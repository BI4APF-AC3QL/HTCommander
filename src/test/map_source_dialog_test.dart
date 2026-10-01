import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/map_source_dialog.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/utils/map_source.dart';

void main() {
  tearDown(DataBroker.reset);
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMapSourceDialog(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('select, apply and reopen a different map source', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Esri World Street Map').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(MapSource.current.id, 'esri-street');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Esri World Street Map'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'custom template validates before saving and preserves attribution',
    (tester) async {
      await open(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom XYZ').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'https://tiles.example/no-coordinates',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.byType(MapSourceDialog), findsOneWidget);
      expect(MapSource.current.id, 'osm');
      await tester.enterText(
        find.byType(TextFormField).first,
        'https://tiles.example/{z}/{x}/{y}.png',
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'My map provider',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(MapSource.current.id, 'custom');
      expect(MapSource.current.attribution, 'My map provider');
      expect(tester.takeException(), isNull);
    },
  );
}
