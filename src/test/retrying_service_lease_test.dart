import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/retrying_service_lease.dart';

void main() {
  test('retries a failed start with capped exponential delays', () {
    fakeAsync((time) {
      var attempts = 0;
      final lease = RetryingServiceLease(
        start: () async {
          attempts++;
          if (attempts < 4) throw StateError('temporary start failure');
        },
        stop: () async {},
        retryDelays: const [Duration(seconds: 2), Duration(seconds: 4)],
      );

      lease.setDesired(true);
      time.flushMicrotasks();
      expect(attempts, 1);
      expect(lease.isActive, isFalse);

      // Duplicate state notifications must not bypass the backoff and hammer
      // Android's service manager with immediate retries.
      lease.setDesired(true);
      time.flushMicrotasks();
      expect(attempts, 1);

      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(attempts, 2);

      time.elapse(const Duration(seconds: 4));
      time.flushMicrotasks();
      expect(attempts, 3);

      // Backoff remains capped at the final configured delay.
      time.elapse(const Duration(seconds: 4));
      time.flushMicrotasks();
      expect(attempts, 4);
      expect(lease.isActive, isTrue);

      lease.dispose();
      time.flushMicrotasks();
    });
  });

  test('retries a failed stop until the service is inactive', () {
    fakeAsync((time) {
      var stopAttempts = 0;
      final lease = RetryingServiceLease(
        start: () async {},
        stop: () async {
          stopAttempts++;
          if (stopAttempts == 1) throw StateError('temporary stop failure');
        },
        retryDelays: const [Duration(seconds: 1)],
      );

      lease.setDesired(true);
      time.flushMicrotasks();
      expect(lease.isActive, isTrue);

      lease.setDesired(false);
      time.flushMicrotasks();
      expect(stopAttempts, 1);
      expect(lease.isActive, isTrue);

      time.elapse(const Duration(seconds: 1));
      time.flushMicrotasks();
      expect(stopAttempts, 2);
      expect(lease.isActive, isFalse);

      lease.dispose();
      time.flushMicrotasks();
    });
  });

  test('reconciles a release requested while start is still pending', () {
    fakeAsync((time) {
      final startResult = Completer<void>();
      final calls = <String>[];
      final lease = RetryingServiceLease(
        start: () {
          calls.add('start');
          return startResult.future;
        },
        stop: () async => calls.add('stop'),
      );

      lease.setDesired(true);
      time.flushMicrotasks();
      expect(calls, ['start']);

      lease.setDesired(false);
      time.flushMicrotasks();
      expect(calls, ['start'], reason: 'transitions must not overlap');

      startResult.complete();
      time.flushMicrotasks();
      expect(calls, ['start', 'stop']);
      expect(lease.isActive, isFalse);

      lease.dispose();
      time.flushMicrotasks();
    });
  });

  test('a desired-state reversal cancels a stale retry', () {
    fakeAsync((time) {
      var starts = 0;
      var stops = 0;
      final lease = RetryingServiceLease(
        start: () async {
          starts++;
          throw StateError('temporary start failure');
        },
        stop: () async => stops++,
        retryDelays: const [Duration(seconds: 2)],
      );

      lease.setDesired(true);
      time.flushMicrotasks();
      expect(starts, 1);

      lease.setDesired(false);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();

      expect(starts, 1);
      expect(stops, 0);
      expect(lease.isActive, isFalse);
      lease.dispose();
      time.flushMicrotasks();
    });
  });
}
