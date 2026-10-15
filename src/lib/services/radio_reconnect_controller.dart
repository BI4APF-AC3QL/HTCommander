import 'dart:async';

typedef RadioReconnectAttempt = Future<bool> Function(String macAddress);

/// Shared retry schedules used by native radio connection flows.
abstract final class RadioReconnectPolicy {
  static const desktopDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];

  /// Android keeps the remembered radio recoverable while the user has not
  /// explicitly disconnected it. The final retry interval is capped at five
  /// minutes to limit battery and foreground-service churn.
  static const androidDelays = <Duration>[
    ...desktopDelays,
    Duration(seconds: 60),
    Duration(seconds: 120),
    Duration(seconds: 300),
  ];
}

/// Schedules sequential reconnect attempts for remembered radios.
///
/// The controller owns retry timing and prevents state-change notifications
/// from starting a second attempt while the current scan or connection is in
/// progress. Retry limits and delays are selected by the caller's policy;
/// platform-specific discovery and connection work stays with the caller.
class RadioReconnectController {
  RadioReconnectController({
    required List<Duration> delays,
    this.continueWhileRemembered = false,
    required this.isRemembered,
    required this.isConnected,
    required this.attempt,
    this.onChanged,
    this.onScheduled,
    this.onExhausted,
    this.onError,
  }) : delays = List.unmodifiable(delays);

  final List<Duration> delays;

  /// When true, repeat the final delay until the radio is connected or the
  /// remembered connection is cancelled. Other callers keep finite retries.
  final bool continueWhileRemembered;
  final bool Function(String macAddress) isRemembered;
  final bool Function(String macAddress) isConnected;
  final RadioReconnectAttempt attempt;
  final void Function()? onChanged;
  final void Function(String macAddress, Duration delay, int attempt)?
  onScheduled;
  final void Function(String macAddress, int attempts)? onExhausted;
  final void Function(String macAddress, Object error)? onError;

  final Map<String, Timer> _timers = {};
  final Map<String, int> _attemptCounts = {};
  final Set<String> _inFlight = {};
  final Set<String> _exhaustionReported = {};
  bool _disposed = false;

  bool get hasWork => _timers.isNotEmpty || _inFlight.isNotEmpty;

  int attemptsFor(String macAddress) =>
      _attemptCounts[macAddress.trim().toUpperCase()] ?? 0;

  void schedule(String macAddress) {
    if (_disposed) return;
    final mac = macAddress.trim().toUpperCase();
    if (mac.isEmpty || !isRemembered(mac)) {
      cancel(mac);
      return;
    }
    if (isConnected(mac)) {
      cancel(mac);
      return;
    }
    // A disconnect event can arrive while a scheduled scan/connect is still
    // resolving. The active attempt will schedule its own retry on failure.
    if (_timers.containsKey(mac) || _inFlight.contains(mac)) return;

    final attemptIndex = _attemptCounts[mac] ?? 0;
    final canContinue = continueWhileRemembered && delays.isNotEmpty;
    if (attemptIndex >= delays.length && !canContinue) {
      if (_exhaustionReported.add(mac)) {
        onExhausted?.call(mac, attemptIndex);
      }
      return;
    }

    _attemptCounts[mac] = attemptIndex + 1;
    final delayIndex = attemptIndex.clamp(0, delays.length - 1);
    final delay = delays[delayIndex];
    _timers[mac] = Timer(delay, () {
      _timers.remove(mac);
      if (_disposed || !isRemembered(mac)) {
        cancel(mac);
        return;
      }
      if (isConnected(mac)) {
        cancel(mac);
        return;
      }
      // This check also protects against a duplicate timer callback if a
      // platform timer implementation delivers an already-cancelled callback.
      if (!_inFlight.add(mac)) return;
      onChanged?.call();
      unawaited(_runAttempt(mac, attempt));
    });
    onScheduled?.call(mac, delay, attemptIndex + 1);
    onChanged?.call();
  }

  /// Runs one immediate attempt through the same in-flight guard as a timer.
  /// An optional operation lets startup reuse its already-discovered device
  /// instead of performing a second Bluetooth scan.
  Future<void> attemptNow(
    String macAddress, {
    RadioReconnectAttempt? operation,
  }) async {
    if (_disposed) return;
    final mac = macAddress.trim().toUpperCase();
    if (mac.isEmpty || !isRemembered(mac) || isConnected(mac)) {
      cancel(mac);
      return;
    }
    if (_inFlight.contains(mac)) return;

    // If a disconnect event queued a timer while startup discovery was still
    // running, treat this immediate attempt as that pending retry.
    _timers.remove(mac)?.cancel();
    if (!_inFlight.add(mac)) return;
    onChanged?.call();
    await _runAttempt(mac, operation ?? attempt);
  }

  /// Cancels a pending timer while preserving the retry count.
  /// Used when a manual or automatic connection has begun.
  void pause(String macAddress) {
    final mac = macAddress.trim().toUpperCase();
    final timer = _timers.remove(mac);
    if (timer != null) {
      timer.cancel();
      onChanged?.call();
    }
  }

  /// Cancels retries and resets backoff, for example after a manual disconnect
  /// or a successful connection.
  void cancel(String macAddress) {
    final mac = macAddress.trim().toUpperCase();
    final timer = _timers.remove(mac);
    timer?.cancel();
    final hadTimer = timer != null;
    final hadAttempts = _attemptCounts.remove(mac) != null;
    final hadExhaustion = _exhaustionReported.remove(mac);
    if (hadTimer || hadAttempts || hadExhaustion) onChanged?.call();
  }

  Future<void> _runAttempt(String mac, RadioReconnectAttempt operation) async {
    var succeeded = false;
    try {
      succeeded = await operation(mac);
    } catch (error) {
      onError?.call(mac, error);
    } finally {
      _inFlight.remove(mac);
      if (succeeded) {
        cancel(mac);
      } else if (!_disposed && isRemembered(mac) && !isConnected(mac)) {
        schedule(mac);
      }
      onChanged?.call();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _attemptCounts.clear();
    _inFlight.clear();
    _exhaustionReported.clear();
    onChanged?.call();
  }
}
