/// A single host-owned periodic task. Arming is runtime-only; missed slots
/// are skipped, including suspend/resume and clock regression.
class BeaconSchedule {
  BeaconSchedule({required this.clock});
  final DateTime Function() clock;
  int revision = 0;
  int interval = 0;
  bool armed = false;
  DateTime? nextAt, lastAt;
  String reason = 'restart';
  int requested = 0, skipped = 0;
  DateTime? _observed;

  void configure(int seconds) {
    interval = seconds;
    pause(seconds == 0 ? 'disabled' : 'configuration');
  }

  bool resume(int approvedRevision) {
    if (armed ||
        approvedRevision != revision ||
        interval < 60 ||
        interval > 86400) {
      return false;
    }
    armed = true;
    reason = '';
    _observed = clock();
    nextAt = _observed!.add(Duration(seconds: interval));
    return true;
  }

  void pause(String cause) {
    revision++;
    armed = false;
    reason = cause;
    nextAt = null;
    _observed = null;
  }

  bool due() {
    if (!armed || nextAt == null) return false;
    final now = clock();
    if (_observed != null && now.isBefore(_observed!)) {
      nextAt = now.add(Duration(seconds: interval));
      skipped++;
      _observed = now;
      return false;
    }
    _observed = now;
    if (now.isBefore(nextAt!)) return false;
    // Never catch up after sleep. A late slot does not transmit old location.
    final late = now.difference(nextAt!);
    nextAt = now.add(Duration(seconds: interval));
    if (late >= const Duration(seconds: 5)) {
      skipped++;
      return false;
    }
    return true;
  }

  Map<String, Object?> get snapshot => {
    'revision': revision,
    'enabled': interval >= 60 && interval <= 86400,
    'running': armed,
    'intervalSeconds': interval,
    'reason': reason,
    'nextAt': nextAt?.toUtc().toIso8601String(),
    'lastAt': lastAt?.toUtc().toIso8601String(),
    'requests': requested,
    'skipped': skipped,
  };
}
