/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/settings_dialog.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/services/data_broker.dart';

/// Keep the shared settings surface usable on a phone-sized Android screen.
/// This also guards Android-only sections such as the hosted server, phone
/// location and speech-recognition setup from regressing as desktop settings
/// evolve.
void main() {
  testWidgets('Android settings expose the shared tabs on a phone screen', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    void set(String name, Object? data) =>
        DataBroker.dispatch(deviceId: 0, name: name, data: data, store: true);

    set('CallSign', 'KK7ABC');
    set('AprsIsEnabled', 1);
    set('AprsIsServer', 'aprs.example.net');
    set('AprsIsPort', 14580);
    set('AprsIsPasscode', '12345');
    set('ManualLocationEnabled', 1);
    set('ManualLatitude', 47.6062);
    set('ManualLongitude', -122.3321);

    try {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: Center(child: SettingsDialog())),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'initial build');

      // Android supports the same shared application tabs as desktop, plus
      // its own native service and phone-location controls within those tabs.
      expect(find.byType(Tab), findsNWidgets(10));
      expect(find.text('Servers'), findsOneWidget);
      expect(find.text('Map'), findsOneWidget);
      expect(find.text('Comms'), findsOneWidget);

      final tabs = find.byType(Tab);
      for (var i = 0; i < tabs.evaluate().length; i++) {
        await tester.ensureVisible(tabs.at(i));
        await tester.pumpAndSettle();
        await tester.tap(tabs.at(i), warnIfMissed: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: 'tab index $i');
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
