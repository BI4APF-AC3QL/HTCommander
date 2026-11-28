import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/app_settings.dart';
import 'package:htcommander/services/tts_audio_gain.dart';
import 'package:htcommander/services/tts_service.dart';

Uint8List pcm(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unity gain leaves audio unchanged', () {
    final input = pcm([0, 1000, -1000, 32767, -32768]);
    expect(applyTtsOutputGain(input, 1), input);
  });

  test('boost raises quiet speech and smoothly limits both polarities', () {
    final result = ByteData.sublistView(
      applyTtsOutputGain(pcm([4000, -4000, 30000, -30000]), 2),
    );
    expect(result.getInt16(0, Endian.little), 8000);
    expect(result.getInt16(2, Endian.little), -8000);
    expect(result.getInt16(4, Endian.little), greaterThan(30000));
    expect(result.getInt16(4, Endian.little), lessThan(32767));
    expect(result.getInt16(6, Endian.little), lessThan(-30000));
    expect(result.getInt16(6, Endian.little), greaterThan(-32768));
  });

  test('invalid gain uses unity and quiet gain attenuates', () {
    final input = pcm([1000, -1000]);
    expect(applyTtsOutputGain(input, double.nan), input);
    final result = ByteData.sublistView(applyTtsOutputGain(input, 0.5));
    expect(result.getInt16(0, Endian.little), 500);
    expect(result.getInt16(2, Endian.little), -500);
  });

  test('output gain survives settings save and load', () async {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    AppSettings(voiceOutputGain: 2.25).saveToDataBroker();
    expect(AppSettings.loadFromDataBroker().voiceOutputGain, 2.25);
    expect(AppSettings(voiceOutputGain: 2).copyWith().voiceOutputGain, 2);
    await Future<void>.delayed(Duration.zero);
  });

  test('Windows synthesized PCM uses the requested gain', () async {
    const channel = MethodChannel('com.htcommander/tts');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'synthesize') {
            return {
              'samples': Float32List.fromList([0.1, -0.1]),
              'sampleRate': 32000,
            };
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final normal = await TtsService.instance.synthesizeToPcm(
      'test',
      outputGain: 1,
    );
    final boosted = await TtsService.instance.synthesizeToPcm(
      'test',
      outputGain: 2,
    );
    expect(normal, isNotNull);
    expect(boosted, isNotNull);
    final a = ByteData.sublistView(normal!).getInt16(0, Endian.little);
    final b = ByteData.sublistView(boosted!).getInt16(0, Endian.little);
    expect(b, greaterThan(a));
    expect(b, closeTo(a * 2, 2));
  }, skip: !Platform.isWindows ? 'Windows TTS channel' : false);
}
