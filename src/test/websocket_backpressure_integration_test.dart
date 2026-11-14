import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_access_config.dart';
import 'package:htcommander/services/web/web_server_io.dart';

Future<Cookie> login(HttpClient http, String base) async {
  final get = await http.getUrl(Uri.parse('$base/login')),
      response = await get.close();
  final csrf = response.cookies.singleWhere((c) => c.name == 'htc_login');
  await response.drain<void>();
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
      queryParameters: {'csrf': csrf.value, 'password': 'test-password-long'},
    ).query,
  );
  final signed = await post.close();
  final cookie = signed.cookies.singleWhere((c) => c.name == 'htc_bridge');
  await signed.drain<void>();
  return cookie;
}

void main() {
  tearDown(DataBroker.reset);
  test(
    'concurrent upgrades preserve eight-client cap and shutdown removes all',
    () async {
      final server = WebServer(
        0,
        remoteConfig: const RemoteAccessConfig(
          enabled: true,
          password: 'test-password-long',
        ),
      );
      expect(await server.start(), true);
      final http = HttpClient(), base = 'http://127.0.0.1:${server.boundPort}';
      final sockets = <WebSocket>[];
      var highWater = 0;
      server.onClientConnected = (_) {
        if (server.clientCount > highWater) highWater = server.clientCount;
      };
      try {
        final cookie = await login(http, base);
        await Future.wait(
          List.generate(12, (_) async {
            try {
              final ws = await WebSocket.connect(
                '${base.replaceFirst('http:', 'ws:')}/websocket.aspx',
                headers: {
                  'Origin': base,
                  'Cookie': 'htc_bridge=${cookie.value}',
                },
              );
              sockets.add(ws);
              ws.listen((_) {}, onError: (Object _) {});
            } on WebSocketException {
              // Some requests are rejected before handshake, others after detach.
            }
          }),
        );
        expect(highWater, 8);
        expect(server.clientCount, lessThanOrEqualTo(8));
        await server.stop().timeout(const Duration(seconds: 1));
        expect(server.clientCount, 0);
      } finally {
        await server.stop();
        for (final ws in sockets) {
          await ws.close();
        }
        server.dispose();
        http.close(force: true);
      }
    },
  );
  for (final action in ['timeout', 'revoke', 'shutdown']) {
    test('raw slow reader is bounded and isolated: $action', () async {
      final server = WebServer(
        0,
        remoteConfig: const RemoteAccessConfig(
          enabled: true,
          password: 'test-password-long',
        ),
      );
      expect(await server.start(), true);
      final http = HttpClient(), base = 'http://127.0.0.1:${server.boundPort}';
      RawSocket? raw;
      WebSocket? healthy;
      Timer? flood;
      try {
        final healthyCookie = await login(http, base);
        final cookie = await login(http, base);
        final header = {
          'Origin': base,
          'Cookie': 'htc_bridge=${healthyCookie.value}',
        };
        final connected = <WebSocketClient>[];
        final bothConnected = Completer<void>();
        server.onClientConnected = (client) {
          connected.add(client);
          if (connected.length == 2) bothConnected.complete();
        };
        healthy = await WebSocket.connect(
          '${base.replaceFirst('http:', 'ws:')}/websocket.aspx',
          headers: header,
        );
        final received = Completer<void>();
        healthy.listen((v) {
          if (v == 'healthy' && !received.isCompleted) received.complete();
        });
        raw = await RawSocket.connect('127.0.0.1', server.boundPort!);
        final handshake = Completer<String>(), bytes = <int>[];
        final slowSocket = raw;
        raw.listen((event) {
          if (event == RawSocketEvent.read) {
            final chunk = slowSocket.read();
            if (chunk != null) bytes.addAll(chunk);
            final text = latin1.decode(bytes);
            if (text.contains('\r\n\r\n') && !handshake.isCompleted) {
              slowSocket.readEventsEnabled = false;
              handshake.complete(text);
            }
          }
        });
        raw.write(
          latin1.encode(
            'GET /websocket.aspx HTTP/1.1\r\nHost: 127.0.0.1:${server.boundPort}\r\nOrigin: $base\r\nCookie: htc_bridge=${cookie.value}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n',
          ),
        );
        final headers = await handshake.future.timeout(
          const Duration(seconds: 3),
        );
        expect(headers, startsWith('HTTP/1.1 101'));
        expect(
          headers.toLowerCase(),
          isNot(contains('sec-websocket-extensions:')),
        );
        await bothConnected.future.timeout(const Duration(seconds: 3));
        expect(connected, hasLength(2));
        final slow = connected.last;
        final disconnected = Completer<void>();
        server.onClientDisconnected = (c) {
          if (c.id == slow.id && !disconnected.isCompleted) {
            disconnected.complete();
          }
        };
        final congested = Completer<void>();
        final pcm = Uint8List(64000)..[0] = 0xf1;
        var maxBytes = 0, maxMessages = 0;
        flood = Timer.periodic(const Duration(milliseconds: 1), (_) {
          for (var i = 0; i < 4; i++) {
            slow.sendBinary(pcm);
          }
          final state = slow.outputSnapshot;
          maxBytes = maxBytes < (state['queuedPayloadBytes'] as int)
              ? state['queuedPayloadBytes'] as int
              : maxBytes;
          maxMessages = maxMessages < (state['queuedMessages'] as int)
              ? state['queuedMessages'] as int
              : maxMessages;
          if (maxBytes >= 448000 &&
              (state['droppedAudioBlocks'] as int) > 0 &&
              !congested.isCompleted) {
            congested.complete();
          }
        });
        connected.first.sendText('healthy');
        await received.future.timeout(const Duration(seconds: 2));
        await congested.future.timeout(const Duration(seconds: 6));
        if (action == 'revoke') server.revokeClient(slow.id);
        if (action == 'shutdown') {
          await server.stop().timeout(const Duration(seconds: 1));
        }
        await disconnected.future.timeout(const Duration(seconds: 12));
        flood.cancel();
        expect(maxBytes, lessThanOrEqualTo(512 * 1024));
        expect(maxMessages, lessThanOrEqualTo(128));
        expect(slow.outputSnapshot['droppedAudioBlocks'], greaterThan(0));
        expect(server.clientCount, action == 'shutdown' ? 0 : 1);
        // Revocation and stop must not wait for a blocked transport.
        server.revokeClient(connected.first.id);
        await server.stop().timeout(const Duration(seconds: 1));
      } finally {
        flood?.cancel();
        raw?.close();
        await healthy?.close();
        await server.stop();
        server.dispose();
        http.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 20)));
  }
  test(
    'SDK upgrade accepts exact limit and closes oversized input before handler',
    () async {
      final server = WebServer(
        0,
        remoteConfig: const RemoteAccessConfig(
          enabled: true,
          password: 'test-password-long',
          defaultReadOnly: false,
        ),
      );
      expect(await server.start(), true);
      final http = HttpClient(), base = 'http://127.0.0.1:${server.boundPort}';
      WebSocket? socket;
      try {
        final cookie = await login(http, base);
        socket = await WebSocket.connect(
          '${base.replaceFirst('http:', 'ws:')}/websocket.aspx',
          headers: {'Origin': base, 'Cookie': 'htc_bridge=${cookie.value}'},
        );
        final accepted = Completer<void>();
        var calls = 0;
        server.onBinaryMessage = (_, data) {
          calls++;
          expect(data.length, 65536);
          accepted.complete();
        };
        final done = Completer<void>();
        socket.listen((_) {}, onDone: done.complete, onError: (Object _) {});
        socket.add(Uint8List(65536));
        await accepted.future.timeout(const Duration(seconds: 2));
        socket.add(Uint8List(65537));
        await done.future.timeout(const Duration(seconds: 3));
        expect(calls, 1);
      } finally {
        await socket?.close();
        await server.stop();
        server.dispose();
        http.close(force: true);
      }
    },
  );
}
