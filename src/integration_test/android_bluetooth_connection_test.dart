import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show ErrorWidget;
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/main.dart' as app;
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/db/app_database.dart';
import 'package:integration_test/integration_test.dart';

import 'support/android_bluetooth_connection_fixture.dart';

const _testRemotePassword = 'android-radio-server-test-password';

Future<void> _verifyRemoteServerSeesConnectedRadio(
  int port,
  int expectedRadioId,
) async {
  final base = Uri(scheme: 'http', host: '::1', port: port);
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final loginPage = await http.getUrl(base.replace(path: '/login'));
    final loginResponse = await loginPage.close();
    expect(loginResponse.statusCode, HttpStatus.ok);
    final csrf = loginResponse.cookies.singleWhere(
      (cookie) => cookie.name == 'htc_login',
    );
    await loginResponse.drain<void>();

    final login = await http.postUrl(base.replace(path: '/login'));
    login.followRedirects = false;
    login.cookies.add(csrf);
    login.headers.set('origin', base.origin);
    login.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    login.write(
      Uri(
        queryParameters: {'csrf': csrf.value, 'password': _testRemotePassword},
      ).query,
    );
    final loginResult = await login.close();
    expect(loginResult.statusCode, HttpStatus.seeOther);
    final session = loginResult.cookies.singleWhere(
      (cookie) => cookie.name == 'htc_bridge',
    );
    await loginResult.drain<void>();

    final socket = await WebSocket.connect(
      Uri(
        scheme: 'ws',
        host: '::1',
        port: port,
        path: '/websocket.aspx',
      ).toString(),
      headers: {'Origin': base.origin, 'Cookie': 'htc_bridge=${session.value}'},
    );
    final connectedState = Completer<Map<String, Object?>>();
    final subscription = socket.listen((event) {
      if (event is! String || !event.startsWith('remote:')) return;
      final message = jsonDecode(event.substring(7));
      if (message is! Map || message['state'] is! Map) return;
      final state = Map<String, Object?>.from(message['state'] as Map);
      if (!connectedState.isCompleted && state['connected'] == true) {
        connectedState.complete(state);
      }
    });
    try {
      socket.add('remote:{"op":"state"}');
      final state = await connectedState.future.timeout(
        const Duration(seconds: 5),
      );
      expect(state['radioId'], expectedRadioId);
      expect(state['connected'], isTrue);
      final dashboard = Map<String, Object?>.from(state['dashboard']! as Map);
      final radio = Map<String, Object?>.from(dashboard['radio']! as Map);
      expect(radio['link'], 'Connected');
    } finally {
      await subscription.cancel();
      await socket.close();
    }
  } finally {
    http.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android Classic Bluetooth connects and releases a mocked N7500',
    (tester) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      final originalFlutterErrorHandler = FlutterError.onError;
      try {
        app.main(<String>[]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        final startup = await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 120));
          while (DataBroker.getDataHandler<WebServerHandler>(
                    'WebServerHandler',
                  ) ==
                  null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return DataBroker.getDataHandler<WebServerHandler>(
            'WebServerHandler',
          );
        });
        expect(
          startup,
          isNotNull,
          reason: 'the Android app must finish startup',
        );
        expect(AppDatabase.instance, isNotNull);

        final server = DataBroker.getDataHandler<WebServerHandler>(
          'WebServerHandler',
        )!;
        await tester.runAsync(() async {
          void setServerSetting(String name, Object value) =>
              DataBroker.dispatch(
                deviceId: 0,
                name: name,
                data: value,
                store: true,
              );

          setServerSetting('webServerEnabled', 0);
          setServerSetting('webServerPort', 0);
          setServerSetting('webServerRemoteEnabled', 1);
          setServerSetting('webServerPassword', _testRemotePassword);
          setServerSetting('AllowTransmit', 0);
          setServerSetting('webServerAllowTransmit', 0);
          setServerSetting('webServerEnabled', 1);

          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (server.boundPort == null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(server.boundPort, isNotNull);

          try {
            await exerciseAndroidBluetoothClassicConnection(
              onConnected: (radioId) => _verifyRemoteServerSeesConnectedRadio(
                server.boundPort!,
                radioId,
              ),
            );
          } finally {
            setServerSetting('webServerEnabled', 0);
            final stopDeadline = DateTime.now().add(
              const Duration(seconds: 10),
            );
            while (server.boundPort != null &&
                DateTime.now().isBefore(stopDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(server.boundPort, isNull);
          }
        });
      } finally {
        ErrorWidget.builder = originalErrorWidgetBuilder;
        FlutterError.onError = originalFlutterErrorHandler;
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
