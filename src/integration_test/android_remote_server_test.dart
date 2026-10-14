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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android remote server starts, authenticates, serves the hosted UI, and stops',
    (tester) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      final originalFlutterErrorHandler = FlutterError.onError;
      try {
        app.main(<String>[]);
        await tester.pump(const Duration(seconds: 1));

        final handler = await tester.runAsync(() async {
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
          handler,
          isNotNull,
          reason: 'the Android app must finish startup',
        );
        expect(
          AppDatabase.instance,
          isNotNull,
          reason: 'Android SQLite initialization must succeed before startup',
        );

        final server = handler!;
        HttpClient? http;
        try {
          // Port zero lets Android choose a free ephemeral port for this test.
          // The app's regular settings and validation path still starts the
          // native foreground service before opening the real Dart HTTP socket.
          DataBroker.dispatch(deviceId: 0, name: 'webServerEnabled', data: 0);
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (server.boundPort != null &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          });
          expect(
            server.boundPort,
            isNull,
            reason: 'the test must start from a stopped server',
          );
          DataBroker.dispatch(deviceId: 0, name: 'webServerPort', data: 0);
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerRemoteEnabled',
            data: 1,
          );
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerPassword',
            data: 'AndroidIntegrationTestPassword',
          );
          DataBroker.dispatch(deviceId: 0, name: 'webServerEnabled', data: 1);

          final port = await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 30));
            while (server.boundPort == null &&
                DateTime.now().isBefore(deadline)) {
              final status =
                  DataBroker.getValue<String>(0, 'webServerStatus', '') ?? '';
              if (status.startsWith('Failed') ||
                  status.startsWith('Android foreground service failed')) {
                throw StateError(
                  'Android remote server did not start: $status',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            return server.boundPort;
          });
          expect(port, isNotNull, reason: 'the real HTTP listener must bind');

          http = HttpClient();
          await tester.runAsync(() async {
            final base = Uri(scheme: 'http', host: '::1', port: port!);

            final unauthenticatedRequest = await http!.getUrl(
              base.resolve('/index.html'),
            );
            unauthenticatedRequest.followRedirects = false;
            final unauthenticatedResponse = await unauthenticatedRequest
                .close();
            expect(unauthenticatedResponse.statusCode, HttpStatus.seeOther);
            expect(
              unauthenticatedResponse.headers.value(HttpHeaders.locationHeader),
              '/login',
            );
            await unauthenticatedResponse.drain<void>();

            final formRequest = await http!.getUrl(base.resolve('/login'));
            final formResponse = await formRequest.close();
            expect(formResponse.statusCode, HttpStatus.ok);
            final csrf = formResponse.cookies.singleWhere(
              (cookie) => cookie.name == 'htc_login',
            );
            expect(
              await utf8.decoder.bind(formResponse).join(),
              contains('远程访问密码'),
            );

            final loginRequest = await http!.postUrl(base.resolve('/login'));
            loginRequest.followRedirects = false;
            loginRequest.cookies.add(csrf);
            loginRequest.headers.set('origin', base.origin);
            loginRequest.headers.contentType = ContentType(
              'application',
              'x-www-form-urlencoded',
            );
            loginRequest.write(
              Uri(
                queryParameters: {
                  'csrf': csrf.value,
                  'password': 'AndroidIntegrationTestPassword',
                },
              ).query,
            );
            final loginResponse = await loginRequest.close();
            expect(loginResponse.statusCode, HttpStatus.seeOther);
            expect(
              loginResponse.headers.value(HttpHeaders.locationHeader),
              '/remote.html',
            );
            final session = loginResponse.cookies.singleWhere(
              (cookie) => cookie.name == 'htc_bridge',
            );
            await loginResponse.drain<void>();

            final remoteRequest = await http!.getUrl(
              base.resolve('/remote.html'),
            );
            remoteRequest.cookies.add(session);
            final remoteResponse = await remoteRequest.close();
            expect(remoteResponse.statusCode, HttpStatus.ok);
            expect(
              await utf8.decoder.bind(remoteResponse).join(),
              contains('操作权'),
            );

            final appRequest = await http!.getUrl(base.resolve('/index.html'));
            appRequest.cookies.add(session);
            final appResponse = await appRequest.close();
            expect(appResponse.statusCode, HttpStatus.ok);
            expect(
              await utf8.decoder.bind(appResponse).join(),
              contains('flutter_bootstrap.js'),
            );

            final scriptRequest = await http!.getUrl(
              base.resolve('/main.dart.js'),
            );
            scriptRequest.cookies.add(session);
            final scriptResponse = await scriptRequest.close();
            expect(scriptResponse.statusCode, HttpStatus.ok);
            expect(
              scriptResponse.headers.contentType?.mimeType,
              'application/javascript',
            );
            final scriptBytes = await scriptResponse.fold<int>(
              0,
              (total, chunk) => total + chunk.length,
            );
            expect(scriptBytes, greaterThan(100000));

            final wasmRequest = await http!.getUrl(
              base.resolve('/canvaskit/canvaskit.wasm'),
            );
            wasmRequest.cookies.add(session);
            final wasmResponse = await wasmRequest.close();
            expect(wasmResponse.statusCode, HttpStatus.ok);
            expect(
              wasmResponse.headers.contentType?.mimeType,
              'application/wasm',
            );
            await wasmResponse.drain<void>();
          });
        } finally {
          http?.close(force: true);
          DataBroker.dispatch(deviceId: 0, name: 'webServerEnabled', data: 0);
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerRemoteEnabled',
            data: 0,
          );
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerPassword',
            data: '',
            allowEmpty: true,
          );
          DataBroker.dispatch(deviceId: 0, name: 'webServerPort', data: 8080);
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (server.boundPort != null &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
          });
        }
      } finally {
        ErrorWidget.builder = originalErrorWidgetBuilder;
        FlutterError.onError = originalFlutterErrorHandler;
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
