import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprsis/aprsis_manager.dart';
import 'package:htcommander/dialogs/software_beacon_dialog.dart';
import 'package:htcommander/gps/gps_data.dart';
import 'package:htcommander/handlers/beacon_schedule.dart';
import 'package:htcommander/handlers/software_beacon_config.dart';
import 'package:htcommander/handlers/software_beacon_handler.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/radio/radio.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/host_bridge.dart';
import 'package:htcommander/services/web/remote_beacon_status.dart';
import 'aprsis_manager_test.dart' show FakeNetwork;

void set(int id, String name, Object? value) =>
    DataBroker.dispatch(deviceId: id, name: name, data: value);
Map status() => DataBroker.getValueDynamic(0, 'SoftwareBeaconStatus') as Map;
void resume() => set(0, 'SoftwareBeaconResume', status()['revision']);
void ready() {
  set(0, 'CallSign', 'W1AW');
  set(0, 'AllowTransmit', 1);
  set(1, 'ConnectedRadios', [
    {'DeviceId': 2, 'FriendlyName': 'Simulated N7500'},
  ]);
  set(2, 'State', 'Connected');
  set(2, 'Channels', [
    {'channelId': 1, 'name': 'APRS'},
  ]);
}

void idle() =>
    set(2, 'HtStatus', {'isInRx': false, 'isInTx': false, 'rssi': 0});
