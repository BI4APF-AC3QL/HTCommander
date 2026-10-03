import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/web/aprs_shortcuts.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';
import 'package:htcommander/dialogs/aprs_shortcuts_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DataBroker.reset);
  test(
    'parse normalizes callsigns, deduplicates and roundtrips named templates',
    () {
      final value = AprsShortcuts.parse(
        'bi4apf-7\nW1AW\nBI4APF-7',
        'CQ: CQ test\nReply: Thanks: 73',
      );
      final copy = AprsShortcuts.decode(value.encode());
      expect(copy.favorites, ['BI4APF-7', 'W1AW']);
      expect(copy.templates.last.text, 'Thanks: 73');
      expect(() => copy.favorites.add('CALL'), throwsUnsupportedError);
    },
  );
  test('limits and protocol restrictions reject invalid host shortcuts', () {
    for (final call in ['CALL-16', 'CALL<script>', 'TOOLONG7']) {
      expect(() => AprsShortcuts.parse(call, ''), throwsFormatException);
    }
    expect(
      () => AprsShortcuts.parse(List.generate(21, (i) => 'A$i').join('\n'), ''),
      throwsFormatException,
    );
    expect(
      () => AprsShortcuts.parse(
        '',
        List.generate(17, (i) => 'T$i: Hello').join('\n'),
      ),
      throwsFormatException,
    );
    for (final line in [
      'No separator',
      'CQ: 中文消息',
      'CQ: hello|world',
      'CQ: ${'A' * 68}',
      'CQ: hi\ncq: again',
    ]) {
      expect(() => AprsShortcuts.parse('', line), throwsFormatException);
    }
    expect(AprsShortcuts.decode('invalid').favorites, isEmpty);
    expect(AprsShortcuts.decode('x' * 16385).templates, isEmpty);
  });
  test(
    'saved and deliberately cleared shortcuts persist through broker reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      await DataBroker.initialize();
      AprsShortcuts.parse('W1AW', 'CQ: CQ test').save();
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('databroker_${AprsShortcuts.setting}');
      expect(saved, isNotNull);
      DataBroker.reset();
      await DataBroker.initialize();
      expect(AprsShortcuts.current.favorites, ['W1AW']);
      AprsShortcuts().save();
      DataBroker.reset();
      await DataBroker.initialize();
      expect(AprsShortcuts.current.favorites, isEmpty);
      expect(AprsShortcuts.current.templates, isEmpty);
    },
  );
  test('phone snapshot supplies shortcuts without generating send events', () {
    var sends = 0;
    final observer = DataBrokerClient()
      ..subscribe(
        deviceId: 1,
        name: 'SendAprsMessage',
        callback: (_, _, _) => sends++,
      );
    addTearDown(observer.dispose);
    AprsShortcuts.parse('W1AW', 'CQ: Hello').save();
    final controller = RemoteRadioController(target: () => 2);
    final snapshot = controller.snapshot(1);
    expect((snapshot['aprsShortcuts'] as Map)['favorites'], ['W1AW']);
    expect(sends, 0);
  });
  testWidgets('host editor validates and saves on a narrow display', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AprsShortcutsDialog())),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'CALL-16');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid callsign/SSID.'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'bi4apf-7');
    await tester.enterText(find.byType(TextField).last, 'CQ: CQ test');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(AprsShortcuts.current.favorites, ['BI4APF-7']);
    expect(AprsShortcuts.current.templates.single.text, 'CQ test');
    expect(tester.takeException(), isNull);
  });
}
