import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/web/web_server_io.dart';

class _RealHttp extends HttpOverrides {}

class _HostedWebAssets extends CachingAssetBundle {
  static final Map<String, List<int>> assets = {
    'assets/web_app/index.html': utf8.encode(
      '<!doctype html><title>Hosted</title>',
    ),
    'assets/web_app/main.dart.js': utf8.encode(
      'console.log("hosted");',
    ),
    'assets/web_app/canvaskit/canvaskit.wasm': Uint8List.fromList([
      0x00,
      0x61,
      0x73,
      0x6d,
    ]),
  };

  @override
  Future<ByteData> load(String key) async {
    final bytes = assets[key];
    if (bytes == null) throw FlutterError('Asset not found: $key');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android web server serves packaged hosted UI and JS assets', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttp();
    final server = WebServer(0, assetBundle: _HostedWebAssets());
    final http = HttpClient();
    try {
      expect(await server.start(), isTrue);

      final page = await http.getUrl(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.boundPort!,
        ),
      );
      final pageResponse = await page.close();
      expect(pageResponse.statusCode, HttpStatus.ok);
      expect(pageResponse.headers.contentType?.mimeType, 'text/html');
      expect(await utf8.decoder.bind(pageResponse).join(), contains('Hosted'));
      expect(pageResponse.headers[HttpHeaders.setCookieHeader], isNotEmpty);

      final script = await http.getUrl(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.boundPort!,
          path: '/main.dart.js',
        ),
      );
      final scriptResponse = await script.close();
      expect(scriptResponse.statusCode, HttpStatus.ok);
      expect(
        scriptResponse.headers.contentType?.mimeType,
        'application/javascript',
      );
      expect(
        await utf8.decoder.bind(scriptResponse).join(),
        contains('hosted'),
      );

      final wasm = await http.getUrl(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.boundPort!,
          path: '/canvaskit/canvaskit.wasm',
        ),
      );
      final wasmResponse = await wasm.close();
      expect(wasmResponse.statusCode, HttpStatus.ok);
      expect(wasmResponse.headers.contentType?.mimeType, 'application/wasm');
      expect(await wasmResponse.fold<List<int>>([], (b, d) => b..addAll(d)), [
        0x00,
        0x61,
        0x73,
        0x6d,
      ]);
    } finally {
      http.close(force: true);
      server.dispose();
      HttpOverrides.global = previousOverrides;
    }
  });
}
