import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/aprs_events.dart';
import 'package:htcommander/aprs/aprs_packet.dart';
import 'package:htcommander/handlers/aprs_handler.dart';
import 'package:htcommander/radio/ax25_address.dart';
import 'package:htcommander/radio/ax25_packet.dart';
import 'package:htcommander/radio/radio.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';

void main() {
  tearDown(DataBroker.reset);
  testWidgets(
    'remote submission is correlated and incoming ACK reaches phone state',
    (tester) async {
      void set(int id, String name, Object value) =>
          DataBroker.dispatch(deviceId: id, name: name, data: value);
      set(0, 'CallSign', 'AC3QL');
      set(0, 'AllowTransmit', 1);
      set(0, 'webServerAllowAprs', 1);
      set(2, 'State', 'Connected');
      set(2, 'HtStatus', {'isPowerOn': true, 'isInTx': false});
      set(2, 'Channels', [
        {'channelId': 3, 'name': 'APRS', 'txDisable': false},
      ]);
      final handler = AprsHandler()..init();
      final observer = DataBrokerClient();
      final frames = <TransmitDataFrameData>[];
      observer.subscribe(
        deviceId: 2,
        name: 'TransmitDataFrame',
        callback: (_, _, value) => frames.add(value as TransmitDataFrameData),
      );
      final remote = RemoteRadioController(target: () => 2);
      try {
        expect(
          remote.command(1, {
            'op': 'aprsMessage',
            'destination': 'BI4APF-7',
            'text': 'Hello',
          }),
          isNull,
        );
        expect(frames, hasLength(1));
        final outgoing = AprsPacket.parse(frames.single.packet!)!;
        final sequence = outgoing.messageData.seqId;
        expect(sequence, isNotEmpty);
        final ack = AX25Packet(
          addresses: [
            AX25Address.parse('APRS')!,
            AX25Address.parse('BI4APF-7')!,
          ],
          dataStr: ':AC3QL    :ack$sequence',
          type: FrameType.uFrameUi,
          command: true,
          time: DateTime.now(),
        );
        ack.incoming = true;
        ack.pid = 240;
        set(
          1,
          'AprsFrame',
          AprsFrameEventArgs(AprsPacket.parse(ack)!, ack, null),
        );
        final state = remote.snapshot()['aprsDeliveries'] as List;
        expect(state.single['status'], 'acknowledged');
        expect(state.single['sequence'], sequence);
        await tester.pump(const Duration(seconds: 1));
        expect(frames, hasLength(1));
      } finally {
        handler.dispose();
        observer.dispose();
        remote.release();
      }
    },
  );
}
