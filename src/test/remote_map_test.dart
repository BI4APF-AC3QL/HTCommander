import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/aprs_events.dart';
import 'package:htcommander/aprs/aprs_packet.dart';
import 'package:htcommander/aprs/station_index.dart';
import 'package:htcommander/aprsis/tnc2_codec.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';

AprsFrameEventArgs position(String call, DateTime time, double lat) {
  final frame = Tnc2Codec.decode('$call>APRS:!4737.14N/12220.09W>Test')!;
  frame.time = time;
  final packet = AprsPacket.parse(frame)!;
  packet.position.coordinateSet.latitude.value = lat;
  return AprsFrameEventArgs(packet, frame, null);
}

void main() {
  tearDown(DataBroker.reset);
  test('snapshot expires stale map entries even when no new frames arrive', () {
    final now = DateTime.utc(2026, 10, 2);
    DataBroker.dispatch(
      deviceId: 1,
      name: 'RemoteMapStations',
      data: [
        {'lat': 31.2, 'lon': 121.5, 'time': now.toIso8601String()},
        {
          'lat': 31.2,
          'lon': 121.5,
          'time': now.subtract(const Duration(days: 2)).toIso8601String(),
        },
        {'lat': 31.2, 'lon': 121.5, 'time': 'invalid'},
        {'lat': double.nan, 'lon': 121.5},
      ],
    );
    var clock = now;
    final controller = RemoteRadioController(
      target: () => -1,
      clock: () => clock,
    );
    expect(controller.snapshot()['mapStations'], hasLength(1));
    clock = now.add(const Duration(hours: 25));
    expect(controller.snapshot()['mapStations'], isEmpty);
  });
  test(
    'restore merges tracks by time, preserves live fix and isolates copies',
    () {
      final now = DateTime(2026);
      final index = StationIndex(clock: () => now);
      index.add(position('W1AW', now, 42));
      index.restore([
        position('W1AW', now.subtract(const Duration(minutes: 1)), 41),
        position('W1AW', now.subtract(const Duration(minutes: 2)), 40),
        position('W1AW', now.subtract(const Duration(days: 2)), 39),
      ]);
      expect(index.stations.single['lat'], 42);
      expect((index.stations.single['track'] as List).map((p) => p[0]), [
        40,
        41,
        42,
      ]);
      (index.stations.single['track'] as List).first[0] = 0.0;
      expect((index.stations.single['track'] as List).first[0], 40);
      index.clear();
      expect(index.stations, isEmpty);
    },
  );
  test(
    'station and track limits, stale cleanup and old/future position rejection',
    () {
      var now = DateTime(2026);
      final index = StationIndex(clock: () => now, capacity: 2, trackLimit: 2);
      expect(index.add(position('W1AW', now, 40)), true);
      expect(
        index.add(
          position('W1AW', now.subtract(const Duration(seconds: 1)), 41),
        ),
        false,
      );
      expect(
        index.add(position('W1AW', now.add(const Duration(hours: 1)), 41)),
        false,
      );
      now = now.add(const Duration(seconds: 1));
      index.add(position('W1AW', now, 41));
      now = now.add(const Duration(seconds: 1));
      index.add(position('W1AW', now, 42));
      expect(index.stations.single['track'], hasLength(2));
      index.add(position('AC3QL', now, 30));
      index.add(position('BI4APF', now, 31));
      expect(index.stations, hasLength(2));
      now = now.add(const Duration(hours: 25));
      expect(index.stations, isEmpty);
    },
  );
  test(
    'client viewports are isolated, dateline wraps and replies are bounded',
    () {
      DataBroker.dispatch(
        deviceId: 1,
        name: 'RemoteMapStations',
        data: [
          {'lat': 10.0, 'lon': 175.0},
          {'lat': 10.0, 'lon': -175.0},
          {'lat': 40.0, 'lon': 0.0},
        ],
      );
      final controller = RemoteRadioController(target: () => -1);
      controller.command(1, {
        'op': 'state',
        'mapBounds': [0, 170, 20, -170],
      });
      controller.command(2, {
        'op': 'state',
        'mapBounds': [30, -10, 50, 10],
      });
      expect(controller.snapshot(1)['mapStations'], hasLength(2));
      expect(controller.snapshot(2)['mapStations'], hasLength(1));
      controller.command(1, {
        'op': 'state',
        'mapBounds': [0, 999, 20, 1000],
      });
      expect(controller.snapshot(1)['mapStations'], hasLength(2));
      controller.disconnected(1);
      expect(controller.snapshot(1)['mapStations'], hasLength(3));
      DataBroker.dispatch(
        deviceId: 1,
        name: 'RemoteMapStations',
        data: List.generate(600, (_) => {'lat': 40.0, 'lon': 0.0}),
      );
      expect(controller.snapshot(2)['mapStations'], hasLength(256));
    },
  );
}
