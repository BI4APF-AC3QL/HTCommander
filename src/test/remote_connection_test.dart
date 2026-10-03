import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/remote_connection_dialog.dart';
import 'package:htcommander/dialogs/remote_access_dialog.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_connection_service.dart';
import 'package:htcommander/services/web/remote_connection_io.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zxing2/qrcode.dart' as zxing;

class _RealHttp extends HttpOverrides {}

class _FakeProbes implements ConnectionProbes {
  bool pending = false;
  int calls = 0, cancels = 0;
  final waiting = <Completer<ConnectionCheck>>[];
  Future<ConnectionCheck> result(ConnectionCheck check) async {
    calls++;
    if (!pending) return check;
    final c = Completer<ConnectionCheck>();
    waiting.add(c);
    return c.future;
  }

  @override
  Future<ConnectionCheck> dns(Uri uri) =>
      result(const ConnectionCheck('dns', 'ipv6Only', ipv4: 0, ipv6: 1));
  @override
  Future<ConnectionCheck> certificate(Uri uri) =>
      result(const ConnectionCheck('certificate', 'certificateRejected'));
  @override
  Future<ConnectionCheck> http(Uri uri, {required bool backend}) => result(
    ConnectionCheck(
      backend ? 'backend' : 'public',
      backend ? 'loginReady' : 'badGateway',
      httpStatus: backend ? 200 : 502,
    ),
  );
  @override
  void cancel() {
    cancels++;
  }
}

