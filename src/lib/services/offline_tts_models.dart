import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Optional models are installed separately from the application.
class OfflineTtsModels {
  static const prefix = 'sherpa-tts:';
  static const kokoro = 'kokoro-multi-lang-v1_1';
  static const melo = 'vits-melo-tts-zh_en';

  static Future<Directory> directory({bool create = false}) async {
    final support = await getApplicationSupportDirectory();
    final result = Directory(
      '${support.path}${Platform.pathSeparator}tts_models',
    );
    if (create) await result.create(recursive: true);
    return result;
  }

  static String _path(String root, String name) =>
      '$root${Platform.pathSeparator}$name';

  static Future<bool> _ready(String root, String model) async {
    final dir = _path(root, model);
    final required = model == kokoro
        ? [
            'model.onnx',
            'voices.bin',
            'tokens.txt',
            'lexicon-us-en.txt',
            'lexicon-zh.txt',
          ]
        : ['model.onnx', 'tokens.txt', 'lexicon.txt', 'date.fst', 'number.fst'];
    for (final name in required) {
      final file = File(_path(dir, name));
      if (!await file.exists() || await file.length() == 0) return false;
    }
    return model != kokoro ||
        await Directory(_path(dir, 'espeak-ng-data')).exists();
  }

  static Future<List<Map<String, String>>> voices() async {
    if (!Platform.isWindows) return [];
    try {
      return await voicesInDirectory(await directory());
    } catch (_) {
      // The desktop path provider may be unavailable during startup or tests.
      return [];
    }
  }

  static Future<List<Map<String, String>>> voicesInDirectory(
    Directory directory,
  ) async {
    final root = directory.path;
    final result = <Map<String, String>>[];
    if (await _ready(root, melo)) {
      result.add({
        'name': 'MeloTTS 中文 / English',
        'locale': 'zh-CN',
        'identifier': '$prefix$melo:0',
      });
    }
    if (await _ready(root, kokoro)) {
      for (var sid = 0; sid < 103; sid++) {
        final category = sid < 2
            ? 'English US female'
            : sid == 2
            ? 'English UK female'
            : sid < 58
            ? '中文女声'
            : '中文男声';
        result.add({
          'name': 'Kokoro 1.1 $category ${sid.toString().padLeft(3, '0')}',
          'locale': sid < 3 ? 'en' : 'zh-CN',
          'identifier': '$prefix$kokoro:$sid',
        });
      }
    }
    return result;
  }

  /// Inference runs outside the UI isolate. No audio is sent to the radio here.
  static Future<({Float32List samples, int sampleRate})?> synthesize(
    String identifier,
    String text,
    double rate,
  ) async {
    if (!Platform.isWindows || !identifier.startsWith(prefix)) return null;
    final pieces = identifier.substring(prefix.length).split(':');
    if (pieces.length != 2 || ![kokoro, melo].contains(pieces[0])) return null;
    final sid = int.tryParse(pieces[1]);
    if (sid == null ||
        sid < 0 ||
        (pieces[0] == kokoro ? sid >= 103 : sid != 0)) {
      return null;
    }
    final root = (await directory()).path;
    if (!await _ready(root, pieces[0])) return null;
    final dir = _path(root, pieces[0]);
    final model = pieces[0];
    final speed = (0.5 + rate.clamp(0.0, 1.0)).toDouble();
    return Isolate.run(() {
      sherpa.initBindings();
      String p(String name) => _path(dir, name);
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          numThreads: 2,
          debug: false,
          kokoro: model == kokoro
              ? sherpa.OfflineTtsKokoroModelConfig(
                  model: p('model.onnx'),
                  voices: p('voices.bin'),
                  tokens: p('tokens.txt'),
                  dataDir: p('espeak-ng-data'),
                  lexicon: '${p('lexicon-us-en.txt')},${p('lexicon-zh.txt')}',
                )
              : const sherpa.OfflineTtsKokoroModelConfig(),
          vits: model == melo
              ? sherpa.OfflineTtsVitsModelConfig(
                  model: p('model.onnx'),
                  tokens: p('tokens.txt'),
                  lexicon: p('lexicon.txt'),
                )
              : const sherpa.OfflineTtsVitsModelConfig(),
        ),
        ruleFsts: model == melo ? '${p('date.fst')},${p('number.fst')}' : '',
      );
      final engine = sherpa.OfflineTts(config);
      try {
        final audio = engine.generate(text: text, sid: sid, speed: speed);
        if (audio.samples.isEmpty || audio.sampleRate <= 0) return null;
        return (samples: audio.samples, sampleRate: audio.sampleRate);
      } finally {
        engine.free();
      }
    });
  }
}
