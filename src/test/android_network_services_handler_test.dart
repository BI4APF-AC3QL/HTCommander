import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/android_network_services_handler.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  tearDown(DataBroker.reset);

  test(
    'keeps Android foreground service active for configured Home Assistant MQTT',
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
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 10));

      try {
        DataBroker.dispatch(
          deviceId: 0,
          name: 'homeAssistantEnabled',
          data: 1,
          store: true,
        );
        handler.init();
        await settle();
        expect(startCalls, 0, reason: 'an empty broker URL starts no client');

        DataBroker.dispatch(
          deviceId: 0,
          name: 'homeAssistantMqttUrl',
          data: 'mqtt://broker.example:1883',
          store: true,
        );
        await settle();
        expect(startCalls, 1);
        expect(stopCalls, 0);

        DataBroker.dispatch(
          deviceId: 0,
          name: 'homeAssistantEnabled',
          data: 0,
          store: true,
        );
        await settle();
        expect(startCalls, 1);
        expect(stopCalls, 1);
      } finally {
        await handler.dispose();
      }
    },
  );

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

        // APRS-IS remains a long-lived TCP client while it reconnects, even
        // when no physical radio is active.
        set('AprsIsEnabled', 1);
        await settle();
        expect(startAttempts, 2);

        set('agwpeServerEnabled', 0);
        await settle();
        expect(stopCalls, 0);

        set('homeAssistantEnabled', 0);
        await settle();
        expect(stopCalls, 0);

        set('AprsIsEnabled', 0);
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

  test(
    'keeps internet radio and hosted node sessions alive in background',
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
      void emit(int deviceId, String name, Object value, {bool store = true}) =>
          DataBroker.dispatch(
            deviceId: deviceId,
            name: name,
            data: value,
            store: store,
          );
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 10));

      try {
        handler.init();
        emit(200, 'State', 'Online');
        await settle();
        expect(startCalls, 1);

        // A second internet-only radio keeps the shared service active after
        // EchoLink disconnects.
        emit(202, 'State', 'Connecting');
        await settle();
        emit(200, 'State', 'Disconnected');
        await settle();
        expect(stopCalls, 0);

        emit(202, 'State', 'Disconnected');
        await settle();
        expect(stopCalls, 1);

        // Node hosting has its own event-only lifecycle and is not represented
        // in ConnectedRadios when the physical radio drops.
        emit(203, 'State', 'Starting', store: false);
        await settle();
        expect(startCalls, 2);
        emit(203, 'State', 'Hosting', store: false);
        await settle();
        emit(1, 'ConnectedRadios', []);
        await settle();
        expect(stopCalls, 1);

        emit(203, 'State', 'Stopped', store: false);
        await settle();
        expect(stopCalls, 2);
      } finally {
        await handler.dispose();
      }
    },
  );

  test(
    'keeps Android foreground service alive during Winlink TCP retries',
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
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 10));

      try {
        handler.init();
        DataBroker.dispatch(
          deviceId: 1,
          name: 'WinlinkBusy',
          data: true,
          store: false,
        );
        await settle();
        expect(startCalls, 1);
        expect(stopCalls, 0);

        DataBroker.dispatch(
          deviceId: 1,
          name: 'WinlinkBusy',
          data: false,
          store: false,
        );
        await settle();
        expect(stopCalls, 1);
      } finally {
        await handler.dispose();
      }
    },
  );
}
