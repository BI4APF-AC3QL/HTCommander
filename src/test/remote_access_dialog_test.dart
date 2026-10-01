import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/remote_access_dialog.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  tearDown(DataBroker.reset);
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
