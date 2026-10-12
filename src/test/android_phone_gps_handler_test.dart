import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/android_phone_gps_handler.dart';
import 'package:htcommander/services/android_current_location.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  tearDown(DataBroker.reset);

  test('publishes live phone fixes and stops the foreground location service', () async {
    final positions = StreamController<AndroidCoordinates>.broadcast();
    var starts = 0;
    var stops = 0;
    final handler = AndroidPhoneGpsHandler(
      isAndroid: true,
      positions: () => positions.stream,
      startService: () async { starts++; },
      stopService: () async { stops++; },
    );
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 10));

    try {
      DataBroker.dispatch(
        deviceId: 0,
        name: 'PhoneGpsTrackingEnabled',
        data: 1,
      );
      handler.init();
      await settle();
      expect(starts, 1);

      positions.add(const AndroidCoordinates(31.23, 121.47));
      await settle();
      expect(DataBroker.getValue<double>(0, 'ManualLatitude'), 31.23);
      expect(DataBroker.getValue<double>(0, 'ManualLongitude'), 121.47);
      expect(DataBroker.getValue<int>(0, 'ManualLocationEnabled'), 1);

      DataBroker.dispatch(
        deviceId: 0,
        name: 'PhoneGpsTrackingEnabled',
        data: 0,
      );
      await settle();
      expect(stops, 1);
      expect(positions.hasListener, isFalse);
    } finally {
      await handler.dispose();
      await positions.close();
    }
  });

  test('does not start phone GPS on non-Android platforms', () async {
    var starts = 0;
    final handler = AndroidPhoneGpsHandler(
      isAndroid: false,
      positions: () => const Stream<AndroidCoordinates>.empty(),
      startService: () async { starts++; },
    );
    DataBroker.dispatch(
      deviceId: 0,
      name: 'PhoneGpsTrackingEnabled',
      data: 1,
    );
    handler.init();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(starts, 0);
    await handler.dispose();
  });
}
