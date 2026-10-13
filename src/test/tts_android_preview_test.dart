import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:htcommander/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'local preview applies voice settings and replaces queued speech',
    () async {
      final calls = <MethodCall>[];
      final tts = FlutterTts();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 1;
      });

      await TtsService.previewWithFlutterTts(
        tts,
        'Local voice preview',
        voiceJson: '{"name":"English Voice","locale":"en-US",'
            '"identifier":"en-US-voice"}',
        rate: 0.65,
        pitch: 1.25,
      );

      expect(
        calls.map((call) => call.method).toList(),
        [
          'stop',
          'setSpeechRate',
          'setPitch',
          'clearVoice',
          'setVoice',
          'speak',
        ],
      );
      expect(calls[1].arguments, 0.65);
      expect(calls[2].arguments, 1.25);
      expect(calls[4].arguments, {
        'name': 'English Voice',
        'locale': 'en-US',
        'identifier': 'en-US-voice',
      });
      expect(calls.last.arguments, 'Local voice preview');
    },
  );

  test('empty voice selection resets to the system default', () async {
    final calls = <MethodCall>[];
    final tts = FlutterTts();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 1;
    });

    await TtsService.previewWithFlutterTts(
      tts,
      'System voice preview',
      rate: 0.5,
      pitch: 1.0,
    );

    expect(
      calls.map((call) => call.method).toList(),
      ['stop', 'setSpeechRate', 'setPitch', 'clearVoice', 'speak'],
    );
  });
}
