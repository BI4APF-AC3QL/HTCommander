import 'dart:convert';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/offline_simulation_dialog.dart';
import 'package:htcommander/dialogs/remote_access_dialog.dart';
import 'package:htcommander/handlers/debug_log_handler.dart';
import 'package:htcommander/services/crash_logger.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/diagnostic_log.dart';
import 'package:htcommander/services/offline_simulation.dart';

class _PrivateError {
  @override
  String toString() => throw StateError('Must not stringify credentials');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DataBroker.reset);
  test(
    'local redaction and strict export omit free text, nested data and poisoned timestamps',
    () {
      const secret = 'arbitrary-private-value';
      expect(
        DiagnosticLog.localText('Failed $secret', secrets: [secret]),
        'Failed [redacted]',
      );
      for (final value in [
        'Authorization: Bearer $secret',
        'cookie: htc_bridge=$secret',
        'passcode=$secret',
        'BEGIN PRIVATE KEY $secret',
        'GPS latitude=30 longitude=120',
        'W1AW>APRS::W2AW:private message',
        'Raw frame TX [private bytes]',
      ]) {
        expect(
          DiagnosticLog.localText(value),
          '[sensitive diagnostic text omitted]',
        );
      }
      final local = DiagnosticLog.localText(
        r'Failed https://secret.example/path?x=key C:\Users\Private\log 127.0.0.1 2001:db8::1',
      );
      expect(local, isNot(contains('secret.example')));
      expect(local, isNot(contains('Private')));
      expect(local, isNot(contains('127.0.0.1')));
      expect(local, isNot(contains('2001:db8')));
      expect(
        DiagnosticLog.localText('x' * 500000).length,
        lessThanOrEqualTo(2049),
      );
      final exported = DiagnosticLog.export([
        {'time': secret, 'message': secret, 'token': secret, 'isError': true},
        {
          'time': '2026-01-01T01:00:00Z',
          'message': 'invisible content',
          'isError': false,
        },
      ]);
      expect(exported, isNot(contains(secret)));
      expect(exported, isNot(contains('invisible content')));
      expect((jsonDecode(exported)['entries'] as List).first, {
        'level': 'error',
        'code': 'applicationDiagnostic',
      });
    },
  );

  test(
    'production log handler bounds flooding, coalesces immutable snapshots and cancels on dispose',
    () {
      fakeAsync((async) {
        final handler = DebugLogHandler();
        final observer = DataBrokerClient();
        final snapshots = <List>[];
        observer.subscribe(
          deviceId: 1,
          name: 'DebugLogEntries',
          callback: (_, _, value) => snapshots.add(value as List),
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'webServerPassword',
          data: 'private-credential',
        );
        handler.init();
        for (var i = 0; i < 1000; i++) {
          DataBroker.dispatch(
            deviceId: 1,
            name: 'LogError',
            data: 'Error $i private-credential',
            store: false,
          );
        }
        expect(snapshots, isEmpty);
        async.elapse(const Duration(milliseconds: 250));
        expect(snapshots, hasLength(1));
        expect(snapshots.single, hasLength(200));
        expect(
          jsonEncode(snapshots.single),
          isNot(contains('private-credential')),
        );
        expect(() => snapshots.single.clear(), throwsUnsupportedError);
        final original = jsonEncode(snapshots.single);
        DataBroker.dispatch(
          deviceId: 1,
          name: 'LogInfo',
          data: 'after',
          store: false,
        );
        async.elapse(const Duration(milliseconds: 250));
        expect(jsonEncode(snapshots.first), original);
        DataBroker.dispatch(
          deviceId: 1,
          name: 'ClearDebugLog',
          data: null,
          store: false,
        );
        expect(snapshots.last, isEmpty);
        DataBroker.dispatch(
          deviceId: 1,
          name: 'LogInfo',
          data: 'pending',
          store: false,
        );
        final count = snapshots.length;
        handler.dispose();
        async.elapse(const Duration(seconds: 1));
        expect(snapshots.length, count);
        observer.dispose();
      });
    },
  );

  test(
    'crash metadata never stringifies error or shares legacy path/content',
    () {
      final text = DiagnosticLog.crashRecord(
        'password secret',
        _PrivateError(),
        StackTrace.fromString(
          '#0 fail (package:htcommander/services/web_server.dart:12:3)\n'
          '#1 secret (file:///C:/Users/private/credential.dart:1:1)',
        ),
      );
      expect(
        text,
        '[ERROR] applicationError runtimeError sites=web_server.dart:12:3',
      );
      final safe = DiagnosticLog.safeCrashTail(
        '[2026-01-01T00:00:00.000Z] $text\n'
        '[2026-01-01T00:00:00.000Z] legacy password and content\nsecret',
      );
      expect(safe, contains('web_server.dart:12:3'));
      expect(safe, isNot(contains('password')));
      expect(safe, isNot(contains('secret')));
    },
  );

  test(
    'asynchronous crash writer serializes, caps queue and rotates bounded files',
    () async {
      final dir = await Directory.systemTemp.createTemp('htc-private-log-test');
      try {
        final file = File('${dir.path}/diagnostic.log');
        final logger = CrashLogger.forTesting(file, maxBytes: 2048);
        for (var i = 0; i < 300; i++) {
          logger.logError('secret-$i', _PrivateError());
        }
        expect(logger.droppedRecords, 236);
        await logger.flush();
        expect(await file.length(), lessThanOrEqualTo(2048));
        expect(await File('${file.path}.1').length(), lessThanOrEqualTo(2048));
        expect(await file.readAsString(), isNot(contains('secret')));
        expect(
          await logger.readRecentError(),
          contains('applicationError runtimeError'),
        );
        logger.logError('Uncaught error', StateError('private message'));
        await logger.flush();
        expect(await logger.readTail(), contains('uncaughtError stateError'));
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'sandbox uses production ACK/retry/timeout with exact matching and no broker requests',
    () {
      final observer = DataBrokerClient();
      var brokerEvents = 0;
      observer.subscribeAll(callback: (_, _, _) => brokerEvents++);
      final simulation = OfflineSimulation();
      expect(simulation.createMessage(), false);
      simulation.connect();
      expect(simulation.createMessage(), true);
      expect(simulation.reply('999'), false);
      expect(simulation.reply('1'), true);
      expect(simulation.deliveries.first['status'], 'acknowledged');
      simulation.createMessage();
      simulation.reply('2', rejected: true);
      expect(simulation.deliveries.last['status'], 'rejected');
      simulation.createMessage();
      simulation.advance();
      expect(simulation.deliveries.last['attempts'], 2);
      simulation.advance();
      expect(simulation.deliveries.last['attempts'], 3);
      simulation.advance();
      expect(simulation.deliveries.last['status'], 'timedOut');
      simulation.createMessage();
      simulation.disconnect();
      expect(simulation.deliveries.last['status'], 'cancelled');
      simulation.connect();
      simulation.advance();
      expect(simulation.deliveries.last['attempts'], 1);
      expect(brokerEvents, 0);
      simulation.dispose();
      simulation.connect();
      expect(simulation.createMessage(), false);
      observer.dispose();
    },
  );

  test(
    'sandbox caps history and measures synthetic receive payload without playback',
    () {
      final simulation = OfflineSimulation()..connect();
      for (var i = 0; i < 20; i++) {
        expect(simulation.createMessage(), true);
      }
      expect(simulation.createMessage(), false);
      simulation.reply('1');
      expect(simulation.createMessage(), true);
      expect(simulation.deliveries, hasLength(20));
      for (var i = 0; i < 10; i++) {
        simulation.receiveTone();
      }
      expect(simulation.rxFrames, 10);
      expect(simulation.normalBytes, 64040);
      expect(simulation.lowBytes, 16040);
      simulation.disconnect();
      simulation.receiveTone();
      expect(simulation.rxFrames, 10);
      simulation.dispose();
    },
  );

  testWidgets(
    '390px sandbox UI stays isolated, handles ACK/RX/disconnect and closes cleanly',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final observer = DataBrokerClient();
      var requests = 0;
      observer.subscribeAll(callback: (_, _, _) => requests++);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const OfflineSimulationDialog(),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('模拟连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建模拟 APRS'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('模拟 ACK'));
      await tester.tap(find.text('模拟 ACK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('acknowledged'), findsOneWidget);
      await tester.ensureVisible(find.text('模拟接收音频'));
      await tester.tap(find.text('模拟接收音频'));
      await tester.pumpAndSettle();
      expect(find.textContaining('6404 / 1604'), findsOneWidget);
      await tester.tap(find.text('模拟断开'));
      await tester.pumpAndSettle();
      expect(find.text('模拟断开 / Simulated disconnected'), findsOneWidget);
      expect(requests, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭 / Close'));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineSimulationDialog), findsNothing);
      observer.dispose();
    },
  );

  test(
    'legacy crash fallback and user paths never enter an issue body',
    () async {
      final dir = await Directory.systemTemp.createTemp('htc-legacy-log-test');
      try {
        final file = File('${dir.path}/legacy.log');
        await file.writeAsString(
          'legacy Authorization: Bearer private-credential\nC:/Users/private\n',
        );
        final logger = CrashLogger.forTesting(file);
        expect(await logger.readTail(), isEmpty);
        final issue = await logger.buildGithubIssueUri(
          fallbackLog: 'private-message-text',
        );
        final body = issue.queryParameters['body']!;
        expect(body, isNot(contains('private-credential')));
        expect(body, isNot(contains('private-message-text')));
        expect(body, isNot(contains(dir.path)));
        expect(body, contains('free-text diagnostic fallback omitted'));
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'host settings opens sandbox and copies metadata without secrets at 390px',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      DataBroker.dispatch(
        deviceId: 1,
        name: 'DebugLogEntries',
        data: [
          {
            'time': '2026-01-01T00:00:00Z',
            'message': 'private-credential unknown payload',
            'isError': true,
          },
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RemoteAccessDialog())),
      );
      await tester.pumpAndSettle();
      final exportButton = find.text('Copy private diagnostic metadata');
      await tester.ensureVisible(exportButton);
      await tester.tap(exportButton);
      await tester.pumpAndSettle();
      expect(copied, isNotNull);
      expect(copied, isNot(contains('private-credential')));
      final sandbox = find.text('Offline simulation');
      await tester.ensureVisible(sandbox);
      await tester.tap(sandbox);
      await tester.pumpAndSettle();
      expect(find.byType(OfflineSimulationDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭 / Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
