import 'dart:collection';
import 'gate_budget.dart';

/// Short-lived RF-to-internet backlog; never used to replay RF transmissions.
class GateQueue {
  GateQueue({
    required this.clock,
    this.capacity = 32,
    this.ttl = const Duration(seconds: 30),
  });
  final DateTime Function() clock;
  final int capacity;
  final Duration ttl;
  final Queue<(String, DateTime)> _queue = Queue();
  int expired = 0, overflow = 0, duplicates = 0, invalid = 0;
  void prune() {
    final now = clock();
    while (_queue.isNotEmpty && !now.isBefore(_queue.first.$2)) {
      _queue.removeFirst();
      expired++;
    }
  }

  bool add(String line) {
    prune();
    if (line.isEmpty ||
        line.length > 512 ||
        line.contains('\n') ||
        line.contains('\r')) {
      invalid++;
      return false;
    }
    if (_queue.any(
      (e) => GateBudget.duplicateKey(e.$1) == GateBudget.duplicateKey(line),
    )) {
      duplicates++;
      return false;
    }
    if (_queue.length >= capacity) {
      overflow++;
      return false;
    }
    _queue.add((line, clock().add(ttl)));
    return true;
  }

  String? take() {
    prune();
    return _queue.isEmpty ? null : _queue.removeFirst().$1;
  }

  int clear() {
    final count = _queue.length;
    _queue.clear();
    return count;
  }

  Map<String, int> get metrics => {
    'queueDepth': _queue.length,
    'queueExpired': expired,
    'queueOverflow': overflow,
    'queueDuplicates': duplicates,
    'queueInvalid': invalid,
  };
}
