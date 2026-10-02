import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/remote_access_dialog.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

void main() {
  tearDown(DataBroker.reset);
  testWidgets('host exports only redacted audit metadata', (tester) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'];
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    DataBroker.dispatch(
      deviceId: 0,
      name: 'RemoteAudit',
      data: [
        {
          'id': 1,
          'clientId': 4,
          'action': 'aprsMessage',
          'result': 'accepted',
          'text': 'private-message',
          'password': 'private-password',
        },
      ],
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RemoteAccessDialog())),
    );
    await tester.pumpAndSettle();
    final export = find.text('Copy redacted operation audit JSON');
    await tester.ensureVisible(export);
    await tester.tap(export);
    await tester.pump();
    expect(copied, contains('aprsMessage'));
    expect(copied, isNot(contains('private')));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'host grants and recalls control with live clients on narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      DataBroker.dispatch(
        deviceId: 0,
        name: 'RemoteClients',
        data: [
          {
            'id': 1,
            'address': '2409:891f:3666:89e5:30b4:28ff:feb0:acef',
            'ownsControl': true,
            'readOnly': false,
          },
          {
            'id': 2,
            'address': '192.168.1.22',
            'controlRequested': true,
            'queuePosition': 1,
            'readOnly': true,
          },
        ],
      );
      final commands = <String, Object?>{};
      final observer = DataBrokerClient();
      addTearDown(observer.dispose);
      observer.subscribeMultiple(
        deviceId: 0,
        names: ['RemoteControlGrant', 'RemoteControlRecall'],
        callback: (_, name, value) => commands[name] = value,
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RemoteAccessDialog())),
      );
      await tester.pumpAndSettle();
      final grant = find.byTooltip('Grant exclusive control').last;
      await tester.ensureVisible(grant);
      await tester.tap(grant);
      await tester.pump();
      expect(commands['RemoteControlGrant'], 2);
      expect(find.text('Operating · May request control'), findsOneWidget);
      expect(find.text('Waiting #1 · Read-only'), findsOneWidget);
      final recall = find.text('Recall all remote control');
      await tester.ensureVisible(recall);
      await tester.tap(recall);
      await tester.pump();
      expect(commands['RemoteControlRecall'], true);
      DataBroker.dispatch(
        deviceId: 0,
        name: 'webServerEmergencyStopped',
        data: 1,
      );
      await tester.pump();
      for (final button in tester.widgetList<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Grant exclusive control',
        ),
      )) {
        expect(button.onPressed, isNull);
      }
      expect(tester.takeException(), isNull);
    },
  );
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
