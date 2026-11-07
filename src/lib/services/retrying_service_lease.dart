import 'dart:async';

/// Serializes a desired on/off state for a service and retries failed
/// transitions with a capped exponential backoff.
///
/// A new desired state is reconciled after any in-flight transition finishes,
/// so a slow start cannot leave a service running after its owner has released
/// the lease.
class RetryingServiceLease {
  RetryingServiceLease({
    required this.start,
    required this.stop,
    this.onError,
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
  });

  final Future<void> Function() start;
  final Future<void> Function() stop;
  final void Function(Object error)? onError;
  final List<Duration> retryDelays;

  Future<void> _tail = Future<void>.value();
  Timer? _retryTimer;
  var _desired = false;
  var _active = false;
  var _disposed = false;
  var _retryIndex = 0;

  bool get isDesired => _desired;
  bool get isActive => _active;

  /// Requests that the service be active or inactive.
  ///
  /// The returned future completes when the immediately queued reconciliation
  /// attempt finishes. Failed transitions are retried in the background.
  Future<void> setDesired(bool desired) {
    if (_disposed) return _tail;
    if (_desired == desired) return _tail;
    _desired = desired;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryIndex = 0;
    return _enqueue();
  }

  Future<void> _enqueue() {
    _tail = _tail.catchError((Object _) {}).then((_) => _reconcile());
    return _tail;
  }

  Future<void> _reconcile() async {
    if (_active == _desired) return;
    final transitionTo = _desired;
    try {
      if (transitionTo) {
        await start();
      } else {
        await stop();
      }
      _active = transitionTo;
      _retryTimer?.cancel();
      _retryTimer = null;
      _retryIndex = 0;
    } catch (error) {
      try {
        onError?.call(error);
      } catch (_) {
        // Diagnostics must not break lifecycle reconciliation.
      }
      if (!_disposed && _active != _desired) _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_retryTimer != null || retryDelays.isEmpty) return;
    final index = _retryIndex.clamp(0, retryDelays.length - 1);
    final delay = retryDelays[index];
    if (_retryIndex < retryDelays.length - 1) _retryIndex++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!_disposed && _active != _desired) _enqueue();
    });
  }

  /// Releases the lease and makes one best-effort stop if active.
  ///
  /// Disposal cancels retries so it cannot keep an otherwise exiting process
  /// alive. Callers that need retries should keep the lease alive and request
  /// [setDesired] with false instead.
  Future<void> dispose() {
    if (_disposed) return _tail;
    _disposed = true;
    _desired = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _tail = _tail.catchError((Object _) {}).then((_) => _reconcile());
    return _tail;
  }
}
