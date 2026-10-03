/// Payload-free phone view of the host task. No configuration or arm command.
abstract final class RemoteBeaconStatus {
  static const reasons = {
    'restart',
    'disabled',
    'configuration',
    'host',
    'emergency',
    'permission',
    'radio',
    'internet',
    'disposed',
    '',
  };
  static Map<String, Object?>? sanitize(Object? raw) {
    if (raw is! Map) return null;
    String? timestamp(Object? value) => value is String
        ? DateTime.tryParse(value)?.toUtc().toIso8601String()
        : null;
    int? count(Object? value) => value is int && value >= 0 ? value : null;
    return {
      'enabled': raw['enabled'] == true,
      'running': raw['running'] == true,
      'internetOnly': raw['radioId'] == -1,
      'reason': reasons.contains(raw['reason'])
          ? raw['reason']
          : 'configuration',
      'availability': reasons.contains(raw['availability'])
          ? raw['availability']
          : null,
      'intervalSeconds': count(raw['intervalSeconds']),
      'nextAt': timestamp(raw['nextAt']),
      'lastAt': timestamp(raw['lastAt']),
      'requests': count(raw['requests']),
      'skipped': count(raw['skipped']),
    };
  }
}
