import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/remote_access_dialog.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  tearDown(DataBroker.reset);
  testWidgets(
    'host emergency stop requires explicit resume without changing TX scopes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RemoteAccessDialog())),
      );
      await tester.pumpAndSettle();
      final stop = find.text('Emergency stop remote control/TX');
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pump();
      expect(DataBroker.getValue<int>(0, 'webServerEmergencyStopped', 0), 1);
      expect(DataBroker.getValue<int>(0, 'webServerAllowAprs', 0), 0);
      final resume = find.text('Resume remote control');
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await tester.pump();
      expect(DataBroker.getValue<int>(0, 'webServerEmergencyStopped', 0), 0);
      expect(DataBroker.getValue<int>(0, 'webServerAllowAprs', 0), 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'remote dialog fits phone viewport and rejects weak credentials',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RemoteAccessDialog())),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Phone remote control'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile).at(1));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('at least 12 characters').last,
        findsOneWidget,
      );
      expect(DataBroker.getValue<int>(0, 'webServerRemoteEnabled', 0), 0);
      expect(tester.takeException(), isNull);
    },
  );
}
