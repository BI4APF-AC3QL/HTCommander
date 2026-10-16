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
import 'package:htcommander/radio/radio_models.dart';
import 'package:htcommander/services/bluetooth_service.dart';
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

      Future<void> sendSettingsAndVerify(
        Map<String, Object?> command,
        bool Function(Uint8List frame) matches,
        String description, {
        required int channelA,
        required int squelch,
        required bool scan,
      }) async {
        final writeCount = bluetoothWrites.length;
        final response = await sendCommand(command);
        expect(response['error'], isNull, reason: '$description is accepted');
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        bool matchingWriteReachedBluetooth() => bluetoothWrites
            .skip(writeCount)
            .any(
              (frame) =>
                  frame.length >= 10 &&
                  frame[0] == 0xFF &&
                  frame[1] == 0x01 &&
                  frame[4] == 0 &&
                  frame[5] == RadioCommandGroup.basic.value &&
                  frame[6] == 0 &&
                  frame[7] == RadioBasicCommand.writeSettings.value &&
                  matches(frame),
            );

        while (!matchingWriteReachedBluetooth() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          matchingWriteReachedBluetooth(),
          isTrue,
          reason: '$description must reach Android Classic as GAIA settings',
        );

        // The mock bridge does not synthesize the radio's settings-read reply.
        // Mirror the successful write so each subsequent command starts from
        // the radio state the real firmware would report.
        final rawSettings = Uint8List(26)
          ..[5] = (channelA & 0x0F) << 4
          ..[6] = (scan ? 0x80 : 0) | (squelch & 0x0F);
        final nextSettings = RadioSettings.fromBytes(rawSettings);
        final connectedRadio = BluetoothService().radioInstance(
          expectedRadioId,
        );
        expect(connectedRadio, isNotNull);
        connectedRadio!.settings = nextSettings;
        DataBroker.dispatch(
          deviceId: expectedRadioId,
          name: 'Settings',
          data: nextSettings.toJson(),
        );
      }

      await sendSettingsAndVerify(
        {'op': 'channel', 'value': 3, 'vfo': 'A'},
        (frame) => frame[8] == 0x30,
        'channel selection',
        channelA: 3,
        squelch: 0,
        scan: false,
      );
      await sendSettingsAndVerify(
        {'op': 'squelch', 'value': 7},
        (frame) => frame[9] == 0x07,
        'squelch adjustment',
        channelA: 3,
        squelch: 7,
        scan: false,
      );
      await sendSettingsAndVerify(
        {'op': 'scan', 'value': true},
        (frame) => frame[9] == 0x87,
        'scan start',
        channelA: 3,
        squelch: 7,
        scan: true,
      );
      await sendSettingsAndVerify(
        {'op': 'scan', 'value': false},
        (frame) => frame[9] == 0x07,
        'scan stop',
        channelA: 3,
        squelch: 7,
        scan: false,
      );

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
      // The emulator driver waits for this while the display is still asleep,
      // proving the authenticated control session can issue a radio command
      // after Android has backgrounded the Activity and suspended the display.
      // ignore: avoid_print
      print('HTC_ANDROID_BT_REMOTE_SCREEN_OFF_CONTROL_OK');
    } finally {
      await subscription.cancel();
      await socket.close();
    }
  } finally {
    http.close(force: true);
  }
}

Future<void> _verifyHttpsProxySession(int port, int expectedRadioId) async {
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
        queryParameters: {'csrf': csrf.value, 'password': _testRemotePassword},
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
  // The mocked N7500 has no inbound frames. Seed only the receive-safe state
  // needed to exercise the browser controls through the Android radio stack.
  final connectedRadio = BluetoothService().radioInstance(expectedRadioId);
  expect(connectedRadio, isNotNull);
  final settings = RadioSettings.fromBytes(Uint8List(26));
  connectedRadio!.settings = settings;
  DataBroker.dispatch(
    deviceId: expectedRadioId,
    name: 'Settings',
    data: settings.toJson(),
  );
  DataBroker.dispatch(
    deviceId: expectedRadioId,
    name: 'Channels',
    data: <Map<String, Object>>[
      {
        'channelId': 3,
        'name': 'RX TEST',
        'rxFreq': 145500000,
        'txFreq': 145500000,
        'scan': true,
        'txDisable': true,
        'mute': false,
        'txMod': 0,
        'rxMod': 0,
        'bandwidth': 0,
      },
    ],
  );

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
      final classicEvents = AndroidBluetoothClassicEventFixture();
      classicEvents.install(
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger,
      );
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
        // Android keeps a startup gate visible until every core service is
        // ready. Wait for the main form so its radio-state listener is mounted
        // before injecting a native disconnect event.
        final mainFormDeadline = DateTime.now().add(
          const Duration(seconds: 60),
        );
        while (!tester.any(find.byType(app.MainForm)) &&
            DateTime.now().isBefore(mainFormDeadline)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        expect(
          tester.any(find.byType(app.MainForm)),
          isTrue,
          reason: 'the Android startup gate must hand off to the main app',
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
              onUnexpectedDisconnect:
                  (radioId, nativeConnectCalls, nativeDiscoveryCalls) async {
                    expect(nativeConnectCalls(), 1);
                    expect(
                      BluetoothService().previouslyConnectedRadioMacs(),
                      contains('02:00:00:00:00:75'),
                    );
                    classicEvents.emitUnexpectedDisconnect(
                      '02:00:00:00:00:75',
                    );

                    final disconnectedDeadline = DateTime.now().add(
                      const Duration(seconds: 10),
                    );
                    while (DataBroker.getValue<String>(radioId, 'State') !=
                            'Disconnected' &&
                        DateTime.now().isBefore(disconnectedDeadline)) {
                      await Future<void>.delayed(
                        const Duration(milliseconds: 50),
                      );
                    }
                    expect(
                      DataBroker.getValue<String>(radioId, 'State'),
                      'Disconnected',
                      reason:
                          'an unsolicited native event must clean up the old link',
                    );
                    expect(
                      BluetoothService().connectedRadioIds,
                      isNot(contains(radioId)),
                      reason:
                          'the disconnected Classic transport must be released',
                    );

                    final reconnectedDeadline = DateTime.now().add(
                      const Duration(seconds: 30),
                    );
                    bool fakeRadioIsConnected() => BluetoothService()
                        .connectedRadioIds
                        .any(
                          (id) =>
                              DataBroker.getValue<String>(id, 'MacAddress') ==
                                  '02:00:00:00:00:75' &&
                              DataBroker.getValue<String>(id, 'State') ==
                                  'Connected',
                        );
                    while ((nativeConnectCalls() < 2 ||
                            !fakeRadioIsConnected()) &&
                        DateTime.now().isBefore(reconnectedDeadline)) {
                      await Future<void>.delayed(
                        const Duration(milliseconds: 100),
                      );
                    }
                    expect(
                      nativeDiscoveryCalls(),
                      greaterThanOrEqualTo(1),
                      reason:
                          'the scheduled retry must rediscover the paired radio',
                    );
                    expect(
                      nativeConnectCalls(),
                      greaterThanOrEqualTo(2),
                      reason: 'Android should retry the remembered radio',
                    );
                    expect(
                      fakeRadioIsConnected(),
                      isTrue,
                      reason:
                          'the scheduled Classic retry should restore the link',
                    );
                  },
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
