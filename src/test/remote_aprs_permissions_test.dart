import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/aprs_events.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';

void main() {
  tearDown(DataBroker.reset);
  test(
    'remote APRS permissions independent of voice, validation and host rate limit',
    () {
      var now = DateTime(2026);
      final controls = RemoteRadioController(target: () => 2, clock: () => now)
        ..grantControl(1);
      final broker = DataBrokerClient();
      final sent = <AprsSendMessageData>[];
      broker.subscribe(
        deviceId: 1,
        name: 'SendAprsMessage',
        callback: (_, _, data) {
          sent.add(data as AprsSendMessageData);
        },
      );
      void host(String name, Object data) =>
          DataBroker.dispatch(deviceId: 0, name: name, data: data);
      final command = {
        'op': 'aprsMessage',
        'destination': 'BI4APF-7',
        'text': 'Hello',
      };
      expect(controls.command(1, command), isNotNull);
      host('webServerAllowAprs', 1);
      host('AllowTransmit', 1);
      host('CallSign', 'AC3QL');
      DataBroker.dispatch(
        deviceId: 2,
        name: 'HtStatus',
        data: {'isPowerOn': true, 'isInTx': false},
      );
      DataBroker.dispatch(
        deviceId: 2,
        name: 'Channels',
        data: [
          {'channelId': 3, 'name': 'APRS', 'txDisable': true},
        ],
      );
      expect(controls.command(1, command), isNotNull);
      DataBroker.dispatch(
        deviceId: 2,
        name: 'Channels',
        data: [
          {'channelId': 3, 'name': 'APRS', 'txDisable': false},
        ],
      );
      for (final bad in ['\n', '{1', '汉字', 'x' * 68]) {
        expect(controls.command(1, {...command, 'text': bad}), isNotNull);
      }
      expect(
        controls.command(1, {...command, 'destination': 'BI4APF-16'}),
        isNotNull,
      );
      expect(sent, isEmpty);
      expect(controls.command(1, command), isNull);
      expect(sent.single.radioDeviceId, 2);
      expect(controls.snapshot()['txAllowed'], false);
      expect(controls.command(2, command), isNotNull);
      now = now.add(const Duration(seconds: 10));
      controls.grantControl(2);
      expect(controls.command(2, command), isNull);
      host('webServerAllowAprs', 0);
      now = now.add(const Duration(seconds: 10));
      expect(controls.command(1, command), isNotNull);
      expect(sent.length, 2);
      broker.dispose();
    },
  );
}
