import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/services/data_broker.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lifecycle = MethodChannel('com.htcommander/server_lifecycle');

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lifecycle, null);
    DataBroker.reset();
  });

  test('Android remote server holds foreground service while listening', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(lifecycle, (call) async {
          calls.add(call);
          return null;
        });

    void set(String name, Object value) => DataBroker.dispatch(
      deviceId: 0,
      name: name,
      data: value,
      store: true,
    );

    set('webServerEnabled', 0);
    set('webServerPort', 0);
    set('webServerRemoteEnabled', 1);
    set('webServerPassword', 'android-test-password');
    final handler = WebServerHandler();
    try {
      handler.init();
      set('webServerEnabled', 1);

      final started = await _waitUntil(
        () => handler.boundPort != null,
        timeout: const Duration(seconds: 3),
      );
      expect(started, isTrue, reason: 'the HTTP listener should bind');
      expect(calls.map((call) => call.method), contains('start'));
      expect(calls.first.arguments, {'reason': 'server'});

      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      final http = HttpClient();
      try {
        final request = await http.getUrl(
          Uri(
            scheme: 'http',
            host: '127.0.0.1',
            port: handler.boundPort!,
            path: '/login',
          ),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);
        expect(
          await utf8.decoder.bind(response).join(),
          contains('远程访问密码'),
        );

        // Android LAN hosts prefer an IPv6 dual-stack listener so phones on
        // IPv6-only Wi-Fi can reach the login page and authenticated client.
        final ipv6Base = Uri(
          scheme: 'http',
          host: '::1',
          port: handler.boundPort!,
        );
        final ipv6Login = await http.getUrl(ipv6Base.replace(path: '/login'));
        final ipv6LoginResponse = await ipv6Login.close();
        expect(ipv6LoginResponse.statusCode, HttpStatus.ok);
        expect(
          await utf8.decoder.bind(ipv6LoginResponse).join(),
          contains('远程访问密码'),
        );
        final csrf = ipv6LoginResponse.cookies.singleWhere(
          (cookie) => cookie.name == 'htc_login',
        );
        final loginPost = await http.postUrl(ipv6Base.replace(path: '/login'));
        loginPost.followRedirects = false;
        loginPost.cookies.add(csrf);
        loginPost.headers.set('origin', ipv6Base.origin);
        loginPost.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
        );
        loginPost.write(
          Uri(
            queryParameters: {
              'csrf': csrf.value,
              'password': 'android-test-password',
            },
          ).query,
        );
        final signedIn = await loginPost.close();
        expect(signedIn.statusCode, HttpStatus.seeOther);
        final session = signedIn.cookies.singleWhere(
          (cookie) => cookie.name == 'htc_bridge',
        );
        await signedIn.drain<void>();
        final remotePage = await http.getUrl(
          ipv6Base.replace(path: '/remote.html'),
        );
        remotePage.cookies.add(session);
        final remoteResponse = await remotePage.close();
        expect(remoteResponse.statusCode, HttpStatus.ok);
        expect(
          await utf8.decoder.bind(remoteResponse).join(),
          contains('操作权'),
        );
      } finally {
        http.close(force: true);
        HttpOverrides.global = previousHttpOverrides;
      }

      set('webServerEnabled', 0);
      final stopped = await _waitUntil(
        () => handler.boundPort == null &&
            calls.any((call) => call.method == 'stop'),
        timeout: const Duration(seconds: 3),
      );
      expect(stopped, isTrue, reason: 'disabling the server should stop it');
      expect(
        calls.where((call) => call.method == 'stop').first.arguments,
        {'reason': 'server'},
      );
    } finally {
      await handler.close();
    }
  });
}

Future<bool> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return predicate();
}
