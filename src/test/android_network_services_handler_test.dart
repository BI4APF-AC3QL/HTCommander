import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/android_network_services_handler.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  tearDown(DataBroker.reset);

  test(
    'retries a failed start and keeps service for either network feature',
    () async {
      var startAttempts = 0;
      var stopCalls = 0;
      final handler = AndroidNetworkServicesHandler(
        startService: () async {
          startAttempts++;
          if (startAttempts == 1) throw StateError('temporary start failure');
        },
        stopService: () async {
          stopCalls++;
        },
      );
      void set(String name, Object value) => DataBroker.dispatch(
        deviceId: 0,
        name: name,
        data: value,
        store: true,
      );
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 10));

      try {
        set('agwpeServerEnabled', 1);
        handler.init();
        await settle();
        expect(startAttempts, 1);

        // A second enabled integration must cause a retry after the first start
        // failed; the failed attempt must not be mistaken for an active service.
        set('homeAssistantEnabled', 1);
        await settle();
        expect(startAttempts, 2);

        set('agwpeServerEnabled', 0);
        await settle();
        expect(stopCalls, 0);

        set('homeAssistantEnabled', 0);
        await settle();
        expect(stopCalls, 1);
      } finally {
        await handler.dispose();
      }
    },
  );

  test(
    'keeps Android radio connections alive alongside network services',
    () async {
      var startCalls = 0;
      var stopCalls = 0;
      final handler = AndroidNetworkServicesHandler(
        startService: () async {
          startCalls++;
        },
        stopService: () async {
          stopCalls++;
        },
      );
      void set(int deviceId, String name, Object value) => DataBroker.dispatch(
        deviceId: deviceId,
        name: name,
        data: value,
        store: true,
      );
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 10));

      try {
        set(1, 'ConnectedRadios', [
          {'DeviceId': 100, 'State': 'Connected'},
        ]);
        handler.init();
        await settle();
        expect(startCalls, 1);

        set(0, 'agwpeServerEnabled', 1);
        await settle();
        set(1, 'ConnectedRadios', []);
        await settle();
        expect(stopCalls, 0);

        set(0, 'agwpeServerEnabled', 0);
        await settle();
        expect(stopCalls, 1);
      } finally {
        await handler.dispose();
      }
    },
  );
}
