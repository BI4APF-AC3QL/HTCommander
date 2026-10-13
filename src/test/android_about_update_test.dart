import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/about_dialog.dart';
import 'package:htcommander/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const packageInfo = MethodChannel('dev.fluttercommunity.plus/package_info');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(packageInfo, null);
  });

  testWidgets('Android About dialog exposes its release update path', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(packageInfo, (call) async {
            return <String, Object>{
              'appName': 'HTCommander',
              'packageName': 'com.meshcentral.htcommander',
              'version': '0.1.0',
              'buildNumber': '1',
            };
          });

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const HTAboutDialog(),
                ),
                child: const Text('Open About'),
              ),
            ),
          ),
        ),
      );

      final updateLabel = AppLocalizations.of(
        tester.element(find.text('Open About')),
      ).aboutCheckForUpdates;

      await tester.tap(find.text('Open About'));
      await tester.pumpAndSettle();

      expect(find.text(updateLabel), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
