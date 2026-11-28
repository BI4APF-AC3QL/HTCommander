import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/audio_output_devices.dart';

const _audioChannel = MethodChannel('com.htcommander/pcm_player');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioChannel, null);
  });

  test('Android lists native audio routes for the output selector', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioChannel, (call) async {
          expect(call.method, 'listDevices');
          return [
            {'id': '', 'label': 'System default'},
            {'id': '23', 'label': 'Bluetooth headset'},
          ];
        });

    expect(AudioOutputDevices.isSupported, isTrue);
    final routes = await AudioOutputDevices.list();
    expect(routes.map((route) => (route.id, route.label)), [
      ('', 'System default'),
      ('23', 'Bluetooth headset'),
    ]);
  });

  test('iOS keeps its system-managed audio route', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    expect(AudioOutputDevices.isSupported, isFalse);
    expect(await AudioOutputDevices.list(), isEmpty);
  });
}
