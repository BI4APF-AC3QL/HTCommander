import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/aprs_events.dart';
import 'package:htcommander/aprs/aprs_packet.dart';
import 'package:htcommander/aprsis/aprsis_manager.dart';
import 'package:htcommander/aprsis/tnc2_codec.dart';
import 'package:htcommander/handlers/aprs_handler.dart';
import 'package:htcommander/handlers/packet_store.dart';
import 'package:htcommander/radio/tnc_data_fragment.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/db/app_database_io.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';

TncDataFragment rf(String line, DateTime time, {String channel = 'APRS'}) {
  final frame = Tnc2Codec.decode(line, time: time)!;
  return TncDataFragment(
    finalFragment: true,
    fragmentId: 0,
    channelId: 3,
    regionId: 0,
    data: frame.toByteArray(),
    channelName: channel,
    incoming: true,
    time: time,
  );
}

Future<void> until(bool Function() condition) async {
  for (var n = 0; n < 200; n++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('History did not become ready');
}

void main() {
  tearDown(() async {
    await AppDatabase.close();
    DataBroker.reset();
  });

  test(
    'real file reopen restores RF/IS messages and map without TX or ACK',
    () async {
      final dir = await Directory.systemTemp.createTemp('htc_remote_restart_');
      addTearDown(() async {
        await AppDatabase.close();
        await dir.delete(recursive: true);
      });
      final path = '${dir.path}/history.db';
      final now = DateTime.now();
      var db = await AppDatabase.openForTesting(path);
      await db.packets.insert(
        rf(
          'W1AW>APRS::AC3QL    :RF hello{1',
          now.subtract(const Duration(minutes: 3)),
        ),
      );
      await db.packets.insert(
        rf(
          'W1AW>APRS:!4000.00N/12220.09W>Old',
          now.subtract(const Duration(minutes: 4)),
        ),
      );
      await db.packets.insert(
        rf(
          'BI4APF>APRS:!3900.00N/12220.09W>Expired',
          now.subtract(const Duration(days: 2)),
        ),
      );
      await db.packets.insert(
        rf('W1AW>APRS:>Non-APRS', now, channel: 'Voice 1'),
      );
      await db.aprsis.insert(
        now.subtract(const Duration(minutes: 2)),
        'W1AW>APRS,TCPIP*::AC3QL    :RF hello{1',
      );
      await db.aprsis.insert(
        now.subtract(const Duration(minutes: 1)),
        'AC3QL>APRS,TCPIP*::W1AW     :IS reply{2',
      );
      await db.aprsis.insert(now, 'W1AW>APRS,TCPIP*:!4100.00N/12220.09W>New');
      await db.aprsis.insert(now, 'bad line');
      await AppDatabase.close();
      db = await AppDatabase.openForTesting(path);

      DataBroker.dispatch(deviceId: 0, name: 'CallSign', data: 'AC3QL');
      final observer = DataBrokerClient();
      final sideEffects = <String>[];
      observer.subscribeMultiple(
        deviceId: DataBroker.allDevices,
        names: ['AprsFrame', 'TransmitDataFrame', 'SendAprsMessage'],
        callback: (_, name, _) => sideEffects.add(name),
      );
      final packets = PacketStore();
      await packets.init();
      final handler = AprsHandler()..init();
      final manager = AprsIsManager()..init();
      final remote = RemoteRadioController(target: () => -1);
      try {
        await until(
          () => DataBroker.getValue<bool>(1, 'AprsIsStoreReady') == true,
        );
        final state = remote.snapshot();
        final messages = state['aprsMessages'] as List;
        expect(messages.map((m) => m['text']), ['RF hello', 'IS reply']);
        expect(messages.first['viaInternet'], false);
        expect(messages.last['incoming'], false);
        final stations = state['mapStations'] as List;
        expect(stations, hasLength(1));
        expect(stations.single['lat'], 41);
        expect(stations.single['viaInternet'], true);
        expect((stations.single['track'] as List).map((p) => p[0]), [40, 41]);
        expect(sideEffects, isEmpty);
        expect(state['aprsDeliveries'], isEmpty);

        // Clear must erase the published view and both persistent APRS sources,
        // while keeping unrelated packet capture history.
        DataBroker.dispatch(
          deviceId: 1,
          name: 'ClearAprsPackets',
          data: null,
          store: false,
        );
        await until(() => packets.packetCount == 1);
        await db.aprsis.recent(1); // queued after the clear operations
        expect(remote.snapshot()['aprsMessages'], isEmpty);
        expect(remote.snapshot()['mapStations'], isEmpty);
        expect(await db.packets.count(aprs: true), 0);
        expect(await db.packets.count(aprs: false), 1);
        expect(await db.aprsis.recent(100), isEmpty);
      } finally {
        handler.dispose();
        await manager.dispose();
        await packets.dispose();
        remote.release();
        observer.dispose();
      }
      await AppDatabase.close();
      db = await AppDatabase.openForTesting(path);
      expect(await db.packets.count(aprs: true), 0);
      expect(await db.aprsis.recent(100), isEmpty);
    },
  );

  test(
    'clear during pending IS database load cannot restore deleted history',
    () async {
      final db = await AppDatabase.openInMemory();
      await db.aprsis.insert(DateTime.now(), 'W1AW>APRS::AC3QL    :Cleared{1');
      DataBroker.dispatch(deviceId: 0, name: 'CallSign', data: 'AC3QL');
      final handler = AprsHandler()..init();
      final manager = AprsIsManager()..init();
      try {
        DataBroker.dispatch(
          deviceId: 1,
          name: 'ClearAprsPackets',
          data: null,
          store: false,
        );
        await until(
          () => DataBroker.getValue<bool>(1, 'AprsIsStoreReady') == true,
        );
        expect(DataBroker.getValueDynamic(1, 'RemoteAprsMessages'), isEmpty);
        expect(await db.aprsis.recent(10), isEmpty);
      } finally {
        handler.dispose();
        await manager.dispose();
      }
    },
  );

  test(
    'late history preserves live messages/fixes and callsign change re-filters',
    () {
      DataBroker.dispatch(deviceId: 0, name: 'CallSign', data: 'AC3QL');
      final handler = AprsHandler()..init();
      final now = DateTime.now();
      final live = Tnc2Codec.decode(
        'W1AW>APRS:!4200.00N/12220.09W>Live',
        time: now,
      )!;
      DataBroker.dispatch(
        deviceId: 1,
        name: 'AprsFrame',
        data: AprsFrameEventArgs(AprsPacket.parse(live)!, live, null),
        store: false,
      );
      final old = Tnc2Codec.decode(
        'W1AW>APRS:!4000.00N/12220.09W>History',
        time: now.subtract(const Duration(minutes: 1)),
      )!;
      final message = Tnc2Codec.decode(
        'W1AW>APRS::AC3QL    :Saved{1',
        time: now,
      )!;
      try {
        DataBroker.dispatch(
          deviceId: 1,
          name: 'AprsIsPacketList',
          data: [AprsPacket.parse(old)!, AprsPacket.parse(message)!],
          store: false,
        );
        final view = DataBroker.getValueDynamic(1, 'RemoteMapStations') as List;
        expect(view.single['lat'], 42);
        expect((view.single['track'] as List).map((p) => p[0]), [40, 42]);
        expect(
          DataBroker.getValueDynamic(1, 'RemoteAprsMessages') as List,
          hasLength(1),
        );
        DataBroker.dispatch(deviceId: 0, name: 'CallSign', data: 'BI4APF');
        expect(DataBroker.getValueDynamic(1, 'RemoteAprsMessages'), isEmpty);
      } finally {
        handler.dispose();
      }
    },
  );
}
