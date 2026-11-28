import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/remote_profile_dialog.dart';
import 'package:htcommander/dialogs/settings_dialog.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/web/remote_profile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (_) async => null),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null),
  );
  void set(String key, Object? value) =>
      DataBroker.dispatch(deviceId: 0, name: key, data: value);
  String profile(Map<String, Object> values) => jsonEncode({
    'format': RemoteProfile.format,
    'version': 1,
    'settings': values,
  });
  tearDown(DataBroker.reset);
  test(
    'export uses whitelist and excludes credentials, private URLs and runtime payloads',
    () {
      for (final entry in {
        'webServerPassword': 'private-password',
        'MapCustomUrl': 'https://private/token',
        'PrivateKey': 'private-key',
        'RemoteAprsShortcuts': 'private-message',
        'RemoteClients': [
          {'address': 'private-address'},
        ],
        'Position': 'private-position',
        'webServerEnabled': 1,
        'webServerAllowAprs': 1,
        'MapSource': 'custom',
        'webServerPublicOrigin': 'https://radio.example:8443/',
        'webServerPort': 18081,
      }.entries) {
        set(entry.key, entry.value);
      }
      final encoded = RemoteProfile.export();
      for (final secret in [
        'private-password',
        'private-message',
        'private-address',
        'private-position',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(encoded, isNot(contains('https://private')));
      final values = (jsonDecode(encoded) as Map)['settings'] as Map;
      expect(values['MapSource'], 'osm');
      expect(values['webServerPublicOrigin'], 'https://radio.example:8443');
      expect(values['webServerPort'], 18081);
      expect(values.keys.toSet(), RemoteProfile.defaults.keys.toSet());
      final plan = RemoteProfile.preview(encoded);
      expect(plan.values, values);
      expect(() => plan.values['webServerPort'] = 1, throwsUnsupportedError);
    },
  );
  test(
    'invalid versions, fields, URLs, paths, numeric types and oversized input fail before writes',
    () {
      set('webServerPort', 8080);
      for (final input in [
        '{}',
        'invalid',
        'x' * 32769,
        jsonEncode({
          'format': RemoteProfile.format,
          'version': 2,
          'settings': {'webServerPort': 18080},
        }),
        profile({'webServerPassword': 'private-secret'}),
        profile({'AllowTransmit': 1}),
        profile({'webServerPort': 0}),
        profile({'webServerPort': 1.5}),
        profile({'webServerPort': 65536}),
        profile({'webServerDefaultReadOnly': true}),
        profile({'webServerPublicOrigin': 'https://user:password@example.com'}),
        profile({
          'webServerPublicOrigin': 'https://radio.example?token=secret',
        }),
        profile({'AprsIsServer': 'radio.example/path'}),
        profile({'AprsIsServer': 'radio.example:14580'}),
        profile({'AprsIsRfPath': 'TCPIP*'}),
        profile({'AprsIsRfPerMinute': 31}),
        profile({'MapSource': 'custom'}),
      ]) {
        expect(() => RemoteProfile.preview(input), throwsFormatException);
        expect(DataBroker.getValueDynamic(0, 'webServerPort'), 8080);
      }
      expect(
        RemoteProfile.preview(
          profile({'AprsIsServer': '2001:db8::1'}),
        ).values['AprsIsServer'],
        '2001:db8::1',
      );
    },
  );
  test(
    'preview is inert; apply stops before endpoint changes without touching secrets or replay',
    () {
      final observer = DataBrokerClient();
      final events = <String>[];
      observer.subscribe(
        deviceId: DataBroker.allDevices,
        name: DataBroker.allNames,
        callback: (_, name, _) => events.add(name),
      );
      for (final key in RemoteProfile.stoppedSettings.keys) {
        set(key, 1);
      }
      set('webServerPassword', 'private-password');
      set('MapCustomUrl', 'private-map');
      set('webServerPort', 8080);
      events.clear();
      final plan = RemoteProfile.preview(
        profile({'webServerPort': 18080, 'AprsIsRfPerMinute': 3}),
      );
      expect(events, isEmpty);
      expect(plan.canApply, true);
      plan.apply();
      for (final entry in RemoteProfile.stoppedSettings.entries) {
        expect(DataBroker.getValueDynamic(0, entry.key), entry.value);
      }
      expect(
        events.indexOf('CancelRemoteAprs'),
        lessThan(events.indexOf('webServerPort')),
      );
      expect(
        events.indexOf('AllowTransmit'),
        lessThan(events.indexOf('AprsIsRfPerMinute')),
      );
      expect(
        DataBroker.getValueDynamic(0, 'webServerPassword'),
        'private-password',
      );
      expect(DataBroker.getValueDynamic(0, 'MapCustomUrl'), 'private-map');
      expect(DataBroker.getValueDynamic(0, 'RemoteProfileRevision'), 1);
      expect(plan.canApply, false);
      expect(() => plan.apply(), throwsStateError);
      expect(events.where((e) => e == 'CancelRemoteAprs'), hasLength(1));
      observer.dispose();
    },
  );
  test('settings changed after preview require a new plan', () {
    set('webServerPort', 8080);
    final plan = RemoteProfile.preview(profile({'webServerPort': 18080}));
    set('webServerPort', 18081);
    expect(plan.canApply, false);
    expect(() => plan.apply(), throwsStateError);
    expect(DataBroker.getValueDynamic(0, 'webServerPort'), 18081);
  });
  testWidgets(
    'host clipboard export and explicit preview/apply fit narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      set('webServerPort', 8080);
      set('webServerPassword', 'private-password');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => const RemoteProfileDialog(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy saved profile JSON'));
      await tester.pumpAndSettle();
      expect(copied, isNotNull);
      expect(copied, isNot(contains('private-password')));
      await tester.enterText(
        find.byKey(const Key('profileInput')),
        profile({'webServerPort': 18080}),
      );
      await tester.ensureVisible(find.text('Preview import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview import'));
      await tester.pumpAndSettle();
      expect(DataBroker.getValueDynamic(0, 'webServerPort'), 8080);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('profileApply')))
            .onPressed,
        isNull,
      );
      final check = find.byKey(const Key('profileConfirm'));
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profileApply')));
      await tester.pumpAndSettle();
      expect(DataBroker.getValueDynamic(0, 'webServerPort'), 18080);
      expect(DataBroker.getValueDynamic(0, 'AllowTransmit'), 0);
      expect(find.byType(RemoteProfileDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'nested import cannot be undone by saving the stale parent settings',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      set('CallSign', 'W1AW');
      set('AllowTransmit', 1);
      set('AprsIsEnabled', 1);
      set('webServerEnabled', 1);
      set('webServerPort', 8080);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => const SettingsDialog(initialTab: 6),
                ),
                child: const Text('settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Phone remote control settings'));
      await tester.tap(find.text('Phone remote control settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Remote profile import / export'));
      await tester.tap(find.text('Remote profile import / export'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('profileInput')),
        profile({
          'webServerPort': 18080,
          'AprsIsServer': 'test.example',
          'AprsIsPort': 14581,
          'AprsIsRangeKm': 123,
        }),
      );
      await tester.ensureVisible(find.text('Preview import'));
      await tester.tap(find.text('Preview import'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('profileConfirm')));
      await tester.tap(find.byKey(const Key('profileConfirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profileApply')));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteProfileDialog), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(DataBroker.getValueDynamic(0, 'webServerPort'), 18080);
      expect(DataBroker.getValueDynamic(0, 'AprsIsServer'), 'test.example');
      expect(DataBroker.getValueDynamic(0, 'AprsIsPort'), 14581);
      expect(DataBroker.getValueDynamic(0, 'AprsIsRangeKm'), 123);
      expect(DataBroker.getValueDynamic(0, 'AllowTransmit'), 0);
      expect(DataBroker.getValueDynamic(0, 'webServerEnabled'), 0);
      expect(DataBroker.getValueDynamic(0, 'AprsIsEnabled'), 0);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
