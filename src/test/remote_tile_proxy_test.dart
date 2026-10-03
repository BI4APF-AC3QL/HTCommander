import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_access_config.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';
import 'package:htcommander/services/web/remote_tile_proxy.dart';
import 'package:htcommander/services/web/web_server_io.dart';
import 'package:htcommander/utils/map_source.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
MapSource source(HttpServer server, {String path = 'tiles'}) => MapSource(
  'custom',
  'Test tiles',
  'http://127.0.0.1:${server.port}/$path/{z}/{x}/{y}?key=test-only',
  'Test',
  '',
);

void main() {
  tearDown(DataBroker.reset);
  test(
    'host tile proxy bounds memory, deduplicates fetches and isolates sources',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final agents = <String?>[];
      upstream.listen((r) async {
        requests++;
        agents.add(r.headers.value('user-agent'));
        r.response.headers.contentType = ContentType('image', 'png');
        r.response.add(png);
        await r.response.close();
      });
      final proxy = RemoteTileProxy();
      try {
        final layer = source(upstream);
        final first = await Future.wait(
          List.generate(8, (_) => proxy.tile(layer, 8, 0, 0)),
        );
        expect(first.every((tile) => tile != null), true);
        expect(requests, 1);
        expect(agents.single, startsWith('HTCommander/'));
        await proxy.tile(layer, 8, 0, 0);
        expect(requests, 1);
        for (var x = 1; x < 70; x++) {
          expect(await proxy.tile(layer, 8, x, 0), isNotNull);
        }
        expect(proxy.cacheSize, RemoteTileProxy.maxEntries);
        expect(proxy.pendingCount, 0);
        await proxy.tile(source(upstream, path: 'changed'), 8, 69, 0);
        expect(requests, 71);
        expect(await proxy.tile(layer, 2, 4, 0), isNull);
        expect(await proxy.tile(layer, 19, 0, 0), isNull);
        proxy.close();
        expect(proxy.cacheSize, 0);
        expect(await proxy.tile(layer, 8, 0, 0), isNull);
      } finally {
        proxy.close();
        await upstream.close(force: true);
      }
    },
  );

  test(
    'slow upstream has bounded concurrency/timeout and close cancels pending',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      upstream.listen((_) {
        requests++;
      });
      final proxy = RemoteTileProxy(timeout: const Duration(milliseconds: 300));
      try {
        final layer = source(upstream);
        final pending = List.generate(8, (x) => proxy.tile(layer, 8, x, 0));
        expect(proxy.pendingCount, 8);
        expect(await proxy.tile(layer, 8, 9, 0), isNull);
        expect(await Future.wait(pending), everyElement(isNull));
        expect(proxy.pendingCount, 0);
        expect(requests, 8);
        final wait = proxy.tile(layer, 8, 0, 0);
        proxy.close();
        expect(await wait, isNull);
        expect(proxy.cacheSize, 0);
      } finally {
        proxy.close();
        await upstream.close(force: true);
      }
    },
  );

  test(
    'reject redirect, error HTML, wrong signature and oversized chunked image',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var redirected = 0;
      upstream.listen((r) async {
        final mode = r.uri.pathSegments.first;
        r.response.headers.contentType = ContentType('image', 'png');
        if (mode == 'redirect') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/target/0/0/0');
        } else if (mode == 'target') {
          redirected++;
          r.response.add(png);
        } else if (mode == 'error') {
          r.response.statusCode = 403;
          r.response.write('denied');
        } else if (mode == 'html') {
          r.response.write('<html>not a map</html>');
        } else {
          r.response.add(List.filled(RemoteTileProxy.maxBytes + 1, 1));
        }
        await r.response.close();
      });
      final proxy = RemoteTileProxy();
      try {
        for (final mode in ['redirect', 'error', 'html', 'large']) {
          expect(
            await proxy.tile(source(upstream, path: mode), 0, 0, 0),
            isNull,
          );
        }
        expect(redirected, 0);
        expect(proxy.cacheSize, 0);
      } finally {
        proxy.close();
        await upstream.close(force: true);
      }
    },
  );

  test(
    'authenticated route fetches only configured source, keeps keys off phone',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      upstream.listen((r) async {
        requests++;
        r.response.headers.contentType = ContentType('image', 'png');
        r.response.add(png);
        await r.response.close();
      });
      DataBroker.dispatch(deviceId: 0, name: 'MapSource', data: 'custom');
      DataBroker.dispatch(
        deviceId: 0,
        name: 'MapCustomUrl',
        data: source(upstream).urlTemplate,
      );
      final remote = RemoteRadioController(target: () => -1);
      final json = jsonEncode(remote.snapshot());
      expect(json, contains('/remote-tiles/custom/{z}/{x}/{y}.png'));
      expect(json, isNot(contains('test-only')));
      expect(json, isNot(contains('${upstream.port}')));
      final server = WebServer(
        0,
        remoteConfig: const RemoteAccessConfig(
          enabled: true,
          password: 'test-only-password',
        ),
      );
      expect(await server.start(), true);
      final http = HttpClient();
      final base = 'http://127.0.0.1:${server.boundPort}';
      try {
        final denied = await http.getUrl(
          Uri.parse('$base/remote-tiles/custom/0/0/0.png'),
        );
        denied.followRedirects = false;
        final deniedResponse = await denied.close();
        expect(deniedResponse.statusCode, 303);
        await deniedResponse.drain<void>();
        expect(requests, 0);
        final form = await (await http.getUrl(
          Uri.parse('$base/login'),
        )).close();
        final csrf = form.cookies.singleWhere((c) => c.name == 'htc_login');
        final page = await utf8.decoder.bind(form).join();
        final token = RegExp(
          'name="csrf" value="([^"]+)"',
        ).firstMatch(page)![1]!;
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
            queryParameters: {'csrf': token, 'password': 'test-only-password'},
          ).query,
        );
        final signed = await post.close();
        final session = signed.cookies.singleWhere(
          (c) => c.name == 'htc_bridge',
        );
        await signed.drain<void>();
        for (final path in [
          'custom/0/0/0.png',
          'custom/0/0/0.png',
          'custom/0/9/0.png',
          'unknown/0/0/0.png',
        ]) {
          final get = await http.getUrl(Uri.parse('$base/remote-tiles/$path'));
          get.cookies.add(session);
          final response = await get.close();
          expect(
            response.statusCode,
            path.startsWith('custom/0/0') ? 200 : 502,
          );
          expect(response.headers.value('cache-control'), 'no-store');
          final bytes = await response.fold<List<int>>(
            [],
            (all, chunk) => all..addAll(chunk),
          );
          if (response.statusCode == 200) expect(bytes, png);
        }
        expect(requests, 1);
      } finally {
        remote.release();
        http.close(force: true);
        await server.stop();
        server.dispose();
        await upstream.close(force: true);
      }
    },
  );
}
