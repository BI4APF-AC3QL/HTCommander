import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/radio_reconnect_controller.dart';

const _delays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

void main() {
  test(
    'Bluetooth restore triggers one serialized remembered-radio scan',
    () async {
      final adapterStates = StreamController<bool>.broadcast(sync: true);
      final firstReconnect = Completer<void>();
      final secondReconnect = Completer<void>();
      var reconnects = 0;
      final watcher = RadioAdapterReconnectWatcher(
        adapterEnabledChanges: adapterStates.stream,
        reconnect: () async {
          reconnects++;
          if (reconnects == 1) await firstReconnect.future;
          if (reconnects == 2) secondReconnect.complete();
        },
      );

      // Initial adapter status is not a new event needing another startup scan.
      adapterStates.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(reconnects, 0);

      adapterStates.add(false);
      adapterStates.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(reconnects, 1);

      // A repeated enabled value does nothing; another off/on during the active
      // scan queues one follow-up instead of overlapping a second Bluetooth scan.
      adapterStates.add(true);
      adapterStates.add(false);
      adapterStates.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(reconnects, 1);

      firstReconnect.complete();
      await secondReconnect.future;
      expect(reconnects, 2);

      await watcher.dispose();
      adapterStates.add(false);
      adapterStates.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(reconnects, 2);
      await adapterStates.close();
    },
  );

  test(
    'failed attempts use bounded increasing delays and stop at the limit',
    () {
      fakeAsync((time) {
        final attemptsAt = <Duration>[];
        var remembered = true;
        var exhausted = 0;
        final controller = RadioReconnectController(
          delays: _delays,
          isRemembered: (_) => remembered,
          isConnected: (_) => false,
          attempt: (_) async {
            attemptsAt.add(time.elapsed);
            return false;
          },
          onExhausted: (_, count) => exhausted = count,
        );

        controller.schedule('aa:bb:cc:dd:ee:ff');
        controller.schedule('AA:BB:CC:DD:EE:FF');
        expect(controller.attemptsFor('aa:bb:cc:dd:ee:ff'), 1);
        time.elapse(const Duration(seconds: 2));
        time.flushMicrotasks();
        expect(attemptsAt, [const Duration(seconds: 2)]);
        expect(controller.attemptsFor('AA:BB:CC:DD:EE:FF'), 2);

        time.elapse(const Duration(seconds: 4));
        time.flushMicrotasks();
        expect(attemptsAt, [
          const Duration(seconds: 2),
          const Duration(seconds: 6),
        ]);
        time.elapse(const Duration(seconds: 8));
        time.flushMicrotasks();
        expect(attemptsAt, hasLength(3));
        expect(exhausted, 3);
        expect(controller.hasWork, isFalse);

        controller.schedule('AA:BB:CC:DD:EE:FF');
        expect(exhausted, 3, reason: 'exhaustion is reported only once');
        remembered = false;
        controller.cancel('aa:bb:cc:dd:ee:ff');
        controller.dispose();
      });
    },
  );

  test('continuous reconnect repeats the capped delay until cancelled', () {
    fakeAsync((time) {
      var attempts = 0;
      var exhausted = 0;
      final controller = RadioReconnectController(
        delays: _delays,
        continueWhileRemembered: true,
        isRemembered: (_) => true,
        isConnected: (_) => false,
        attempt: (_) async {
          attempts++;
          return false;
        },
        onExhausted: (_, _) => exhausted++,
      );

      controller.schedule('AA:BB:CC:DD:EE:FF');
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 4));
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 8));
      time.flushMicrotasks();
      expect(attempts, 3);
      expect(controller.attemptsFor('AA:BB:CC:DD:EE:FF'), 4);

      // After reaching the final delay, retries continue at that capped
      // interval rather than ending or growing without bound.
      time.elapse(const Duration(seconds: 8));
      time.flushMicrotasks();
      expect(attempts, 4);
      expect(controller.attemptsFor('AA:BB:CC:DD:EE:FF'), 5);
      expect(exhausted, 0);
      expect(controller.hasWork, isTrue);

      controller.cancel('AA:BB:CC:DD:EE:FF');
      time.elapse(const Duration(seconds: 30));
      time.flushMicrotasks();
      expect(attempts, 4, reason: 'cancellation prevents later retries');
      expect(controller.hasWork, isFalse);
      controller.dispose();
    });
  });

  test('Android retry schedule grows to a five-minute ceiling', () {
    fakeAsync((time) {
      final scheduledDelays = <Duration>[];
      var attempts = 0;
      final controller = RadioReconnectController(
        delays: RadioReconnectPolicy.androidDelays,
        continueWhileRemembered: true,
        isRemembered: (_) => true,
        isConnected: (_) => false,
        attempt: (_) async {
          attempts++;
          return false;
        },
        onScheduled: (_, delay, _) => scheduledDelays.add(delay),
      );

      controller.schedule('AA:BB:CC:DD:EE:FF');
      for (final delay in RadioReconnectPolicy.androidDelays) {
        time.elapse(delay);
        time.flushMicrotasks();
      }

      expect(attempts, RadioReconnectPolicy.androidDelays.length);
      expect(scheduledDelays, [
        ...RadioReconnectPolicy.androidDelays,
        const Duration(minutes: 5),
      ]);
      expect(controller.hasWork, isTrue);

      controller.cancel('AA:BB:CC:DD:EE:FF');
      time.elapse(const Duration(minutes: 5));
      time.flushMicrotasks();
      expect(attempts, RadioReconnectPolicy.androidDelays.length);
      expect(controller.hasWork, isFalse);
      controller.dispose();
    });
  });

  test('a pending retry cannot overlap an in-flight attempt', () {
    fakeAsync((time) {
      final firstAttempt = Completer<bool>();
      var attemptCount = 0;
      final controller = RadioReconnectController(
        delays: _delays,
        isRemembered: (_) => true,
        isConnected: (_) => false,
        attempt: (_) {
          attemptCount++;
          return attemptCount == 1
              ? firstAttempt.future
              : Future<bool>.value(true);
        },
      );

      controller.schedule('10:20:30:40:50:60');
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(attemptCount, 1);
      expect(controller.hasWork, isTrue);

      // A second Disconnected notification during the scan/connect must not
      // create another timer or a concurrent connection attempt.
      controller.schedule('10:20:30:40:50:60');
      expect(controller.attemptsFor('10:20:30:40:50:60'), 1);
      expect(time.nonPeriodicTimerCount, 0);
      firstAttempt.complete(false);
      time.flushMicrotasks();
      expect(controller.attemptsFor('10:20:30:40:50:60'), 2);

      time.elapse(const Duration(seconds: 4));
      time.flushMicrotasks();
      expect(attemptCount, 2);
      expect(controller.hasWork, isFalse);
      controller.dispose();
    });
  });

  test('a stale cancelled timer cannot consume a replacement retry', () async {
    final timers = <_ManualTimer>[];
    var attempts = 0;
    const mac = 'AA:BB:CC:DD:EE:FF';
    final controller = RadioReconnectController(
      delays: _delays,
      isRemembered: (_) => true,
      isConnected: (_) => false,
      attempt: (_) async {
        attempts++;
        return true;
      },
      createTimer: (_, callback) {
        final timer = _ManualTimer(callback);
        timers.add(timer);
        return timer;
      },
    );

    controller.schedule(mac);
    controller.cancel(mac);
    controller.schedule(mac);
    expect(timers, hasLength(2));

    // Some platform timer implementations may deliver a callback after
    // cancel(). It must not remove the current timer or trigger an early scan.
    timers.first.fireEvenIfCancelled();
    expect(attempts, 0);
    expect(controller.attemptsFor(mac), 1);
    expect(controller.hasWork, isTrue);

    timers[1].fire();
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1);
    expect(controller.hasWork, isFalse);
    controller.dispose();
  });

  test('immediate startup reconnect is serialized with scheduled retries', () {
    fakeAsync((time) {
      final startupAttempt = Completer<bool>();
      var scheduledAttempts = 0;
      final controller = RadioReconnectController(
        delays: _delays,
        isRemembered: (_) => true,
        isConnected: (_) => false,
        attempt: (_) async {
          scheduledAttempts++;
          return true;
        },
      );

      unawaited(
        controller.attemptNow(
          'AA:BB:CC:DD:EE:FF',
          operation: (_) => startupAttempt.future,
        ),
      );
      time.flushMicrotasks();
      expect(controller.hasWork, isTrue);

      // State notifications and a repeated startup request cannot create a
      // timer or start a second connection while the immediate connect runs.
      controller.schedule('aa:bb:cc:dd:ee:ff');
      unawaited(controller.attemptNow('aa:bb:cc:dd:ee:ff'));
      expect(scheduledAttempts, 0);
      expect(controller.attemptsFor('aa:bb:cc:dd:ee:ff'), 0);
      expect(time.nonPeriodicTimerCount, 0);

      startupAttempt.complete(false);
      time.flushMicrotasks();
      expect(controller.attemptsFor('aa:bb:cc:dd:ee:ff'), 1);
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(scheduledAttempts, 1);
      expect(controller.hasWork, isFalse);
      controller.dispose();
    });
  });

  test(
    'success resets backoff and explicit disconnect cancels pending retry',
    () {
      fakeAsync((time) {
        var remembered = true;
        var successes = 0;
        final attemptTimes = <Duration>[];
        final controller = RadioReconnectController(
          delays: _delays,
          isRemembered: (_) => remembered,
          isConnected: (_) => false,
          attempt: (_) async {
            attemptTimes.add(time.elapsed);
            successes++;
            return successes >= 2;
          },
        );

        controller.schedule('aa:bb:cc:dd:ee:ff');
        time.elapse(const Duration(seconds: 2));
        time.flushMicrotasks();
        expect(controller.attemptsFor('aa:bb:cc:dd:ee:ff'), 2);
        time.elapse(const Duration(seconds: 4));
        time.flushMicrotasks();
        expect(controller.attemptsFor('aa:bb:cc:dd:ee:ff'), 0);

        controller.schedule('aa:bb:cc:dd:ee:ff');
        time.elapse(const Duration(seconds: 2));
        time.flushMicrotasks();
        expect(attemptTimes, [
          const Duration(seconds: 2),
          const Duration(seconds: 6),
          const Duration(seconds: 8),
        ]);
        expect(controller.hasWork, isFalse);

        controller.schedule('aa:bb:cc:dd:ee:ff');
        remembered = false;
        controller.cancel('aa:bb:cc:dd:ee:ff');
        time.elapse(const Duration(minutes: 1));
        time.flushMicrotasks();
        expect(attemptTimes, hasLength(3));
        expect(controller.hasWork, isFalse);
        controller.dispose();
      });
    },
  );
}

class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  bool _isActive = true;

  @override
  void cancel() => _isActive = false;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }

  void fireEvenIfCancelled() {
    _isActive = false;
    _callback();
  }
}
