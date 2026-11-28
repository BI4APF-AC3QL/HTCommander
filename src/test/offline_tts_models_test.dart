import 'dart:io';
import 'dart:ffi';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/offline_tts_models.dart';
import 'package:htcommander/services/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('htcommander_tts_test_');
  });

  tearDown(() async {
    if (root.parent.absolute.path == Directory.systemTemp.absolute.path &&
        root.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('htcommander_tts_test_')) {
      await root.delete(recursive: true);
    }
  });

  Future<void> addFiles(String model, List<String> names) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}$model');
    await dir.create(recursive: true);
    for (final name in names) {
      await File(
        '${dir.path}${Platform.pathSeparator}$name',
      ).writeAsString('x');
    }
  }

  test('only complete installed models appear in the voice list', () async {
    await addFiles(OfflineTtsModels.melo, ['model.onnx', 'tokens.txt']);
    expect(await OfflineTtsModels.voicesInDirectory(root), isEmpty);

    await addFiles(OfflineTtsModels.melo, [
      'lexicon.txt',
      'date.fst',
      'number.fst',
    ]);
    final melo = await OfflineTtsModels.voicesInDirectory(root);
    expect(melo, hasLength(1));
    expect(melo.single['identifier'], 'sherpa-tts:${OfflineTtsModels.melo}:0');

    await addFiles(OfflineTtsModels.kokoro, [
      'model.onnx',
      'voices.bin',
      'tokens.txt',
      'lexicon-us-en.txt',
      'lexicon-zh.txt',
    ]);
    expect(await OfflineTtsModels.voicesInDirectory(root), hasLength(1));
    await Directory(
      '${root.path}${Platform.pathSeparator}${OfflineTtsModels.kokoro}${Platform.pathSeparator}espeak-ng-data',
    ).create();
    final voices = await OfflineTtsModels.voicesInDirectory(root);
    expect(voices, hasLength(104));
    expect(
      voices.last['identifier'],
      'sherpa-tts:${OfflineTtsModels.kokoro}:102',
    );
  });

  test('unknown model identifiers are rejected', () async {
    expect(
      await OfflineTtsModels.synthesize('sherpa-tts:unknown:0', 'hello', 0.5),
      isNull,
    );
  });

  final modelRoot = Platform.environment['HTC_TTS_MODEL_ROOT'];
  final nativeDir = Platform.environment['HTC_TTS_NATIVE_DIR'];
  test(
    'MeloTTS generates Chinese audio from an installed model',
    () async {
      // The test runner is outside the application folder. Load the same
      // ONNX runtime shipped with the app before loading the Sherpa DLL.
      DynamicLibrary.open('$nativeDir${Platform.pathSeparator}onnxruntime.dll');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return modelRoot;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final audio = await OfflineTtsModels.synthesize(
        'sherpa-tts:${OfflineTtsModels.melo}:0',
        '你好，这里是电台。',
        0.5,
      );
      expect(audio, isNotNull);
      expect(audio!.sampleRate, greaterThan(0));
      expect(audio.samples.length, greaterThan(100));
      expect(audio.samples.any((sample) => sample.abs() > 0.0001), isTrue);
      final voice = jsonEncode({
        'identifier': 'sherpa-tts:${OfflineTtsModels.melo}:0',
      });
      final normal = await TtsService.instance.synthesizeToPcm(
        '你好',
        voiceJson: voice,
        outputGain: 1,
      );
      final louder = await TtsService.instance.synthesizeToPcm(
        '你好',
        voiceJson: voice,
        outputGain: 1.5,
      );
      expect(normal, isNotNull);
      expect(louder, isNotNull);
      double energy(Uint8List bytes) {
        final data = ByteData.sublistView(bytes);
        var sum = 0.0;
        for (var i = 0; i + 1 < bytes.length; i += 2) {
          final sample = data.getInt16(i, Endian.little).toDouble();
          sum += sample * sample;
        }
        return sum / (bytes.length ~/ 2);
      }

      expect(energy(louder!), greaterThan(energy(normal!)));
    },
    skip: modelRoot == null || nativeDir == null || !Platform.isWindows
        ? 'Optional model not installed'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  final kokoroInstalled =
      modelRoot != null &&
      File(
        '$modelRoot${Platform.pathSeparator}tts_models${Platform.pathSeparator}${OfflineTtsModels.kokoro}${Platform.pathSeparator}model.onnx',
      ).existsSync();
  test(
    'Kokoro generates Chinese audio with female and male voices',
    () async {
      DynamicLibrary.open('$nativeDir${Platform.pathSeparator}onnxruntime.dll');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return modelRoot;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      for (final sid in [3, 58]) {
        final audio = await OfflineTtsModels.synthesize(
          'sherpa-tts:${OfflineTtsModels.kokoro}:$sid',
          '你好，这里是电台。',
          0.5,
        );
        expect(audio, isNotNull);
        expect(audio!.sampleRate, greaterThan(0));
        expect(audio.samples.any((sample) => sample.abs() > 0.0001), isTrue);
      }
    },
    skip:
        modelRoot == null ||
            nativeDir == null ||
            !Platform.isWindows ||
            !kokoroInstalled
        ? 'Optional model not installed'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
