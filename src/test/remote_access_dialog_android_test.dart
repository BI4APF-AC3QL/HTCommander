/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/remote_access_dialog.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

void main() {
  tearDown(DataBroker.reset);

  for (final width in <double>[320, 393]) {
    testWidgets('Android remote client controls fit ${width.toInt()}dp', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = Size(width, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final reportedErrors = <FlutterErrorDetails>[];
      final previousErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        reportedErrors.add(details);
        previousErrorHandler?.call(details);
      };
      addTearDown(() => FlutterError.onError = previousErrorHandler);

      DataBroker.dispatch(
        deviceId: 0,
        name: 'RemoteClients',
        data: [
          {
            'id': 17,
            'address': '192.0.2.17',
            'ownsControl': false,
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
        names: const [
          'RemoteControlGrant',
          'RemoteClientRole',
          'RemoteClientRevoke',
        ],
        callback: (_, name, value) => commands[name] = value,
      );

      final locale = width == 320 ? const Locale('zh') : const Locale('en');
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => RemoteAccessDialog(
                      addressLoader: () async => ['192.0.2.1'],
                      networkChanges:
                          const Stream<List<ConnectivityResult>>.empty(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final hasClient = find.text('#17 · 192.0.2.17').evaluate().length == 1;
      final hasGrant = find.byIcon(Icons.gamepad).evaluate().length == 1;
      final hasRoleToggle = find.byIcon(Icons.lock).evaluate().length == 1;
      final hasRevoke = find.byIcon(Icons.person_remove).evaluate().length == 1;
      final hasHostApproval =
          find
              .text(
                locale.languageCode == 'zh'
                    ? '控制权申请必须由主机批准'
                    : 'Host approval required for control',
              )
              .evaluate()
              .length ==
          1;
      final hasAndroidInstructions = find
          .textContaining(
            locale.languageCode == 'zh'
                ? '同一 Wi-Fi：另一台手机访问上方本机 IP 和端口。'
                : 'On the same Wi-Fi, open the local IP and port above on another device.',
          )
          .evaluate()
          .isNotEmpty;
      final hasWindowsSpecificCopy = find
          .textContaining('Windows')
          .evaluate()
          .isNotEmpty;

      final grant = find.byIcon(Icons.gamepad);
      await tester.ensureVisible(grant);
      await tester.tap(grant);
      await tester.pump();
      final role = find.byIcon(Icons.lock);
      await tester.ensureVisible(role);
      await tester.tap(role);
      await tester.pump();
      final revoke = find.byIcon(Icons.person_remove);
      await tester.ensureVisible(revoke);
      await tester.tap(revoke);
      await tester.pump();

      final exception = tester.takeException();
      FlutterError.onError = previousErrorHandler;
      debugDefaultTargetPlatformOverride = null;
      expect(hasClient, isTrue);
      expect(hasGrant, isTrue);
      expect(hasRoleToggle, isTrue);
      expect(hasRevoke, isTrue);
      expect(hasHostApproval, isTrue);
      expect(hasAndroidInstructions, isTrue);
      expect(hasWindowsSpecificCopy, isFalse);
      expect(commands['RemoteControlGrant'], 17);
      expect(commands['RemoteClientRole'], {'id': 17, 'readOnly': false});
      expect(commands['RemoteClientRevoke'], 17);
      expect(exception, isNull);
      expect(reportedErrors, isEmpty);
    });
  }
}
