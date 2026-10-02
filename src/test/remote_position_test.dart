import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/remote_position.dart';
import 'package:htcommander/handlers/aprs_handler.dart';
import 'package:htcommander/radio/radio.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';

void main() {
  tearDown(DataBroker.reset);
  test(
    'position freshness, accuracy, coordinate bounds and APRS minute carry',
    () {
      final now = DateTime(2026);
      final value = {
        'latitude': 31.2,
        'longitude': 121.5,
        'accuracy': 10,
        'capturedAt': now.toIso8601String(),
      };
      final fix = RemotePositionFix.parse(value, now, radio: false)!;
      expect(fix.information, '!3112.00N/12130.00E>HTCommander phone');
      for (final change in [
        {'latitude': double.nan},
        {'longitude': 181},
        {'accuracy': 101},
        {'accuracy': 0},
        {
          'capturedAt': now
              .subtract(const Duration(minutes: 3))
              .toIso8601String(),
        },
        {'capturedAt': now.add(const Duration(seconds: 6)).toIso8601String()},
      ]) {
        expect(
          RemotePositionFix.parse({...value, ...change}, now, radio: false),
          isNull,
        );
      }
      final pole = RemotePositionFix.parse(
        {...value, 'latitude': -89.999999, 'longitude': -179.999999},
        now,
        radio: false,
      )!;
      expect(pole.information, startsWith('!9000.00S/18000.00W'));
      expect(
        RemotePositionFix.parse(
          {...value, 'receivedTime': now.toIso8601String(), 'locked': false},
          now,
          radio: true,
        ),
        isNull,
      );
      expect(
        RemotePositionFix.parse(
          {
            ...value,
            'receivedTime': now.toIso8601String(),
            'locked': true,
            'accuracy': 0,
          },
          now,
          radio: true,
        )!.accuracy,
        isNull,
      );
    },
  );
  testWidgets(
    'confirmed phone position uses independent permission and host recheck',
    (tester) async {
      var now = DateTime.now();
      void set(int id, String name, Object value) =>
          DataBroker.dispatch(deviceId: id, name: name, data: value);
      set(0, 'CallSign', 'AC3QL');
      set(0, 'AllowTransmit', 1);
      set(0, 'webServerAllowPosition', 1);
      set(2, 'State', 'Connected');
      set(2, 'HtStatus', {'isPowerOn': true, 'isInTx': false});
      set(2, 'Channels', [
        {'channelId': 3, 'name': 'APRS', 'txDisable': false},
      ]);
      final handler = AprsHandler()..init(), observer = DataBrokerClient();
      final frames = <TransmitDataFrameData>[];
      final cancelledTags = <String>[];
      observer.subscribe(
        deviceId: 2,
        name: 'CancelRemoteAprsFrame',
        callback: (_, _, tag) => cancelledTags.add(tag as String),
      );
      observer.subscribe(
        deviceId: 2,
        name: 'TransmitDataFrame',
        callback: (_, _, data) => frames.add(data as TransmitDataFrameData),
      );
      final controls = RemoteRadioController(target: () => 2, clock: () => now);
      final position = {
        'latitude': 31.2,
        'longitude': 121.5,
        'accuracy': 12,
        'capturedAt': now.toIso8601String(),
      };
      final command = {
        'op': 'aprsPosition',
        'source': 'phone',
        'position': position,
      };
      try {
        expect(controls.command(1, command), isNotNull);
        expect(frames, isEmpty);
        expect(controls.command(1, {...command, 'confirmed': true}), isNull);
        expect(frames, hasLength(1));
        expect(frames.single.packet!.dataStr, contains('HTCommander phone'));
        expect(frames.single.packet!.sent, false);
        expect(frames.single.packet!.tag, 'remote-aprs:position:1');
        final receivedTime = now.toIso8601String();
        set(2, 'Position', {
          'latitude': 31.2,
          'longitude': 121.5,
          'accuracy': 0,
          'receivedTime': receivedTime,
          'locked': true,
        });
        now = now.add(const Duration(seconds: 11));
        expect(
          controls.command(1, {
            'op': 'aprsPosition',
            'source': 'radio',
            'confirmed': true,
            'position': {
              'latitude': 31.2,
              'longitude': 121.5,
              'capturedAt': receivedTime,
            },
          }),
          isNull,
        );
        expect(frames, hasLength(2));
        expect(frames.last.packet!.dataStr, contains('HTCommander radio'));
        set(0, 'webServerAllowPosition', 0);
        expect(cancelledTags, contains('remote-aprs:position:1'));
        expect(controls.command(1, {...command, 'confirmed': true}), isNotNull);
        set(
          1,
          'SendRemoteAprsPosition',
          RemotePositionRequest(
            2,
            1,
            RemotePositionFix.parse(position, now, radio: false)!,
          ),
        );
        expect(frames, hasLength(2));
        expect(
          (DataBroker.getValueDynamic(1, 'RemotePositionStatus', null)
              as Map)['status'],
          'rejected',
        );
        set(0, 'webServerAllowPosition', 1);
        set(0, 'webServerEmergencyStopped', 1);
        expect(controls.command(1, {...command, 'confirmed': true}), isNotNull);
        expect(frames, hasLength(2));
      } finally {
        handler.dispose();
        observer.dispose();
        controls.release();
      }
    },
  );
  test(
    'radio preview must match current host fix and cannot be supplied by client',
    () {
      final now = DateTime(2026);
      DataBroker.dispatch(deviceId: 0, name: 'webServerAllowPosition', data: 1);
      DataBroker.dispatch(deviceId: 0, name: 'AllowTransmit', data: 1);
      DataBroker.dispatch(
        deviceId: 2,
        name: 'Position',
        data: {
          'latitude': 31.2,
          'longitude': 121.5,
          'accuracy': 10,
          'receivedTime': now.toIso8601String(),
          'locked': true,
        },
      );
      final controls = RemoteRadioController(target: () => 2, clock: () => now);
      expect(
        controls.command(1, {
          'op': 'aprsPosition',
          'source': 'radio',
          'confirmed': true,
          'position': {
            'latitude': 99,
            'longitude': 121.5,
            'capturedAt': now.toIso8601String(),
          },
        }),
        contains('changed'),
      );
    },
  );
}
