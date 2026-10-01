/// Conservative initial budget for congested RFCOMM, adapting to measured
/// reply latency. Only idempotent READ operations use this retry policy.
class ReadTiming {
  double _smoothedMs = 350;
  Duration budget(int retries) {
    final base = (_smoothedMs * 3 + 200).clamp(1000, 3500);
    return Duration(
      milliseconds: (base * (1 + retries * 0.5)).round().clamp(1000, 5000),
    );
  }

  void observe(Duration elapsed) {
    final ms = elapsed.inMilliseconds.clamp(1, 5000);
    _smoothedMs = _smoothedMs * 0.75 + ms * 0.25;
  }
}
