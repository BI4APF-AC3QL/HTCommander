import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/host_bridge.dart';
import 'package:htcommander/services/web/web_server_io.dart';
import 'package:htcommander/services/agwpe/agwpe_frame.dart';

void main() {
  test('sensitive settings cannot cross the browser bridge', () {
    for (final key in [
      'WinlinkPassword',
      'EchoLinkPassword',
      'RepeaterBookToken',
      'AprsFiApiKey',
      'AllStarWtToken',
      'homeAssistantPassword',
      'MapCustomUrl',
      'webServerEnabled',
    ]) {
      expect(HostBridge.isSyncedSetting(key), isFalse, reason: key);
    }
    expect(HostBridge.isSyncedSetting('MapSource'), isTrue);
    expect(HostBridge.isSyncedSetting('ShowSatellitesOnMap'), isTrue);
  });
  test('AGWPE rejects oversized announced payload before buffering it', () {
    final header = Uint8List(36);
    ByteData.sublistView(header).setUint32(28, 0xffffffff, Endian.little);
    expect(() => AgwpeFrame.tryParse(header), throwsFormatException);
    expect(AgwpeFrame.tryParse(Uint8List(10)), isNull);
    final valid = AgwpeFrame(data: Uint8List.fromList([1, 2, 3])).toBytes();
    expect(AgwpeFrame.tryParse(valid)!.frame.data, [1, 2, 3]);
  });
  test('local web bridge requires session and same origin', () async {
    final dir = await Directory.systemTemp.createTemp('htc-web-test-');
    await File('${dir.path}/index.html').writeAsString('<html>test</html>');
    DataBroker.dispatch(deviceId: 0, name: 'webAppPath', data: dir.path);
    final server = WebServer(0);
    expect(await server.start(), isTrue);
    final origin = 'http://127.0.0.1:${server.boundPort}';
    final ws = 'ws://127.0.0.1:${server.boundPort}/websocket.aspx';
    final http = HttpClient();
    try {
      final page = await (await http.getUrl(
        Uri.parse('$origin/index.html'),
      )).close();
      expect(page.statusCode, 200);
      final cookie = page.cookies.singleWhere((c) => c.name == 'htc_bridge');
      await page.drain<void>();
      expect(cookie.httpOnly, isTrue);
      await expectLater(
        WebSocket.connect(ws, headers: {'Origin': origin}),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        WebSocket.connect(
          ws,
          headers: {
            'Origin': 'https://evil.example',
            'Cookie': '${cookie.name}=${cookie.value}',
          },
        ),
        throwsA(isA<WebSocketException>()),
      );
      final accepted = Completer<void>();
      server.onClientConnected = (_) => accepted.complete();
      final connected = await WebSocket.connect(
        ws,
        headers: {'Origin': origin, 'Cookie': '${cookie.name}=${cookie.value}'},
      );
      await accepted.future.timeout(const Duration(seconds: 3));
      expect(server.clientCount, 1);
      await connected.close();
    } finally {
      http.close(force: true);
      server.dispose();
      DataBroker.reset();
      await dir.delete(recursive: true);
    }
  });
}
