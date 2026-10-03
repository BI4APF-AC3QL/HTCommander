import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprsis/gate_health.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_dashboard.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';

void main() {
  final now = DateTime.utc(2026, 10, 3, 1);
  void set(int id, String key, Object? value) =>
      DataBroker.dispatch(deviceId: id, name: key, data: value);
  Map<String, Object?> build({
    int id = 2,
    DateTime? report,
    List<Map<String, Object>> audit = const [],
  }) => RemoteDashboard.build(
    radioId: id,
    now: now,
    radioReportAt: report,
    audit: audit,
  );
  Map<String, Object> hour(DateTime at, [int count = 1]) => {
    'hour': at.toIso8601String(),
    for (final key in GateHealth.counters) key: count,
  };
  tearDown(DataBroker.reset);

  test('reads actual reported channel and distinguishes unknown data', () {
    set(2, 'State', 'Connected');
    set(2, 'Settings', {'channelA': 0});
    set(2, 'Channels', [
      {'channelId': 0, 'name': 'A', 'rxFreq': 145000000},
      {'channelId': 1, 'name': 'Scanning', 'rxFreq': 144390000},
    ]);
    set(2, 'HtStatus', {
      'currChId': 1,
      'isInRx': true,
      'isInTx': false,
      'isScan': true,
      'rssi': 7,
    });
    set(0, 'AprsIsEnabled', 1);
    set(201, 'AprsIsState', 'Connected (verified)');
    set(0, 'RemoteClients', [
      {'id': 1, 'address': 'private-address'},
      {'id': 2},
    ]);
    set(1, 'RemoteAprsDeliveries', [
      for (final status in [
        'waiting',
        'waiting',
        'acknowledged',
        'rejected',
        'timedOut',
        'cancelled',
        'invalid',
      ])
        {'status': status, 'text': 'private-message'},
    ]);
    final data = build(report: now.subtract(const Duration(seconds: 8)));
    expect(data['radio'], {
      'registered': true,
      'link': 'Connected',
      'reportAgeSeconds': 8,
      'reportAt': '2026-10-03T00:59:52.000Z',
      'receiving': true,
      'transmitting': false,
      'scan': true,
      'signalLevel': 7,
      'channel': 'Scanning',
      'channelSource': 'report',
      'rxFrequency': 144390000,
    });
    expect((data['gateway'] as Map)['link'], 'Connected (verified)');
    expect(data['messages'], {
      'waiting': 2,
      'acknowledged': 1,
      'rejected': 1,
      'timedOut': 1,
      'cancelled': 1,
    });
    expect(data['clientCount'], 2);
    expect(jsonEncode(data), isNot(contains('private')));
    set(2, 'HtStatus', null);
    expect((build()['radio'] as Map)['channelSource'], 'settingsA');
    set(2, 'State', 'Disconnected');
    expect((build()['radio'] as Map)['channel'], isNull);
  });

  test('no radio never invents RX TX frequency or report timestamps', () {
    set(-1, 'HtStatus', {'isInRx': true, 'rssi': 12});
    for (final id in [-1, 0, 1, 201]) {
      final radio = build(id: id, report: now)['radio'] as Map;
      expect(radio['registered'], false);
      expect(radio['link'], 'Disconnected');
      for (final key in [
        'receiving',
        'transmitting',
        'scan',
        'signalLevel',
        'channel',
        'channelSource',
        'rxFrequency',
        'reportAgeSeconds',
        'reportAt',
      ]) {
        expect(radio[key], isNull, reason: '$id/$key');
      }
    }
    expect((build()['gateway'] as Map)['health'], {
      for (final key in GateHealth.counters) key: null,
    });
    expect(
      (build(report: now.add(const Duration(seconds: 1)))['radio']
          as Map)['reportAt'],
      isNull,
    );
  });

  test(
    'health totals include only unique valid UTC hours in last 24 hours',
    () {
      final rows = [
        hour(now, 3),
        hour(now.subtract(const Duration(hours: 23)), 2),
        hour(now, 100),
        hour(now.subtract(const Duration(hours: 24)), 100),
        hour(now.add(const Duration(hours: 1)), 100),
        hour(now.subtract(const Duration(minutes: 1)), 100),
        {...hour(now.subtract(const Duration(hours: 2))), 'failures': -1},
        {
          ...hour(now.subtract(const Duration(hours: 3))),
          'receivedIs': double.nan,
        },
        {...hour(now.subtract(const Duration(hours: 4))), 'hour': 'invalid'},
      ];
      set(201, 'GateHealth', rows);
      expect((build()['gateway'] as Map)['health'], {
        for (final key in GateHealth.counters) key: 5,
      });
      set(201, 'GateHealth', [
        hour(now, 9007199254740991),
        hour(now.subtract(const Duration(hours: 1))),
      ]);
      expect((build()['gateway'] as Map)['health'], {
        for (final key in GateHealth.counters) key: null,
      });
      set(201, 'GateHealth', []);
      expect((build()['gateway'] as Map)['health'], {
        for (final key in GateHealth.counters) key: 0,
      });
    },
  );

  test(
    'activity retains five sanitized recent events without private values',
    () {
      final audit = [
        for (var i = 0; i < 9; i++)
          <String, Object>{
            'time': now.subtract(Duration(seconds: 9 - i)).toIso8601String(),
            'clientId': i,
            'action': 'volume',
            'result': 'accepted',
            'password': 'secret-password',
            'address': 'private-address',
            'text': 'private-message',
            'radioId': 2,
          },
        {
          'time': now.toIso8601String(),
          'clientId': 1,
          'action': 'secret-action',
          'result': 'accepted',
        },
        {
          'time': now.add(const Duration(seconds: 1)).toIso8601String(),
          'clientId': 1,
          'action': 'volume',
          'result': 'accepted',
        },
      ];
      final data = build(audit: audit);
      final recent = data['activity'] as List;
      expect(recent, hasLength(5));
      expect((recent.first as Map)['clientId'], 8);
      expect((recent.last as Map)['clientId'], 4);
      expect(jsonEncode(data), isNot(contains('private')));
      expect(jsonEncode(data), isNot(contains('secret')));
      (recent.first as Map)['clientId'] = 999;
      expect(audit[8]['clientId'], 8);
    },
  );

  test(
    'controller reports only observed status time and clears on invalidation',
    () {
      var clock = now;
      final controller = RemoteRadioController(
        target: () => 2,
        clock: () => clock,
      );
      set(2, 'State', 'Connected');
      set(2, 'HtStatus', {'isInRx': false});
      Map radio() =>
          (controller.snapshot()['dashboard'] as Map)['radio'] as Map;
      expect(radio()['reportAt'], isNull);
      controller.observeRadioReport(2, {'isInRx': false});
      clock = clock.add(const Duration(seconds: 20));
      expect(radio()['reportAgeSeconds'], 20);
      controller.observeRadioReport(2, null);
      expect(radio()['reportAt'], isNull);
      controller.observeRadioReport(2, {'isInRx': 'invalid'});
      expect(radio()['reportAt'], isNull);
    },
  );
}
