import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprsis/gate_queue.dart';

void main() {
  test('queue bounds, deduplicates, expires and drains one line at a time', () {
    var now = DateTime(2026);
    final queue = GateQueue(clock: () => now, capacity: 2);
    expect(queue.add('A>APRS:one'), true);
    expect(queue.add('A>APRS:one'), false);
    expect(queue.add('A>APRS:two'), true);
    expect(queue.add('A>APRS:three'), false);
    expect(queue.metrics['queueDepth'], 2);
    expect(queue.take(), 'A>APRS:one');
    now = now.add(const Duration(seconds: 30));
    expect(queue.take(), isNull);
    expect(queue.metrics['queueExpired'], 1);
    expect(queue.metrics['queueOverflow'], 1);
    expect(queue.metrics['queueDuplicates'], 1);
    expect(queue.add('invalid\nline'), false);
    expect(queue.add('x' * 513), false);
    expect(queue.metrics['queueInvalid'], 2);
    expect(queue.add('A>APRS:new'), true);
    queue.clear();
    expect(queue.take(), isNull);
  });
}