Future<String> decodeVisibleQr(WidgetTester tester) async {
  expect(find.byType(QrImageView), findsOneWidget);
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('connection-login-qr')),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    final pixels = Int32List(image.width * image.height);
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] =
          (bytes[i * 4] << 16) | (bytes[i * 4 + 1] << 8) | bytes[i * 4 + 2];
    }
    final source = zxing.RGBLuminanceSource(image.width, image.height, pixels);
    final text = zxing.QRCodeReader()
        .decode(zxing.BinaryBitmap(zxing.HybridBinarizer(source)))
        .text;
    image.dispose();
    return text;
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DataBroker.reset);
  test(
    'addresses validate origin, preserve port, bracket IPv6, contain no credential',
    () {
      final spec = RemoteConnectionSpec(
        port: 18080,
        publicOrigin: 'https://radio.example.org:8443',
      );
      final urls = spec
          .loginAddresses([
            '192.168.1.10',
            '2001:db8::42',
            '../private?password=secret',
            '999.1.1.1',
            '192.168.1.10',
          ])
          .map((u) => u.toString())
          .toList();
      expect(urls, [
        'https://radio.example.org:8443/login',
        'http://127.0.0.1:18080/login',
        'http://192.168.1.10:18080/login',
        'http://[2001:db8::42]:18080/login',
      ]);
      expect(() => RemoteConnectionSpec(port: 0), throwsFormatException);
      expect(
        () => RemoteConnectionSpec(
          port: 18080,
          publicOrigin: 'https://radio.example.org:65536',
        ),
        throwsFormatException,
      );
      expect(
        () => RemoteConnectionSpec(
          port: 18080,
          publicOrigin: 'https://user:secret@radio.example.org',
        ),
        throwsFormatException,
      );
      expect(
        () => RemoteConnectionSpec(
          port: 18080,
          publicOrigin: 'http://radio.example.org',
        ),
        throwsFormatException,
      );
      expect(
        () => RemoteConnectionSpec(
          port: 18080,
          publicOrigin: 'https://radio.example.org?password=secret',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'timeout, single run and disposal suppress late results and cancel resources',
    () {
      fakeAsync((time) {
        final probes = _FakeProbes()..pending = true;
        final runner = ConnectionDiagnosticRunner(
          probes,
          timeout: const Duration(milliseconds: 10),
        );
        final spec = RemoteConnectionSpec(
          port: 18080,
          publicOrigin: 'https://radio.example.org',
        );
        List<ConnectionCheck>? first, second;
        runner.run(spec).then((r) => first = r);
        runner.run(spec).then((r) => second = r);
        time.flushMicrotasks();
        expect(probes.calls, 4);
        expect(second, isEmpty);
        time.elapse(const Duration(milliseconds: 11));
        time.flushMicrotasks();
        expect(first!.map((r) => r.result), everyElement('timeout'));
        expect(probes.cancels, 1);
        for (final c in probes.waiting) {
          c.complete(const ConnectionCheck('backend', 'loginReady'));
        }
        time.flushMicrotasks();
        runner.run(spec).then((r) => first = r);
        time.flushMicrotasks();
        runner.dispose();
        time.elapse(const Duration(milliseconds: 11));
        time.flushMicrotasks();
        expect(first, isEmpty);
        expect(probes.cancels, greaterThan(1));
      });
    },
  );
  test(
    'no public origin never makes external probes; export drops unknown exception metadata',
    () async {
      final probes = _FakeProbes();
      final runner = ConnectionDiagnosticRunner(probes);
      final result = await runner.run(RemoteConnectionSpec(port: 18080));
      expect(probes.calls, 1);
      expect(result.where((r) => r.result == 'notConfigured'), hasLength(3));
      final copied = jsonEncode(
        const ConnectionCheck(
          'secret-host',
          'password private exception',
        ).toJson(),
      );
      expect(copied, isNot(contains('secret')));
      expect(copied, isNot(contains('private')));
      runner.dispose();
    },
  );
  test(
    'native loopback recognizes login only, bounds response and times out without credentials',
    () async {
      final old = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      addTearDown(() => HttpOverrides.global = old);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <HttpRequest>[];
      server.listen((request) async {
        seen.add(request);
        if (request.uri.path == '/hold') return;
        if (request.uri.path == '/502') {
          request.response.statusCode = 502;
        } else if (request.uri.path == '/large') {
          request.response.write('x' * 20000);
        } else if (request.uri.path == '/login') {
          request.response.headers.contentType = ContentType.html;
          request.response.cookies.add(
            Cookie('htc_login', 'fixture-secret-token'),
          );
          request.response.write(
            '<title>HTCommander 登录</title><form action="/login"><input name="csrf" value="fixture-secret-token"></form>',
          );
        } else {
          request.response.write('<h1>other software private</h1>');
        }
        await request.response.close();
      });
      final probes = NativeConnectionProbes(
        timeout: const Duration(milliseconds: 200),
      );
      Uri url(String path) =>
          Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);
      try {
        expect(
          (await probes.http(url('/login'), backend: true)).result,
          'loginReady',
        );
        expect(
          (await probes.http(url('/'), backend: true)).result,
          'unexpectedService',
        );
        expect(
          (await probes.http(url('/large'), backend: true)).result,
          'unexpectedService',
        );
        final gateway = await probes.http(url('/502'), backend: false);
        expect(gateway.result, 'badGateway');
        expect(gateway.httpStatus, 502);
        expect(
          (await probes.http(url('/hold'), backend: true)).result,
          'timeout',
        );
        for (final req in seen) {
          expect(req.headers.value('Authorization'), isNull);
          expect(req.headers.value('Cookie'), isNull);
          expect(req.method, 'GET');
        }
        final dns = await probes.dns(Uri(scheme: 'https', host: '::1'));
        expect(dns.ipv6, 1);
        expect(dns.result, 'ipv6Only');
      } finally {
        probes.cancel();
        await server.close(force: true);
      }
    },
  );
  test(
    'native TLS rejects self-signed certificate with no trust bypass',
    () async {
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/remote_tls/test-only-cert.pem')
        ..usePrivateKey('test/fixtures/remote_tls/test-only-key.pem');
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server.listen((socket) => socket.destroy(), onError: (Object _) {});
      final probes = NativeConnectionProbes();
      try {
        final result = await probes.certificate(
          Uri(scheme: 'https', host: '127.0.0.1', port: server.port),
        );
        expect(result.result, 'certificateRejected');
        expect(result.expires, isNull);
      } finally {
        probes.cancel();
        await server.close();
      }
    },
  );
  testWidgets(
    '390px saved address QR raster independently decodes HTTPS and IPv6; diagnostics export is redacted',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'];
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final spec = RemoteConnectionSpec(
        port: 18080,
        publicOrigin: 'https://radio.example.org:8443',
      );
      final runner = ConnectionDiagnosticRunner(_FakeProbes());
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: const ValueKey('connection-screen'),
            child: Scaffold(
              body: RemoteConnectionDialog(
                spec: spec,
                hosts: const ['2001:db8::42'],
                runner: runner,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final snapshotPath = Platform.environment['HTC_DIAGNOSTIC_SCREENSHOT'];
      if (snapshotPath != null) {
        final screen = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('connection-screen')),
        );
        await tester.runAsync(() async {
          final rendered = await screen.toImage();
          final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
          await File(snapshotPath).writeAsBytes(png!.buffer.asUint8List());
          rendered.dispose();
        });
      }
      expect(
        await decodeVisibleQr(tester),
        'https://radio.example.org:8443/login',
      );
      await tester.tap(find.byType(DropdownButtonFormField<Uri>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('http://[2001:db8::42]:18080/login').last);
      await tester.pumpAndSettle();
      expect(
        await decodeVisibleQr(tester),
        'http://[2001:db8::42]:18080/login',
      );
      final check = find.text('Check saved connection settings');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(find.textContaining('502: check gateway'), findsOneWidget);
      final copy = find.text('Copy redacted connection diagnostics JSON');
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, contains('ipv6Only'));
      expect(copied, isNot(contains('radio.example.org')));
      expect(copied, isNot(contains('2001:db8')));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('parent QR uses saved port and origin while editor is dirty', (
    tester,
  ) async {
    DataBroker.dispatch(deviceId: 0, name: 'webServerPort', data: 18080);
    DataBroker.dispatch(
      deviceId: 0,
      name: 'webServerPublicOrigin',
      data: 'https://radio.example.org',
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RemoteAccessDialog())),
    );
    await tester.pumpAndSettle();
    final port = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == '18080',
    );
    await tester.ensureVisible(port);
    await tester.enterText(port, '19090');
    final qr = find.text('Address QR and connection diagnostics');
    await tester.ensureVisible(qr);
    await tester.tap(qr);
    await tester.pumpAndSettle();
    expect(await decodeVisibleQr(tester), 'https://radio.example.org/login');
    expect(
      tester
          .widget<RemoteConnectionDialog>(find.byType(RemoteConnectionDialog))
          .spec
          .port,
      18080,
    );
    expect(tester.takeException(), isNull);
  });
}
