import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/android_recording_service_lease.dart';

void main() {
  test(
    'shares one Android recording service reason across active inputs',
    () async {
      var starts = 0;
      var stops = 0;
      final lease = AndroidRecordingServiceLease(
        enabled: true,
        startService: () async {
          starts++;
        },
        stopService: () async {
          stops++;
        },
      );

      await lease.acquire();
      await lease.acquire();
      expect(starts, 1);
      expect(stops, 0);

      await lease.release();
      expect(stops, 0);
      await lease.release();
      expect(stops, 1);

      await lease.acquire();
      expect(starts, 2);
      await lease.release();
      expect(stops, 2);
    },
  );

  test('does not acquire a lease when starting the service fails', () async {
    var starts = 0;
    var stops = 0;
    final lease = AndroidRecordingServiceLease(
      enabled: true,
      startService: () async {
        starts++;
        throw StateError('service unavailable');
      },
      stopService: () async {
        stops++;
      },
    );

    await expectLater(lease.acquire(), throwsStateError);
    await lease.release();
    expect(starts, 1);
    expect(stops, 0);
  });

  test('is a no-op away from Android', () async {
    var starts = 0;
    var stops = 0;
    final lease = AndroidRecordingServiceLease(
      enabled: false,
      startService: () async {
        starts++;
      },
      stopService: () async {
        stops++;
      },
    );

    await lease.acquire();
    await lease.release();
    expect(starts, 0);
    expect(stops, 0);
  });
}
