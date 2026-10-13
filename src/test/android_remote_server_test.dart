import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/services/data_broker.dart';

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
      } finally {
        http.close(force: true);
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
