import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_access_config.dart';
import 'package:htcommander/services/web/web_server_io.dart';

void main() {
  tearDown(DataBroker.reset);
  test('read-only policy denies writes, raw frames and malformed controls', () {
    for (final message in [
      'remote:{"op":"state"}',
      'remote:{"op":"pttStop"}',
      'audioon',
      'audiooff',
    ]) {
      expect(WebServer.readOnlyMessageAllowed(message), true);
    }
    for (final message in [
      'remote:{"op":"aprsMessage"}',
      'remote:{"op":"volume"}',
      'remote:broken',
      'remote:[]',
      'setsetting:AllowTransmit:1',
      'winlinkdisconnect:',
      'selectradio:2',
    ]) {
      expect(WebServer.readOnlyMessageAllowed(message), false);
    }
  });
  test(
    'host role changes and targeted revocation isolate independent sessions',
    () async {
      final server = WebServer(
        0,
        remoteConfig: const RemoteAccessConfig(
          enabled: true,
          password: 'test-password-long',
          defaultReadOnly: true,
        ),
      );
      expect(await server.start(), true);
      final base = 'http://127.0.0.1:${server.boundPort}', http = HttpClient();
      final received = StreamController<String>.broadcast();
      server.onTextMessage = (_, message) => received.add(message);
      final clients = <WebSocketClient>[];
      final connected = Completer<void>();
      server.onClientConnected = (client) {
        clients.add(client);
        if (clients.length == 2) connected.complete();
      };
      final sockets = <WebSocket>[], replies = <StreamController<dynamic>>[];
      Future<Cookie> login() async {
        final get = await http.getUrl(Uri.parse('$base/login'));
        final response = await get.close();
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
            queryParameters: {
              'csrf': csrf.value,
              'password': 'test-password-long',
            },
          ).query,
        );
        final signed = await post.close();
        final cookie = signed.cookies.singleWhere(
          (c) => c.name == 'htc_bridge',
        );
        await signed.drain<void>();
        return cookie;
      }

      try {
        final sessions = [await login(), await login()];
        for (final session in sessions) {
          final ws = await WebSocket.connect(
            '${base.replaceFirst('http:', 'ws:')}/websocket.aspx',
            headers: {'Origin': base, 'Cookie': 'htc_bridge=${session.value}'},
          );
          sockets.add(ws);
          final reply = StreamController<dynamic>.broadcast();
          replies.add(reply);
          ws.listen(reply.add, onDone: reply.close);
        }
        await connected.future.timeout(const Duration(seconds: 3));
        expect(server.clientSummaries, hasLength(2));
        final denied = replies[0].stream.first.timeout(
          const Duration(seconds: 3),
        );
        sockets[0].add('remote:{"op":"aprsMessage"}');
        expect(await denied, contains('read-only'));
        final rawDenied = replies[0].stream.first.timeout(
          const Duration(seconds: 3),
        );
        sockets[0].add([1, 2, 3]);
        expect(await rawDenied, contains('read-only'));
        server.setClientReadOnly(clients[0].id, false);
        final accepted = received.stream.first.timeout(
          const Duration(seconds: 3),
        );
        sockets[0].add('remote:{"op":"volume","value":3}');
        expect(await accepted, contains('volume'));
        DataBroker.dispatch(
          deviceId: 0,
          name: 'webServerEmergencyStopped',
          data: 1,
        );
        final stopped = replies[0].stream.first.timeout(
          const Duration(seconds: 3),
        );
        sockets[0].add('remote:{"op":"volume","value":4}');
        expect(await stopped, contains('read-only'));
        server.revokeClient(clients[0].id);
        expect(server.clientSummaries, hasLength(1));
        final stillReadable = received.stream.first.timeout(
          const Duration(seconds: 3),
        );
        sockets[1].add('remote:{"op":"state"}');
        expect(await stillReadable, contains('state'));
        final request = await http.getUrl(Uri.parse('$base/remote.html'));
        request.followRedirects = false;
        request.cookies.add(sessions[0]);
        final revoked = await request.close();
        expect(revoked.statusCode, 303);
        await revoked.drain<void>();
      } finally {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.stop();
        server.dispose();
        http.close(force: true);
        await received.close();
        for (final reply in replies) {
          if (!reply.isClosed) await reply.close();
        }
      }
    },
  );
}
