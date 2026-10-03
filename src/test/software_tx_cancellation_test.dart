import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/radio/modem_tx_encoder.dart';
import 'package:htcommander/radio/software_modem.dart';
import 'package:htcommander/radio/tnc_data_fragment.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

class Encoder extends ModemTxEncoder {
  final requests = <List<Uint8List>>[];
  final results = <Completer<ModemTxResult>>[];
  @override
  Future<ModemTxResult> encodePacket({
    required PacketModulation modulation,
    required bool fecEnabled,
    required int txdelay,
    required int txtail,
    required int sampleRate,
    required List<Uint8List> frames,
  }) {
    requests.add(frames);
    final result = Completer<ModemTxResult>();
    results.add(result);
    return result.future;
  }

  void finish(int index) =>
      results[index].complete(ModemTxResult(Uint8List(100), []));
  @override
  void dispose() {}
}

void publish(int device, String name, Object data) =>
    DataBroker.dispatch(deviceId: device, name: name, data: data);
TncDataFragment frame(int marker, {String? tag, DateTime? deadline}) =>
    TncDataFragment(
        finalFragment: true,
        fragmentId: 0,
        data: Uint8List.fromList([marker, 1, 2, 3]),
        channelId: 0,
        channelName: 'APRS',
        regionId: 0,
      )
      ..transmitTag = tag
      ..transmitDeadline = deadline;

