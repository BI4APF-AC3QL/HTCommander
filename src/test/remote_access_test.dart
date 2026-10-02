import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/web/remote_access_config.dart';
import 'package:htcommander/services/web/remote_web_auth.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';
import 'package:htcommander/services/web/web_server_io.dart';

void main() {
  tearDown(DataBroker.reset);
  test('remote defaults off and only canonical HTTPS origins accepted', () {
    expect(RemoteAccessConfig.current.enabled, false);
    expect(RemoteAccessConfig.current.allowTransmit, false);
    for (final invalid in [
      'http://radio.example',
      'https://a.example/path',
      'https://user:pass@a.example',
      'https://a.example?q=1',
    ]) {
      expect(RemoteAccessConfig.validateOrigin(invalid), isNotNull);
    }
    expect(
      RemoteAccessConfig.validateOrigin('https://radio.example:8443/'),
      isNull,
    );
  });
  test(
    'login forms are single use, sessions expire, failures rate limited',
    () {
      var now = DateTime(2026);
      final auth = RemoteWebAuth('a-long-test-password', clock: () => now);
      final csrf = auth.newForm();
      expect(auth.consumeForm(csrf, 'wrong'), false);
      expect(auth.consumeForm(csrf, csrf), true);
      expect(auth.consumeForm(csrf, csrf), false);
      for (var i = 0; i < 5; i++) {
        expect(auth.login('client', 'bad'), isNull);
      }
      expect(auth.rateLimited('client'), true);
      expect(auth.login('client', 'a-long-test-password'), isNull);
      now = now.add(const Duration(minutes: 1));
      final token = auth.login('client', 'a-long-test-password');
      expect(auth.authenticated(token), true);
      auth.logout(token);
      expect(auth.authenticated(token), false);
      final next = auth.login('client', 'a-long-test-password');
      now = now.add(const Duration(hours: 12));
      expect(auth.authenticated(next), false);
    },
  );
  test('unconfigured remote server fails closed', () async {
    final server = WebServer(
      0,
      remoteConfig: const RemoteAccessConfig(enabled: true),
    );
    expect(await server.start(), false);
    expect(server.isRunning, false);
    server.dispose();
  });
  test('stop while remote bind is pending cannot leave a listener', () async {
    final server = WebServer(
      0,
      remoteConfig: const RemoteAccessConfig(
        enabled: true,
        password: 'a-long-test-password',
      ),
    );
    final starting = server.start();
    await server.stop();
    expect(await starting, false);
    expect(server.boundPort, isNull);
    server.dispose();
  });
  test('real HTTP login protects static files, websocket and logout', () async {
    final server = WebServer(
      0,
      remoteConfig: const RemoteAccessConfig(
        enabled: true,
        password: 'a-long-test-password',
      ),
    );
    expect(await server.start(), true);
    final base = 'http://127.0.0.1:${server.boundPort}';
    final http = HttpClient();
    WebSocket? socket;
    Future<HttpClientResponse> get(String path, {Cookie? cookie}) async {
      final request = await http.getUrl(Uri.parse('$base$path'));
      request.followRedirects = false;
      if (cookie != null) request.cookies.add(cookie);
      return request.close();
    }

    try {
      final denied = await get('/main.dart.js');
      expect(denied.statusCode, 303);
      expect(denied.headers.value('location'), '/login');
      await denied.drain<void>();
      final login = await get('/login');
      expect(login.headers.value('referrer-policy'), 'same-origin');
      final csrf = login.cookies.singleWhere((c) => c.name == 'htc_login');
      expect(csrf.httpOnly, true);
      await login.drain<void>();
      final opaque = await http.postUrl(Uri.parse('$base/login'));
      opaque.headers.set('origin', 'null');
      final opaqueResponse = await opaque.close();
      expect(opaqueResponse.statusCode, HttpStatus.forbidden);
      await opaqueResponse.drain<void>();
      final post = await http.postUrl(Uri.parse('$base/login'));
      post.followRedirects = false;
      post.cookies.add(csrf);
      post.headers.set('origin', base);
      post.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      post.write(
        Uri(
          queryParameters: {
            'csrf': csrf.value,
            'password': 'a-long-test-password',
          },
        ).query,
      );
      final signed = await post.close();
      expect(signed.statusCode, 303);
      final session = signed.cookies.singleWhere((c) => c.name == 'htc_bridge');
      expect(session.httpOnly, true);
      await signed.drain<void>();
      final page = await get('/remote.html', cookie: session);
      expect(page.statusCode, 200);
      await page.drain<void>();
      final manifest = await get('/remote.webmanifest', cookie: session);
      expect(manifest.statusCode, 200);
      final data = jsonDecode(await utf8.decoder.bind(manifest).join()) as Map;
      expect(data['start_url'], '/remote.html');
      expect(data['display'], 'standalone');
      final worker = await get('/remote-worker.js', cookie: session);
      final workerText = await utf8.decoder.bind(worker).join();
      expect(workerText, contains('activate'));
      expect(workerText, isNot(contains('fetch')));
      final protectedManifest = await get('/remote.webmanifest');
      expect(protectedManifest.statusCode, 303);
      await protectedManifest.drain<void>();
      final ws = '${base.replaceFirst('http:', 'ws:')}/websocket.aspx';
      await expectLater(
        WebSocket.connect(ws, headers: {'Origin': base}),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        WebSocket.connect(
          ws,
          headers: {
            'Origin': 'https://evil.example',
            'Cookie': 'htc_bridge=${session.value}',
          },
        ),
        throwsA(isA<WebSocketException>()),
      );
      final connected = Completer<void>();
      server.onClientConnected = (_) => connected.complete();
      socket = await WebSocket.connect(
        ws,
        headers: {'Origin': base, 'Cookie': 'htc_bridge=${session.value}'},
      );
      await connected.future.timeout(const Duration(seconds: 3));
      final closed = Completer<void>();
      socket.listen((_) {}, onDone: () => closed.complete());
      final logout = await http.postUrl(Uri.parse('$base/logout'));
      logout.cookies.add(session);
      logout.headers.set('origin', base);
      final loggedOut = await logout.close();
      expect(loggedOut.statusCode, 204);
      await loggedOut.drain<void>();
      await closed.future.timeout(const Duration(seconds: 3));
      final rejected = await get('/remote.html', cookie: session);
      expect(rejected.statusCode, 303);
      await rejected.drain<void>();
    } finally {
      await socket?.close();
      http.close(force: true);
      server.dispose();
    }
  });

  test(
    'HTTPS proxy origin issues secure cookies and rejects unknown hosts',
    () async {
      final server = WebServer(
        0,
        remoteConfig: const RemoteAccessConfig(
          enabled: true,
          password: 'a-long-test-password',
          publicOrigin: 'https://radio.example.test',
        ),
      );
      expect(await server.start(), true);
      final base = 'http://127.0.0.1:${server.boundPort}';
      final http = HttpClient();
      try {
        final unknown = await http.getUrl(Uri.parse('$base/login'));
        unknown.headers.set('host', 'evil.example');
        final forbidden = await unknown.close();
        expect(forbidden.statusCode, 403);
        await forbidden.drain<void>();
        final get = await http.getUrl(Uri.parse('$base/login'));
        get.headers.set('host', 'radio.example.test');
        final login = await get.close();
        final csrf = login.cookies.singleWhere((c) => c.name == 'htc_login');
        expect(csrf.secure, true);
        await login.drain<void>();
        final post = await http.postUrl(Uri.parse('$base/login'));
        post.followRedirects = false;
        post.headers.set('host', 'radio.example.test');
        post.headers.set('origin', 'https://radio.example.test');
        post.cookies.add(csrf);
        post.write(
          Uri(
            queryParameters: {
              'csrf': csrf.value,
              'password': 'a-long-test-password',
            },
          ).query,
        );
        final response = await post.close();
        expect(response.statusCode, 303);
        expect(
          response.cookies.singleWhere((c) => c.name == 'htc_bridge').secure,
          true,
        );
        await response.drain<void>();
      } finally {
        http.close(force: true);
        await server.stop();
        server.dispose();
      }
    },
  );

  void readyRadio() {
    for (final e in {'AllowTransmit': 1, 'webServerAllowTransmit': 1}.entries) {
      DataBroker.dispatch(deviceId: 0, name: e.key, data: e.value, store: true);
    }
    for (final e in <String, Object?>{
      'AudioState': true,
      'HtStatus': {'isInTx': false, 'isPowerOn': true},
      'Settings': {'channelA': 0, 'doubleChannel': 0},
      'Channels': [
        {
          'channelId': 0,
          'txDisable': false,
          'name': 'Test',
          'rxFreq': 145000000,
        },
      ],
    }.entries) {
      DataBroker.dispatch(deviceId: 2, name: e.key, data: e.value);
    }
  }

  Uint8List mic() => Uint8List.fromList([0xf2, 1, 0, 125, 0, 0, 0, 0]);
  test(
    'PTT requires both permissions and valid radio; ownership is exclusive',
    () {
      final controls = RemoteRadioController(target: () => 2)..grantControl(1);
      expect(controls.command(1, {'op': 'pttStart'}), isNotNull);
      readyRadio();
      expect(controls.command(1, {'op': 'pttStart'}), isNull);
      expect(controls.command(2, {'op': 'pttStart'}), isNotNull);
      expect(controls.microphone(2, mic()), false);
      expect(controls.command(1, {'op': 'channel', 'value': 0}), isNotNull);
      expect(controls.microphone(1, mic()), true);
      controls.command(2, {'op': 'pttStop'});
      expect(controls.snapshot()['txOwner'], 1);
      controls.disconnected(1);
      expect(controls.snapshot()['txOwner'], isNull);
    },
  );
  test('missing microphone data, disconnect and hard limit release TX', () {
    fakeAsync((time) {
      readyRadio();
      final controls = RemoteRadioController(
        target: () => 2,
        clock: () => time.getClock(DateTime(2026)).now(),
      )..grantControl(1);
      final broker = DataBrokerClient();
      var cancelled = 0;
      broker.subscribe(
        deviceId: 2,
        name: 'CancelVoiceTransmit',
        callback: (_, _, _) => cancelled++,
      );
      controls.command(1, {'op': 'pttStart'});
      time.elapse(const Duration(milliseconds: 1501));
      expect(cancelled, 1);
      expect(controls.snapshot()['txOwner'], isNull);
      controls.command(1, {'op': 'pttStart'});
      for (var i = 0; i < 59; i++) {
        time.elapse(const Duration(seconds: 1));
        controls.microphone(1, mic());
      }
      time.elapse(const Duration(seconds: 1));
      expect(cancelled, 2);
      expect(controls.snapshot()['txOwner'], isNull);
      broker.dispose();
    });
  });
  test('permissions revoked or malformed/oversized PCM releases owner', () {
    readyRadio();
    final controls = RemoteRadioController(target: () => 2)..grantControl(1);
    controls.command(1, {'op': 'pttStart'});
    expect(controls.microphone(1, Uint8List(9000)), false);
    expect(controls.snapshot()['txOwner'], isNull);
    controls.command(1, {'op': 'pttStart'});
    DataBroker.dispatch(
      deviceId: 0,
      name: 'AllowTransmit',
      data: 0,
      store: true,
    );
    expect(controls.microphone(1, mic()), false);
    expect(controls.snapshot()['txOwner'], isNull);
    controls.release();
  });
  test('raw commands cannot bypass PTT or write firmware/settings', () {
    for (final frame in [
      [0, 2, 0, 31],
      [0, 2, 0, 11],
      [0, 2, 0, 66],
      [0, 10, 6, 64],
    ]) {
      expect(
        RemoteRadioController.safeRawCommand(Uint8List.fromList(frame)),
        false,
      );
    }
    expect(
      RemoteRadioController.safeRawCommand(
        Uint8List.fromList([0, 2, 0, 13, 0]),
      ),
      true,
    );
  });
}
