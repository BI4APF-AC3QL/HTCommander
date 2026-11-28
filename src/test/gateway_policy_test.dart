import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:htcommander/aprsis/gate_health.dart';
import 'package:htcommander/aprsis/gateway_policy.dart';
import 'package:htcommander/dialogs/gateway_policy_dialog.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DataBroker.reset);
  test(
    'gateway policy validates paths, persists deliberate disable and normalizes corrupt preferences',
    () async {
      SharedPreferences.setMockInitialValues({});
      await DataBroker.initialize();
      expect(GatewayPolicy.current.toInternet, true);
      expect(DataBroker.getValue<int>(0, 'AprsIsGateToRf', 0), 0);
      const GatewayPolicy(
        toInternet: false,
        rfPath: 'WIDE1-1',
        rfPerMinute: 3,
      ).save();
      DataBroker.reset();
      await DataBroker.initialize();
      expect(GatewayPolicy.current.toInternet, false);
      expect(GatewayPolicy.current.rfPath, 'WIDE1-1');
      expect(GatewayPolicy.current.rfPerMinute, 3);
      for (final invalid in ['TCPIP', 'NOGATE', 'CALL<script>', 'WIDE2-2']) {
        expect(
          () => GatewayPolicy(rfPath: invalid).save(),
          throwsFormatException,
        );
      }
      expect(
        () => const GatewayPolicy(rfPerMinute: 0).save(),
        throwsFormatException,
      );
      DataBroker.dispatch(deviceId: 0, name: 'AprsIsRfPath', data: 'TCPIP');
      DataBroker.dispatch(deviceId: 0, name: 'AprsIsRfPerMinute', data: 999);
      expect(GatewayPolicy.current.rfPath, '');
      expect(GatewayPolicy.current.rfPerMinute, 30);
    },
  );
  test(
    'UTC hourly report aggregates, rolls over, caps retention and rejects payload keys',
    () {
      var now = DateTime.parse('2026-10-02T08:59:59+08:00');
      final report = GateHealth(clock: () => now);
      report.record('receivedRf', 2);
      report.record('toInternet');
      report.record('private-message');
      report.record('failures', -1);
      expect(report.snapshot.single['hour'], '2026-10-02T00:00:00.000Z');
      expect(report.snapshot.single['receivedRf'], 2);
      now = now.add(const Duration(seconds: 1));
      report.record('failures');
      expect(report.snapshot.length, 2);
      expect(report.snapshot.first['failures'], 1);
      for (var i = 0; i < 40; i++) {
        now = now.add(const Duration(hours: 1));
        report.record('dropped');
      }
      expect(report.snapshot.length, 24);
      expect(jsonEncode(report.snapshot), isNot(contains('private-message')));
      final copy = report.snapshot;
      copy.first['dropped'] = 999;
      expect(report.snapshot.first['dropped'], 1);
      now = now.add(const Duration(days: 2));
      expect(report.snapshot, isEmpty);
      now = now.subtract(const Duration(days: 5));
      report.record('receivedIs');
      expect(report.snapshot.length, 1);
    },
  );
  testWidgets(
    '390px host rule editor saves and exports payload-free hourly report',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      const GatewayPolicy().save();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'];
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      DataBroker.dispatch(
        deviceId: 201,
        name: 'GateHealth',
        data: [
          {'hour': '2026-10-02T00:00:00Z', 'receivedRf': 4},
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GatewayPolicyDialog())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Copy last 24 hours (UTC)'));
      await tester.tap(find.text('Copy last 24 hours (UTC)'));
      await tester.pump();
      expect(jsonDecode(copied!).single['receivedRf'], 4);
      await tester.tap(find.text('Save rules'));
      await tester.pumpAndSettle();
      expect(GatewayPolicy.current.toInternet, false);
      expect(tester.takeException(), isNull);
    },
  );
}
