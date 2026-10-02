/// Bounded duplicate and rate protection for either forwarding direction.
/// Path changes do not bypass duplicate detection; payload/sequence does.
class GateBudget {
  GateBudget({
    DateTime Function()? clock,
    this.capacity = 2048,
    this.limitPerMinute = 120,
    this.duplicateWindow = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final int capacity;
  int limitPerMinute;
  final Duration duplicateWindow;
  final Map<String, DateTime> _seen = {};
  final List<DateTime> _accepted = [];
  int forwarded = 0, duplicates = 0, limited = 0, invalid = 0;
  static String duplicateKey(String line) {
    final colon = line.indexOf(':');
    if (colon < 0) return line;
    final header = line.substring(0, colon);
    final comma = header.indexOf(',');
    return '${comma < 0 ? header : header.substring(0, comma)}${line.substring(colon)}';
  }

  bool accept(String line) {
    if (line.isEmpty ||
        line.length > 512 ||
        line.contains('\r') ||
        line.contains('\n')) {
      invalid++;
      return false;
    }
    final now = _clock();
    _seen.removeWhere((_, t) => now.difference(t) >= duplicateWindow);
    _accepted.removeWhere(
      (t) => now.difference(t) >= const Duration(minutes: 1),
    );
    final key = duplicateKey(line);
    if (_seen.containsKey(key)) {
      duplicates++;
      return false;
    }
    if (_accepted.length >= limitPerMinute) {
      limited++;
      return false;
    }
    if (_seen.length >= capacity) _seen.remove(_seen.keys.first);
    _seen[key] = now;
    _accepted.add(now);
    forwarded++;
    return true;
  }

  Map<String, int> get metrics => {
    'forwarded': forwarded,
    'duplicateDrops': duplicates,
    'rateDrops': limited,
    'invalidDrops': invalid,
    'dedupEntries': _seen.length,
  };
}
