import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show ErrorWidget;
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/main.dart' as app;
import 'package:htcommander/radio/gaia_protocol.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/db/app_database.dart';
import 'package:integration_test/integration_test.dart';

import 'support/android_bluetooth_connection_fixture.dart';

const _testRemotePassword = 'android-radio-server-test-password';

Future<void> _verifyRemoteServerSeesConnectedRadio(
  int port,
  int expectedRadioId,
  List<Uint8List> bluetoothWrites,
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
    Completer<Map<String, Object?>>? pendingResponse;
    final subscription = socket.listen((event) {
      if (event is! String || !event.startsWith('remote:')) return;
      final message = jsonDecode(event.substring(7));
      if (message is! Map) return;
      final response = pendingResponse;
      if (response != null && !response.isCompleted) {
        pendingResponse = null;
        response.complete(Map<String, Object?>.from(message));
      }
    });

    Future<Map<String, Object?>> sendCommand(Map<String, Object?> command) {
      final response = Completer<Map<String, Object?>>();
      pendingResponse = response;
      socket.add('remote:${jsonEncode(command)}');
      return response.future.timeout(const Duration(seconds: 5));
    }

    try {
      final initial = await sendCommand({'op': 'state'});
      final state = Map<String, Object?>.from(initial['state']! as Map);
      expect(state['radioId'], expectedRadioId);
      expect(state['connected'], isTrue);
      final dashboard = Map<String, Object?>.from(state['dashboard']! as Map);
      final radio = Map<String, Object?>.from(dashboard['radio']! as Map);
      expect(radio['link'], 'Connected');

      final control = await sendCommand({'op': 'requestControl'});
      final controlledState = Map<String, Object?>.from(
        control['state']! as Map,
      );
      expect(controlledState['controlOwner'], control['clientId']);

      Future<void> sendVolumeAndVerify(int level) async {
        final writeCount = bluetoothWrites.length;
        final volume = await sendCommand({'op': 'volume', 'value': level});
        expect(volume['error'], isNull);
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        bool volumeCommandReachedBluetooth() => bluetoothWrites
            .skip(writeCount)
            .any(
              (frame) =>
                  frame.length >= 9 &&
                  frame[0] == 0xFF &&
                  frame[1] == 0x01 &&
                  frame[4] == 0 &&
                  frame[5] == RadioCommandGroup.basic.value &&
                  frame[6] == 0 &&
                  frame[7] == RadioBasicCommand.setVolume.value &&
                  frame[8] == level,
            );

        while (!volumeCommandReachedBluetooth() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          volumeCommandReachedBluetooth(),
          isTrue,
          reason: 'remote volume must reach the Android Classic radio bridge',
        );
      }

      await sendVolumeAndVerify(8);

      // The host-side emulator script backgrounds MainActivity after this
      // marker. Keep the authenticated socket open so the next requests prove
      // that the radio and server remain connected together in the background.
      // ignore: avoid_print
      print('HTC_ANDROID_BT_REMOTE_BG_ACCEPTANCE_READY:$port');
      // Leave enough time for the emulator driver to background the Activity,
      // turn the display off and verify the forwarded HTTP endpoint while the
      // same radio connection and authenticated WebSocket remain active.
      await Future<void>.delayed(const Duration(seconds: 20));
      final background = await sendCommand({'op': 'state'});
      final backgroundState = Map<String, Object?>.from(
        background['state']! as Map,
      );
      expect(backgroundState['radioId'], expectedRadioId);
      expect(backgroundState['connected'], isTrue);
      await sendVolumeAndVerify(9);
    } finally {
      await subscription.cancel();
      await socket.close();
    }
  } finally {
    http.close(force: true);
  }
}

Future<void> _verifyHttpsProxySession(
  int port,
  int expectedRadioId,
) async {
  final backend = Uri(scheme: 'http', host: '::1', port: port);
  final origin = Uri.parse('https://radio.example.test');
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final formRequest = await http.getUrl(backend.resolve('/login'));
    formRequest.headers.set(HttpHeaders.hostHeader, origin.host);
    final form = await formRequest.close();
    expect(form.statusCode, HttpStatus.ok);
    final csrf = form.cookies.singleWhere(
      (cookie) => cookie.name == 'htc_login',
    );
    expect(csrf.secure, isTrue);
    await form.drain<void>();

    final login = await http.postUrl(backend.resolve('/login'));
    login.followRedirects = false;
    login.headers.set(HttpHeaders.hostHeader, origin.host);
    login.headers.set('Origin', origin.origin);
    login.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    login.cookies.add(csrf);
    login.write(
      Uri(
        queryParameters: {
          'csrf': csrf.value,
          'password': _testRemotePassword,
        },
      ).query,
    );
    final signedIn = await login.close();
    expect(signedIn.statusCode, HttpStatus.seeOther);
    final session = signedIn.cookies.singleWhere(
      (cookie) => cookie.name == 'htc_bridge',
    );
    expect(session.secure, isTrue);
    await signedIn.drain<void>();

    final pageRequest = await http.getUrl(backend.resolve('/remote.html'));
    pageRequest.headers.set(HttpHeaders.hostHeader, origin.host);
    pageRequest.cookies.add(session);
    final page = await pageRequest.close();
    expect(page.statusCode, HttpStatus.ok);
    await page.drain<void>();

    final socket = await WebSocket.connect(
      Uri(
        scheme: 'ws',
        host: '::1',
        port: port,
        path: '/websocket.aspx',
      ).toString(),
      headers: {
        HttpHeaders.hostHeader: origin.host,
        'Origin': origin.origin,
        HttpHeaders.cookieHeader: 'htc_bridge=${session.value}',
      },
    );
    final response = Completer<Map<String, Object?>>();
    final subscription = socket.listen((event) {
      if (event is! String || !event.startsWith('remote:')) return;
      final decoded = jsonDecode(event.substring(7));
      if (decoded is Map && decoded['state'] is Map && !response.isCompleted) {
        response.complete(Map<String, Object?>.from(decoded['state'] as Map));
      }
    });
    try {
      socket.add('remote:{"op":"state"}');
      final state = await response.future.timeout(const Duration(seconds: 5));
      expect(state['radioId'], expectedRadioId);
      expect(state['connected'], isTrue);
    } finally {
      await subscription.cancel();
      await socket.close();
    }
  } finally {
    http.close(force: true);
  }
}

Future<void> _verifyAndroidRemotePaths(
  int port,
  int expectedRadioId,
  List<Uint8List> bluetoothWrites,
) async {
  await _verifyRemoteServerSeesConnectedRadio(
    port,
    expectedRadioId,
    bluetoothWrites,
  );
  await _verifyHttpsProxySession(port, expectedRadioId);
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
          setServerSetting(
            'webServerPublicOrigin',
            'https://radio.example.test',
          );
          setServerSetting('webServerDefaultReadOnly', 0);
          setServerSetting('webServerRequireControlApproval', 0);
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
              onConnected: (radioId, bluetoothWrites) =>
                  _verifyAndroidRemotePaths(
                    server.boundPort!,
                    radioId,
                    bluetoothWrites,
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