void main() {
  tearDown(DataBroker.reset);
  testWidgets(
    'beacon pause cancels pending encode while retaining local packet',
    (tester) async {
      publish(0, 'AllowTransmit', 1);
      publish(0, 'AprsSoftwareModemMode', 'AFSK1200');
      publish(2, 'HtStatus', {'rssi': 0, 'isInTx': false});
      final encoder = Encoder();
      final modem = SoftwareModem(txEncoder: encoder, randomInt: (_) => 0)
        ..init();
      var output = 0;
      final watch = DataBrokerClient()
        ..subscribe(
          deviceId: 2,
          name: 'TransmitVoicePCM',
          callback: (_, _, v) => output++,
        );
      publish(2, 'SoftModemTransmitPacket', frame(10, tag: 'software-beacon'));
      publish(2, 'SoftModemTransmitPacket', frame(20));
      await tester.pump(const Duration(milliseconds: 100));
      expect(encoder.requests.single.map((f) => f.first), [10]);
      publish(
        DataBroker.allDevices,
        'CancelSoftwareBeaconFrames',
        'software-beacon',
      );
      encoder.finish(0);
      await tester.pump();
      expect(output, 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(encoder.requests.last.map((f) => f.first), [20]);
      encoder.finish(1);
      await tester.pump();
      expect(output, 1);
      modem.dispose();
      watch.dispose();
    },
  );
  testWidgets(
    'gateway recall cancels encoding bundle without cancelling unrelated local frame',
    (tester) async {
      publish(0, 'AllowTransmit', 1);
      publish(0, 'AprsSoftwareModemMode', 'AFSK1200');
      publish(2, 'HtStatus', {'rssi': 0, 'isInTx': false});
      final encoder = Encoder();
      final modem = SoftwareModem(txEncoder: encoder, randomInt: (_) => 0)
        ..init();
      final output = <Map>[];
      final observer = DataBrokerClient()
        ..subscribe(
          deviceId: 2,
          name: 'TransmitVoicePCM',
          callback: (_, _, value) => output.add(value as Map),
        );
      publish(2, 'SoftModemTransmitPacket', frame(10, tag: 'aprs-is-gate'));
      publish(2, 'SoftModemTransmitPacket', frame(20));
      await tester.pump(const Duration(milliseconds: 100));
      expect(encoder.requests.length, 1);
      expect(encoder.requests.single.map((f) => f.first), [10]);
      publish(DataBroker.allDevices, 'CancelGatewayFrames', 'aprs-is-gate');
      encoder.finish(0);
      await tester.pump();
      expect(output, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(encoder.requests.length, 2);
      expect(encoder.requests.last.map((f) => f.first), [20]);
      encoder.finish(1);
      await tester.pump();
      expect(output.length, 1);
      modem.dispose();
      observer.dispose();
    },
  );
  testWidgets(
    'remote tags revoke only matching client and TX revocation cancels in-flight software encode',
    (tester) async {
      publish(0, 'AllowTransmit', 1);
      publish(0, 'AprsSoftwareModemMode', 'AFSK1200');
      publish(2, 'HtStatus', {'rssi': 5, 'isInTx': false});
      final encoder = Encoder();
      final modem = SoftwareModem(txEncoder: encoder, randomInt: (_) => 0)
        ..init();
      var output = 0;
      final observer = DataBrokerClient()
        ..subscribe(
          deviceId: 2,
          name: 'TransmitVoicePCM',
          callback: (_, _, _) => output++,
        );
      publish(2, 'SoftModemTransmitPacket', frame(10, tag: 'remote-aprs:1'));
      publish(2, 'SoftModemTransmitPacket', frame(20, tag: 'remote-aprs:2'));
      publish(2, 'CancelRemoteAprsFrame', 'remote-aprs:1');
      publish(2, 'HtStatus', {'rssi': 0, 'isInTx': false});
      publish(2, 'ChannelClear', true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(encoder.requests.single.map((f) => f.first), [20]);
      publish(0, 'AllowTransmit', 0);
      encoder.finish(0);
      await tester.pump();
      expect(output, 0);
      publish(0, 'AllowTransmit', 1);
      publish(2, 'ChannelClear', true);
      await tester.pump(const Duration(seconds: 1));
      expect(encoder.requests.length, 1);
      modem.dispose();
      observer.dispose();
    },
  );
  testWidgets(
    'expired packet behind later-deadline local frame is removed, never bundled',
    (tester) async {
      publish(0, 'AllowTransmit', 1);
      publish(0, 'AprsSoftwareModemMode', 'AFSK1200');
      publish(2, 'HtStatus', {'rssi': 5, 'isInTx': false});
      final encoder = Encoder();
      var now = DateTime.utc(2026);
      final modem = SoftwareModem(
        txEncoder: encoder,
        randomInt: (_) => 0,
        clock: () => now,
      )..init();
      final deadline = now.add(const Duration(seconds: 1));
      publish(2, 'SoftModemTransmitPacket', frame(10));
      publish(2, 'SoftModemTransmitPacket', frame(20, deadline: deadline));
      publish(
        2,
        'SoftModemTransmitPacket',
        frame(30, deadline: now.subtract(const Duration(seconds: 1))),
      );
      now = now.add(const Duration(seconds: 2));
      publish(2, 'HtStatus', {'rssi': 0, 'isInTx': false});
      publish(2, 'ChannelClear', true);
      await tester.pump(const Duration(seconds: 1));
      expect(encoder.requests.single.map((f) => f.first), [10]);
      encoder.finish(0);
      await tester.pump();
      modem.dispose();
    },
  );
  testWidgets(
    'packet expires while encoding; completion cannot submit stale PCM',
    (tester) async {
      publish(0, 'AllowTransmit', 1);
      publish(0, 'AprsSoftwareModemMode', 'AFSK1200');
      publish(2, 'HtStatus', {'rssi': 0, 'isInTx': false});
      var now = DateTime.utc(2026);
      final encoder = Encoder();
      final modem = SoftwareModem(
        txEncoder: encoder,
        randomInt: (_) => 0,
        clock: () => now,
      )..init();
      var output = 0;
      final observer = DataBrokerClient()
        ..subscribe(
          deviceId: 2,
          name: 'TransmitVoicePCM',
          callback: (_, _, _) => output++,
        );
      publish(
        2,
        'SoftModemTransmitPacket',
        frame(
          10,
          tag: 'aprs-is-gate',
          deadline: now.add(const Duration(seconds: 1)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(encoder.requests.length, 1);
      now = now.add(const Duration(seconds: 2));
      encoder.finish(0);
      await tester.pump();
      expect(output, 0);
      modem.dispose();
      observer.dispose();
    },
  );
}
