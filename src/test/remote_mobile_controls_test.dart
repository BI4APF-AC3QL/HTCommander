import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';
import 'package:htcommander/services/host_bridge.dart';
import 'package:htcommander/handlers/satellite_handler.dart';
import 'package:htcommander/satellite/satellite_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RemoteRadioController control;
  late DataBrokerClient broker;
  late DateTime now;
  void set(int id, String name, Object? value) =>
      DataBroker.dispatch(deviceId: id, name: name, data: value, store: true);
  void setupOrbit() {
    set(0, 'SatelliteRemoteState', {
      'enabled': true,
      'observerKnown': true,
      'catalog': [
        {
          'id': 25544,
          'name': 'ISS',
          'usages': [
            {'index': 0, 'name': 'Voice', 'downlinkHz': 145800000},
          ],
        },
      ],
      'positions': [
        {
          'id': 25544,
          'utc': now.toIso8601String(),
          'azimuthDeg': 90.0,
          'elevationDeg': 30.0,
          'rangeRateKmS': 1.0,
        },
      ],
    });
  }

  setUp(() {
    now = DateTime.utc(2026, 10, 4);
    broker = DataBrokerClient();
    control = RemoteRadioController(target: () => 2, clock: () => now);
    control.grantControl(1);
    set(2, 'HtStatus', {'isPowerOn': true, 'isInTx': false, 'isScan': false});
    set(2, 'Settings', {'squelchLevel': 5});
  });
  tearDown(() {
    control.recallControl();
    broker.dispose();
    DataBroker.reset();
  });
  test('squelch validates level, exclusive ownership and emergency stop', () {
    final levels = <Object?>[];
    broker.subscribe(
      deviceId: 2,
      name: 'SetSquelchLevel',
      callback: (_, _, v) => levels.add(v),
    );
    expect(control.command(1, {'op': 'squelch', 'value': 7}), isNull);
    expect(levels, [7]);
    for (final value in [-1, 10, 1.5, '7']) {
      expect(control.command(1, {'op': 'squelch', 'value': value}), isNotNull);
    }
    expect(control.command(2, {'op': 'squelch', 'value': 5}), isNotNull);
    set(0, 'webServerEmergencyStopped', 1);
    expect(control.command(1, {'op': 'squelch', 'value': 5}), isNotNull);
    expect(levels, [7]);
  });
  test('satellite request uses known catalogue and forces receive-only', () {
    setupOrbit();
    final requests = <Object?>[];
    broker.subscribe(
      deviceId: 0,
      name: 'SatelliteTrackTarget',
      callback: (_, _, v) => requests.add(v),
    );
    expect(
      control.command(1, {
        'op': 'satelliteStart',
        'noradId': 25544,
        'usageIndex': 0,
        'receiveOnly': false,
        'uplinkHz': 435000000,
      }),
      isNull,
    );
    expect((requests.single as Map)['receiveOnly'], true);
    expect((requests.single as Map)['uplinkHz'], isNull);
    expect(
      control.command(1, {'op': 'channel', 'value': 0}),
      contains('Stop satellite'),
    );
    control.disconnected(1);
    expect(requests.last, isNull);
    expect(DataBroker.getValueDynamic(0, 'SatelliteTrackingMarker'), isNull);
  });
  test(
    'stale orbit, missing observer, busy radio and unknown selection deny',
    () {
      setupOrbit();
      now = now.add(const Duration(seconds: 7));
      expect(
        control.command(1, {
          'op': 'satelliteStart',
          'noradId': 25544,
          'usageIndex': 0,
        }),
        contains('stale'),
      );
      setupOrbit();
      expect(
        control.command(1, {
          'op': 'satelliteStart',
          'noradId': 999,
          'usageIndex': 0,
        }),
        isNotNull,
      );
      expect(
        control.command(1, {
          'op': 'satelliteStart',
          'noradId': 25544,
          'usageIndex': 99,
        }),
        isNotNull,
      );
      set(2, 'LockState', {'isLocked': true, 'usage': 'BBS'});
      expect(
        control.command(1, {
          'op': 'satelliteStart',
          'noradId': 25544,
          'usageIndex': 0,
        }),
        contains('occupied'),
      );
      final st = DataBroker.getValueDynamic(0, 'SatelliteRemoteState') as Map;
      set(0, 'SatelliteRemoteState', {...st, 'observerKnown': false});
      expect(
        control.command(1, {
          'op': 'satelliteStart',
          'noradId': 25544,
          'usageIndex': 0,
        }),
        isNotNull,
      );
    },
  );
  test(
    'handoff stops remote tracking, but never stops replacement local task',
    () {
      setupOrbit();
      final requests = <Object?>[];
      broker.subscribe(
        deviceId: 0,
        name: 'SatelliteTrackTarget',
        callback: (_, _, v) => requests.add(v),
      );
      control.command(1, {
        'op': 'satelliteStart',
        'noradId': 25544,
        'usageIndex': 0,
      });
      control.grantControl(2);
      expect(requests.last, isNull);
      control.command(2, {
        'op': 'satelliteStart',
        'noradId': 25544,
        'usageIndex': 0,
      });
      set(0, 'SatelliteTrackingMarker', {'noradId': 25544, 'usageIndex': 0});
      final count = requests.length;
      control.disconnected(2);
      expect(requests.length, count);
      expect(
        DataBroker.getValueDynamic(0, 'SatelliteTrackingMarker'),
        isNotNull,
      );
    },
  );
  test('recording preferences/status never cross web settings bridge', () {
    for (final key in [
      'RollingVoiceStatus',
      'RollingVoiceEnabled',
      'RollingVoiceHours',
      'SatelliteRemoteState',
    ]) {
      expect(HostBridge.isSyncedSetting(key), false);
    }
  });
  test(
    'production satellite handler emits zero uplink for remote RX-only tracking',
    () async {
      final dir = Directory.systemTemp.createTempSync('htc-orbit-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) => Future.value(dir.path));
      final handler = SatelliteHandler();
      final frames = <SatelliteTrackParams>[];
      broker.subscribe(
        deviceId: 2,
        name: 'SatelliteTrackUpdate',
        callback: (_, _, v) {
          if (v is SatelliteTrackParams) frames.add(v);
        },
      );
      try {
        set(0, 'SatObserverLat', 31.2);
        set(0, 'SatObserverLon', 121.5);
        set(0, 'SatelliteSupport', 1);
        await handler.init();
        final state =
            DataBroker.getValueDynamic(0, 'SatelliteRemoteState') as Map;
        expect(state['enabled'], true);
        expect(state['observerKnown'], true);
        final catalog = state['catalog'] as List;
        expect(catalog, isNotEmpty);
        final sat = catalog.whereType<Map>().firstWhere(
              (s) => (s['usages'] as List).isNotEmpty,
            ),
            usage = (sat['usages'] as List).first as Map;
        DataBroker.dispatch(
          deviceId: 0,
          name: 'SatelliteTrackTarget',
          data: {
            'radioDeviceId': 2,
            'noradId': sat['id'],
            'usageIndex': usage['index'],
            'receiveOnly': true,
          },
          store: false,
        );
        expect(frames, isNotEmpty);
        expect(frames.last.txFreqHz, 0);
        expect(frames.last.txCtcssHz, isNull);
        expect(frames.last.rxFreqHz, greaterThan(0));
      } finally {
        handler.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        dir.deleteSync(recursive: true);
      }
    },
  );
}