void configure({
  bool location = false,
  int radio = 2,
  int interval = 60,
  String text = 'test beacon',
}) => set(
  0,
  'SoftwareBeaconConfig',
  jsonEncode(
    SoftwareBeaconConfig(
      intervalSeconds: interval,
      includeLocation: location,
      radioDeviceId: radio,
      message: text,
    ).toJson(),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DataBroker.reset);
  test(
    'schedule explicit revision, full interval, no sleep catchup or clock regression burst',
    () {
      var now = DateTime.utc(2026);
      final task = BeaconSchedule(clock: () => now)..configure(60);
      final revision = task.revision;
      expect(task.armed, false);
      expect(task.resume(revision - 1), false);
      expect(task.resume(revision), true);
      expect(task.due(), false);
      now = now.add(const Duration(seconds: 60));
      expect(task.due(), true);
      now = now.add(const Duration(hours: 1));
      expect(task.due(), false);
      expect(task.skipped, 1);
      expect(task.nextAt, now.add(const Duration(seconds: 60)));
      now = now.subtract(const Duration(hours: 2));
      expect(task.due(), false);
      expect(task.skipped, 2);
      task.pause('host');
      expect(task.resume(revision), false);
      expect(task.resume(task.revision), true);
      expect(task.due(), false);
    },
  );
  test(
    'startup/edit stays paused, selected radio never falls back, no stale approval/replay',
    () {
      fakeAsync((time) {
        final clock = time.getClock(DateTime.utc(2026));
        ready();
        configure();
        final frames = <TransmitDataFrameData>[];
        final cancelled = <Object?>[];
        final watch = DataBrokerClient()
          ..subscribe(
            deviceId: DataBroker.allDevices,
            name: 'TransmitDataFrame',
            callback: (_, _, v) => frames.add(v as TransmitDataFrameData),
          )
          ..subscribe(
            deviceId: DataBroker.allDevices,
            name: 'CancelSoftwareBeaconFrames',
            callback: (_, _, v) => cancelled.add(v),
          );
        final host = SoftwareBeaconHandler(clock: clock.now)
          ..init()
          ..init();
        time.elapse(const Duration(minutes: 2));
        expect(frames, isEmpty);
        expect(status()['reason'], 'restart');
        resume();
        time.elapse(const Duration(seconds: 59));
        idle();
        time.elapse(const Duration(seconds: 1));
        expect(frames, hasLength(1));
        expect(frames.single.packet!.tag, 'software-beacon');
        expect(
          frames.single.packet!.deadline,
          clock.now().add(const Duration(seconds: 15)),
        );
        expect(status()['requests'], 1);
        final old = status()['revision'];
        configure(text: 'new');
        set(0, 'SoftwareBeaconResume', old);
        expect(status()['running'], false);
        expect(cancelled, isNotEmpty);
        time.elapse(const Duration(minutes: 2));
        expect(frames, hasLength(1));
        resume();
        set(1, 'ConnectedRadios', [
          {'DeviceId': 3},
        ]);
        set(3, 'State', 'Connected');
        set(3, 'Channels', [
          {'channelId': 1, 'name': 'APRS'},
        ]);
        expect(status()['running'], false);
        expect(status()['reason'], 'radio');
        ready();
        time.elapse(const Duration(minutes: 2));
        expect(frames, hasLength(1));
        host.dispose();
        watch.dispose();
        expect(time.periodicTimerCount, 0);
      });
    },
  );
  test(
    'busy or stale radio and stale/invalid GPS skip; emergency and revoke latch pause',
    () {
      fakeAsync((time) {
        final clock = time.getClock(DateTime.utc(2026));
        ready();
        configure(location: true);
        var sends = 0;
        final watch = DataBrokerClient()
          ..subscribe(
            deviceId: 2,
            name: 'TransmitDataFrame',
            callback: (_, _, v) => sends++,
          );
        final host = SoftwareBeaconHandler(clock: clock.now)..init();
        resume();
        time.elapse(const Duration(seconds: 59));
        idle();
        time.elapse(const Duration(seconds: 1));
        expect(sends, 0);
        set(
          1,
          'GpsData',
          GpsData(
            latitude: 31,
            longitude: 121,
            isFixed: true,
            gpsTime: clock.now(),
          ),
        );
        time.elapse(const Duration(seconds: 59));
        idle();
        time.elapse(const Duration(seconds: 1));
        expect(sends, 1);
        time.elapse(const Duration(seconds: 60));
        expect(sends, 1); // radio observation expired
        time.elapse(const Duration(seconds: 59));
        idle();
        time.elapse(const Duration(seconds: 1));
        expect(sends, 1); // GPS stale
        set(
          1,
          'GpsData',
          GpsData(
            latitude: double.nan,
            longitude: 121,
            isFixed: true,
            gpsTime: clock.now(),
          ),
        );
        time.elapse(const Duration(seconds: 59));
        idle();
        time.elapse(const Duration(seconds: 1));
        expect(sends, 1);
        set(
          1,
          'GpsData',
          GpsData(
            latitude: 31,
            longitude: 121,
            isFixed: true,
            gpsTime: clock.now(),
          ),
        );
        time.elapse(const Duration(seconds: 59));
        set(2, 'HtStatus', {'isInRx': true, 'isInTx': false, 'rssi': 5});
        time.elapse(const Duration(seconds: 1));
        expect(sends, 1);
        set(0, 'webServerEmergencyStopped', 1);
        expect(status()['reason'], 'emergency');
        set(0, 'webServerEmergencyStopped', 0);
        expect(status()['running'], false);
        resume();
        set(0, 'AllowTransmit', 0);
        expect(status()['reason'], 'permission');
        set(0, 'AllowTransmit', 1);
        expect(status()['running'], false);
        time.elapse(const Duration(minutes: 5));
        expect(sends, 1);
        expect(status()['skipped'], 5);
        host.dispose();
        watch.dispose();
      });
    },
  );
  test(
    'internet task writes only to verified fake network, no gateway backlog or RF',
    () {
      fakeAsync((time) {
        final clock = time.getClock(DateTime.utc(2026));
        set(0, 'CallSign', 'W1AW');
        set(0, 'AprsIsEnabled', 1);
        set(0, 'AprsIsPasscode', '12345');
        set(0, 'AprsIsGateToInternet', 0);
        configure(radio: -1);
        final net = FakeNetwork();
        final manager = AprsIsManager(
          networkFactory: () => net,
          clock: clock.now,
        )..init();
        final host = SoftwareBeaconHandler(clock: clock.now)..init();
        var rf = 0;
        final watch = DataBrokerClient()
          ..subscribe(
            deviceId: DataBroker.allDevices,
            name: 'TransmitDataFrame',
            callback: (_, _, v) => rf++,
          );
        resume();
        expect(status()['running'], false);
        net.ready();
        time.flushMicrotasks();
        net.login();
        time.flushMicrotasks();
        expect(net.sent, hasLength(1));
        resume();
        time.elapse(const Duration(seconds: 59));
        expect(net.sent, hasLength(1));
        time.elapse(const Duration(seconds: 1));
        expect(net.sent.last, 'W1AW>APRS:>test beacon');
        expect(status()['requests'], 1);
        expect(rf, 0);
        expect(
          (DataBroker.getValueDynamic(201, 'GateMetrics') as Map)['queueDepth'],
          0,
        );
        set(0, 'SoftwareBeaconPause', true);
        time.elapse(const Duration(minutes: 3));
        expect(net.sent, hasLength(2));
        resume();
        net.failSend = true;
        time.elapse(const Duration(seconds: 60));
        time.flushMicrotasks();
        expect(status()['running'], false);
        expect(status()['requests'], 1);
        expect(rf, 0);
        host.dispose();
        watch.dispose();
        unawaited(manager.dispose());
        time.flushMicrotasks();
        expect(time.periodicTimerCount, 0);
      });
    },
  );
  test(
    'validation/privacy excludes task controls, payload and location from remote settings',
    () {
      expect(
        const SoftwareBeaconConfig(intervalSeconds: 1).validationError,
        isNotNull,
      );
      expect(
        const SoftwareBeaconConfig(message: 'line\nbreak').validationError,
        isNotNull,
      );
      expect(
        const SoftwareBeaconConfig(symbolTable: 'X').validationError,
        isNotNull,
      );
      expect(
        const SoftwareBeaconConfig(radioDeviceId: 0).validationError,
        isNotNull,
      );
      for (final key in [
        'SoftwareBeaconResume',
        'SoftwareBeaconConfig',
        'SoftwareBeaconInternetSend',
        'SoftwareBeaconStatus',
      ]) {
        expect(HostBridge.isSyncedSetting(key), false);
      }
      final view = RemoteBeaconStatus.sanitize({
        'running': true,
        'radioId': -1,
        'reason': 'private-failure',
        'message': 'private payload',
        'latitude': 31,
        'revision': 123,
      });
      expect(jsonEncode(view), isNot(contains('private')));
      expect(view!.containsKey('revision'), false);
      expect(view['reason'], 'configuration');
      expect(view['requests'], null);
    },
  );
  testWidgets(
    '390px host cancel/approve/pause workflow cannot resume stale revision',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ready();
      configure();
      final host = SoftwareBeaconHandler()..init();
      addTearDown(host.dispose);
      var dialogNow = DateTime.utc(2026);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SoftwareBeaconDialog(clock: () => dialogNow)),
        ),
      );
      await tester.pumpAndSettle();
      final start = find.text('Start / resume task…');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(find.text('Confirm scheduled beacon'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(status()['running'], false);
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      dialogNow = dialogNow.add(const Duration(seconds: 31));
      await tester.tap(find.text('Authorize schedule'));
      await tester.pumpAndSettle();
      expect(status()['running'], false);
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      set(0, 'SoftwareBeaconPause', true);
      await tester.pump();
      await tester.tap(find.text('Authorize schedule'));
      await tester.pumpAndSettle();
      expect(status()['running'], false);
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Authorize schedule'));
      await tester.pumpAndSettle();
      expect(status()['running'], true);
      final pause = find.text('Pause task');
      await tester.ensureVisible(pause);
      await tester.tap(pause);
      await tester.pump();
      expect(status()['running'], false);
      expect(tester.takeException(), isNull);
      host.dispose();
    },
  );
}
