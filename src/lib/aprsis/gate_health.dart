/// Payload-free UTC hourly health. Retains at most 24 hours in memory.
/// Counts describe software processing, not on-air delivery.
class GateHealth {
  GateHealth({required this.clock});
  final DateTime Function() clock;
  static const counters = [
    'receivedRf',
    'receivedIs',
    'toInternet',
    'toRfRequested',
    'dropped',
    'failures',
  ];
  final Map<DateTime, Map<String, int>> _hours = {};
  DateTime _hour(DateTime time) {
    final utc = time.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day, utc.hour);
  }

  void _prune(DateTime now) => _hours.removeWhere(
    (hour, _) =>
        hour.isBefore(now.subtract(const Duration(hours: 23))) ||
        hour.isAfter(now),
  );
  void record(String name, [int count = 1]) {
    if (!counters.contains(name) || count < 1 || count > 1000000) return;
    final hour = _hour(clock());
    _prune(hour);
    final row = _hours.putIfAbsent(
      hour,
      () => {for (final key in counters) key: 0},
    );
    row[name] = row[name]! + count;
  }

  List<Map<String, Object>> get snapshot {
    _prune(_hour(clock()));
    final hours = _hours.keys.toList()..sort((a, b) => b.compareTo(a));
    return hours
        .map(
          (hour) => <String, Object>{
            'hour': hour.toIso8601String(),
            ..._hours[hour]!,
          },
        )
        .toList();
  }
}
