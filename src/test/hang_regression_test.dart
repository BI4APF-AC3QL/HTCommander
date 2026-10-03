import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/aprs_events.dart';
import 'package:htcommander/aprs/aprs_packet.dart';
import 'package:htcommander/aprsis/aprsis_client.dart';
import 'package:htcommander/aprsis/tnc2_codec.dart';
import 'package:htcommander/handlers/aprs_handler.dart';
import 'package:htcommander/radio/gaia_protocol.dart';
import 'package:htcommander/radio/radio.dart';
import 'package:htcommander/radio/radio_models.dart';
import 'package:htcommander/radio/radio_transport.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

class _Network implements AprsIsNetwork {
  final input = StreamController<String>(sync: true);
  @override
  Stream<String> get incoming => input.stream;
  @override
  Future<void> get done => Completer<void>().future;
  @override
  Future<void> connect(String host, int port) async {}
  @override
  void sendLine(String line) {}
  @override
  Future<void> close() => input.close();
}

class _Transport implements RadioTransport {
  final states = StreamController<TransportState>.broadcast(sync: true);
  final bytes = StreamController<Uint8List>.broadcast(sync: true);
  final writes = <Uint8List>[];
  bool writeOk = true;
  int disconnects = 0;
  @override
  TransportState state = TransportState.connected;
  @override
  Stream<TransportState> get stateStream => states.stream;
  @override
  Stream<Uint8List> get dataStream => bytes.stream;
  @override
  DiscoveredDevice? get connectedDevice => null;
  @override
  Stream<DiscoveredDevice> get scanStream => const Stream.empty();
  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<bool> connect(DiscoveredDevice device) async => true;
  @override
  Future<int> requestMtu(int mtu) async => mtu;
  @override
  Future<bool> send(Uint8List data) async {
    writes.add(data);
    return writeOk;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    state = TransportState.disconnected;
    states.add(state);
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await bytes.close();
  }

  int get tncWrites => writes.where((w) => w.length >= 8 && w[7] == 31).length;
  void ack([int status = 0]) => bytes.add(
    GaiaProtocol.encode(Uint8List.fromList([0, 2, 0x80, 31, status])),
  );
}

Radio _radio({bool busy = false, DateTime Function()? clock}) {
  DataBroker.dispatch(deviceId: 0, name: 'AllowTransmit', data: 1);
  final radio = Radio(deviceId: 2, macAddress: 'test-only', queueClock: clock);
  final status = Uint8List(9)..[7] = busy ? 0x10 : 0;
  radio.htStatus = RadioHtStatus.fromBytes(status);
  return radio;
}

