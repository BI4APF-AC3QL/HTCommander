import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/message_delivery.dart';

void main() {
  test('zero SSID representations acknowledge the same station', () {
    final tracker = MessageDeliveryTracker(clock: () => DateTime(2026));
    tracker.start('zero', 'AC3QL', 'BI4APF', '1');
    expect(tracker.acknowledge('BI4APF-0', 'AC3QL-0', '1'), true);
  });
  test('ACK requires matching sender, recipient and sequence', () {
    final tracker = MessageDeliveryTracker(clock: () => DateTime(2026));
    final entry = tracker.start('1', 'BI4APF-1', 'TEST-2', '42');
    expect(tracker.acknowledge('OTHER', 'BI4APF-1', '42'), false);
    expect(tracker.acknowledge('TEST-2', 'BI4APF', '42'), false);
    expect(tracker.acknowledge('TEST-2', 'BI4APF-1', '43'), false);
    expect(tracker.acknowledge('test-2', 'bi4apf-1', '42'), true);
    expect(entry.status, DeliveryStatus.acknowledged);
    expect(tracker.acknowledge('TEST-2', 'BI4APF-1', '42'), false);
  });

  test('bounded retries retain sequence and do not burst after clock jump', () {
    var now = DateTime(2026);
    final tracker = MessageDeliveryTracker(clock: () => now);
    final entry = tracker.start('1', 'A', 'B', '7');
    expect(tracker.tick(allowed: (_) => true), isEmpty);
    now = now.add(const Duration(hours: 1));
    expect(tracker.tick(allowed: (_) => true), [entry]);
    expect(entry.sequence, '7');
    expect(tracker.tick(allowed: (_) => true), isEmpty);
    now = now.add(const Duration(seconds: 30));
    expect(tracker.tick(allowed: (_) => true), [entry]);
    now = now.add(const Duration(seconds: 30));
    expect(tracker.tick(allowed: (_) => true), isEmpty);
    expect(entry.attempts, 3);
    expect(entry.status, DeliveryStatus.timedOut);
  });

  test('revocation cancels without replay and full pending outbox rejects', () {
    final tracker = MessageDeliveryTracker(
      clock: () => DateTime(2026),
      capacity: 1,
    );
    final entry = tracker.start('1', 'A', 'B', '7');
    expect(() => tracker.start('2', 'A', 'B', '8'), throwsStateError);
    expect(tracker.tick(allowed: (_) => false), isEmpty);
    expect(entry.status, DeliveryStatus.cancelled);
    expect(tracker.tick(allowed: (_) => true), isEmpty);
    final next = tracker.start('2', 'A', 'B', '8');
    expect(tracker.entries, [next]);
    tracker.cancelAll();
    expect(next.status, DeliveryStatus.cancelled);
  });

  test('rejection stops retries and duplicate identities are refused', () {
    final tracker = MessageDeliveryTracker(clock: () => DateTime(2026));
    final entry = tracker.start('1', 'A', 'B', '7');
    expect(() => tracker.start('2', 'A', 'B', '7'), throwsStateError);
    expect(tracker.acknowledge('B', 'A', '7', rejected: true), true);
    expect(entry.status, DeliveryStatus.rejected);
  });
}
