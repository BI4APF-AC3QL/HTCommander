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
void _recordLayoutException(
  WidgetTester tester,
  String reason,
  List<FlutterErrorDetails> reportedErrors,
  List<String> failures,
) {
  final exception = tester.takeException();
  if (exception == null) {
    reportedErrors.clear();
    return;
  }
  final diagnostics = reportedErrors
      .map((error) => error.toString())
      .join('\n');
  reportedErrors.clear();
  final details = exception is FlutterError
      ? exception.toStringDeep()
      : exception.toString();
  failures.add('$reason:\n$diagnostics\n$details');
}

void main() {
  for (final width in <double>[393, 320]) {
    final locale = width == 320 ? const Locale('zh') : const Locale('en');
    testWidgets(
      'Android settings fit ${width.toInt()}dp ${locale.languageCode}',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = Size(width, 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final reportedErrors = <FlutterErrorDetails>[];
        final layoutFailures = <String>[];
        final previousErrorHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          reportedErrors.add(details);
          previousErrorHandler?.call(details);
        };

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
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const Scaffold(body: Center(child: SettingsDialog())),
            ),
          );
          await tester.pump();
          _recordLayoutException(
            tester,
            'initial build',
            reportedErrors,
            layoutFailures,
          );

          // Android supports the same shared application tabs as desktop, plus
          // its own native service and phone-location controls within those tabs.
          expect(find.byType(Tab), findsNWidgets(10));
          if (locale.languageCode == 'en') {
            expect(find.text('Servers'), findsOneWidget);
            expect(find.text('Map'), findsOneWidget);
            expect(find.text('Comms'), findsOneWidget);
          }

          final tabs = find.byType(Tab);
          for (var i = 0; i < tabs.evaluate().length; i++) {
            await tester.ensureVisible(tabs.at(i));
            // The Comms page can show an intentional loading spinner while the
            // native speech capabilities are checked, so settling may never end.
            await tester.pump(const Duration(milliseconds: 300));
            await tester.tap(tabs.at(i), warnIfMissed: false);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            _recordLayoutException(
              tester,
              'tab index $i',
              reportedErrors,
              layoutFailures,
            );
          }
          if (layoutFailures.isNotEmpty) fail(layoutFailures.join('\n\n'));
        } finally {
          FlutterError.onError = previousErrorHandler;
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