void main() {
  tearDown(DataBroker.reset);
  testWidgets('beacon pause removes only pending beacon hardware frames', (
    tester,
  ) async {
    final radio = _radio(busy: true);
    final transport = _Transport();
    await radio.connect(transport);
    radio.transmitTncData(
      Uint8List(20),
      '',
      channelId: 1,
      tag: 'software-beacon',
    );
    radio.transmitTncData(Uint8List(20), '', channelId: 1, tag: 'aprs-is-gate');
    radio.transmitTncData(Uint8List(20), '', channelId: 1, tag: 'local');
    expect(radio.transmitQueueLength, 3);
    DataBroker.dispatch(
      deviceId: DataBroker.allDevices,
      name: 'CancelSoftwareBeaconFrames',
      data: 'software-beacon',
      store: false,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(radio.transmitQueueLength, 2);
    expect(transport.tncWrites, 0);
    radio.dispose();
    await transport.dispose();
  });

  test(
    'unterminated megabyte input stays bounded and recovers at newline',
    () async {
      final net = _Network();
      final client = AprsIsClient(
        callsign: 'W1AW',
        passcode: '-1',
        softwareName: 'Test',
        softwareVersion: '1',
        filter: '',
        network: net,
      );
      final lines = <String>[];
      final diagnostics = <String>[];
      client.onPacketLine = lines.add;
      client.onDiagnostic = diagnostics.add;
      await client.open('fake', 0);
      final chunk = 'x' * 100;
      for (var i = 0; i < 10000; i++) {
        net.input.add(chunk);
        expect(client.bufferedCharacters, lessThanOrEqualTo(513));
      }
      expect(client.oversizedLines, 1);
      expect(lines, isEmpty);
      net.input.add('W1AW>APRS:discarded-tail\nW1AW>APRS:valid\r\n');
      expect(lines, ['W1AW>APRS:valid']);
      expect(diagnostics.where((d) => d.contains('Oversized')), hasLength(1));
      net.input.add('y' * 512);
      net.input.add('\r');
      net.input.add('\n');
      expect(lines.last, hasLength(512));
      net.input.add('${'z' * 514}\nW1AW>APRS:second\n');
      expect(client.oversizedLines, 2);
      expect(lines.last, 'W1AW>APRS:second');
      await client.close();
      expect(client.bufferedCharacters, 0);
    },
  );

  testWidgets(
    'actual control RX/read/write diagnostics publish once a second and end safely',
    (tester) async {
      var now = DateTime.utc(2026, 10, 3);
      final radio = _radio(clock: () => now),
          transport = _Transport(),
          observer = DataBrokerClient();
      final reports = <Map>[];
      observer.subscribe(
        deviceId: 2,
        name: 'RadioLinkDiagnostics',
        callback: (_, _, value) => reports.add(value as Map),
      );
      await radio.connect(transport);
      try {
        radio.readRegionName(0);
        await tester.pump();
        now = now.add(const Duration(milliseconds: 120));
        final reply = GaiaProtocol.encode(
          Uint8List.fromList([
            0,
            2,
            0x80,
            RadioBasicCommand.readRegionName.value,
            0,
            0,
          ]),
        );
        transport.bytes.add(Uint8List.fromList([0x12, 0x34, ...reply]));
        for (var i = 0; i < 100; i++) {
          transport.ack();
        }
        expect(reports, hasLength(1));
        await tester.pump(const Duration(seconds: 1));
        final snapshot = reports.last;
        expect(snapshot['commandsReceived'], 101);
        expect(snapshot['framingSkippedBytes'], 2);
        expect(snapshot['rxBytes'], greaterThan(100));
        expect((snapshot['replyDelay'] as Map)['lastMs'], 120);
        expect(snapshot['readReplies'], 1);
        transport.writeOk = false;
        radio.getVolumeLevel();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(reports.last['writeFailures'], 1);
        radio.readRegionName(1);
        await tester.pump();
        await tester.pump(const Duration(seconds: 8));
        expect(reports.last['readTimeouts'], greaterThan(0));
        radio.disconnect();
        expect(reports.last['connected'], false);
        expect(reports.last['queuedReads'], 0);
        expect(reports.last['pendingWrites'], 0);
        final count = reports.length;
        await tester.pump(const Duration(seconds: 3));
        expect(reports, hasLength(count));
        expect(transport.tncWrites, 0);
      } finally {
        radio.dispose();
        observer.dispose();
        await transport.dispose();
      }
    },
  );
  testWidgets('1000 positions produce one latest bounded snapshot per window', (
    tester,
  ) async {
    final handler = AprsHandler()..init();
    final observer = DataBrokerClient();
    final snapshots = <List>[];
    observer.subscribe(
      deviceId: 1,
      name: 'RemoteMapStations',
      callback: (_, _, value) => snapshots.add(value as List),
    );
    final now = DateTime.now();
    for (var i = 0; i < 1000; i++) {
      final frame = Tnc2Codec.decode('W1AW>APRS:!4737.14N/12220.09W>Test')!;
      frame.time = now.add(Duration(microseconds: i));
      final packet = AprsPacket.parse(frame)!;
      packet.position.coordinateSet.latitude.value = 40 + i / 1000;
      DataBroker.dispatch(
        deviceId: 1,
        name: 'AprsFrame',
        data: AprsFrameEventArgs(packet, frame, null),
        store: false,
      );
    }
    expect(snapshots, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(snapshots, hasLength(1));
    expect(snapshots.single.single['lat'], 40.999);
    await tester.pump(const Duration(seconds: 2));
    expect(snapshots, hasLength(1));
    handler.dispose();
    observer.dispose();
  });

  testWidgets(
    'missing TNC ACK disconnects once, drops queue and never replays',
    (tester) async {
      final radio = _radio();
      final transport = _Transport();
      await radio.connect(transport);
      expect(radio.transmitTncData(Uint8List(100), '', channelId: 1), 100);
      expect(transport.tncWrites, 1);
      expect(radio.transmitQueueLength, 2);
      await tester.pump(const Duration(seconds: 10));
      expect(transport.disconnects, 1);
      expect(radio.transmitQueueLength, 0);
      expect(DataBroker.getValue<String>(2, 'State'), 'Disconnected');
      transport.ack();
      await tester.pump(const Duration(seconds: 10));
      expect(transport.tncWrites, 1);
      radio.dispose();
      expect(transport.bytes.hasListener, false);
      expect(transport.states.hasListener, false);
      await transport.dispose();
    },
  );

  testWidgets('write failure also clears the in-flight queue', (tester) async {
    final radio = _radio();
    final transport = _Transport()..writeOk = false;
    await radio.connect(transport);
    radio.transmitTncData(Uint8List(100), '', channelId: 1);
    await tester.pump();
    expect(radio.transmitQueueLength, 0);
    expect(transport.disconnects, 1);
    radio.dispose();
    await transport.dispose();
  });

  testWidgets('successful ACK advances fragments and cancels watchdog', (
    tester,
  ) async {
    final radio = _radio();
    final transport = _Transport();
    await radio.connect(transport);
    radio.transmitTncData(Uint8List(100), '', channelId: 1);
    transport.ack();
    expect(transport.tncWrites, 2);
    transport.ack();
    expect(radio.transmitQueueLength, 0);
    await tester.pump(const Duration(seconds: 11));
    expect(transport.disconnects, 0);
    radio.dispose();
    await transport.dispose();
  });

  testWidgets('rejected response disconnects safely during receive decoding', (
    tester,
  ) async {
    final radio = _radio();
    final transport = _Transport();
    await radio.connect(transport);
    radio.transmitTncData(Uint8List(100), '', channelId: 1);
    transport.ack(1);
    expect(radio.transmitQueueLength, 0);
    expect(transport.disconnects, 1);
    transport.ack();
    expect(transport.tncWrites, 1);
    radio.dispose();
    await transport.dispose();
  });

  testWidgets(
    'busy channel queue is bounded, rejects whole packets and expires',
    (tester) async {
      var now = DateTime(2026);
      final radio = _radio(busy: true, clock: () => now);
      final transport = _Transport();
      await radio.connect(transport);
      final deadline = now.add(const Duration(seconds: 1));
      // Four packets of 64 fragments fill the queue without wrapping wire IDs.
      for (var i = 0; i < 4; i++) {
        expect(
          radio.transmitTncData(
            Uint8List(3200),
            '',
            channelId: 1,
            deadline: deadline,
          ),
          3200,
        );
      }
      expect(radio.transmitQueueLength, 256);
      expect(radio.transmitTncData(Uint8List(100), '', channelId: 1), 0);
      expect(radio.transmitTncData(Uint8List(3201), '', channelId: 1), 0);
      expect(radio.transmitQueueLength, 256);
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(radio.transmitQueueLength, 0);
      expect(transport.tncWrites, 0);
      radio.dispose();
      await transport.dispose();
    },
  );

  test(
    'reconnect replaces listeners and dispose cancels delayed initialization',
    () async {
      final radio = _radio();
      final old = _Transport();
      await radio.connect(old);
      radio.disconnect();
      final current = _Transport();
      await radio.connect(current);
      expect(old.bytes.hasListener, false);
      expect(old.states.hasListener, false);
      final observer = DataBrokerClient();
      var received = 0;
      observer.subscribe(
        deviceId: 2,
        name: 'RawCommandRx',
        callback: (_, _, _) => received++,
      );
      old.ack();
      expect(received, 0);
      current.ack();
      expect(received, 1);
      radio.dispose();
      current.ack();
      expect(received, 1);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(current.writes, isEmpty);
      observer.dispose();
      await old.dispose();
      await current.dispose();
    },
  );
  testWidgets('gateway cancellation removes only tagged hardware packets', (
    tester,
  ) async {
    final radio = _radio(busy: true);
    final transport = _Transport();
    await radio.connect(transport);
    radio.transmitTncData(Uint8List(20), '', channelId: 1, tag: 'aprs-is-gate');
    radio.transmitTncData(Uint8List(20), '', channelId: 1, tag: 'local');
    expect(radio.transmitQueueLength, 2);
    DataBroker.dispatch(
      deviceId: DataBroker.allDevices,
      name: 'CancelGatewayFrames',
      data: 'aprs-is-gate',
      store: false,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(radio.transmitQueueLength, 1);
    expect(transport.tncWrites, 0);
    radio.dispose();
    await transport.dispose();
  });
}
