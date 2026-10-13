import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/android_speech_to_text_engine.dart';
import 'package:htcommander/handlers/speech_to_text_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.htcommander/android_speech_to_text');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the offline fallback when the Android PCM API is unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'isSupported' => false,
            'isSherpaFallbackSupported' => true,
            _ => null,
          };
        });

    final fallback = _FakeSpeechToTextEngine();
    var factoryCalls = 0;
    final engine = AndroidSpeechToTextEngine(
      fallbackFactory: () {
        factoryCalls++;
        return fallback;
      },
    );
    final resultExpectation = expectLater(
      engine.results,
      emits(const SpeechResult('received words', true)),
    );

    expect(await engine.initialize(localeId: 'zh-CN'), isTrue);
    expect(factoryCalls, 1);
    expect(fallback.localeId, 'zh-CN');

    fallback.resultsController.add(const SpeechResult('received words', true));
    await resultExpectation;
    await engine.startSegment();
    await engine.processPcm16(Uint8List.fromList([1, 0]), 0, 2, 32000);
    await engine.completeSegment();
    expect(fallback.startedSegments, 1);
    expect(fallback.processedSampleRates, [32000]);
    expect(fallback.completedSegments, 1);

    await engine.dispose();
    expect(fallback.disposed, isTrue);
  });

  test('does not start a fallback when its native ABI is unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'isSupported' => false,
            'isSherpaFallbackSupported' => false,
            _ => null,
          };
        });

    var factoryCalls = 0;
    final engine = AndroidSpeechToTextEngine(
      fallbackFactory: () {
        factoryCalls++;
        return _FakeSpeechToTextEngine();
      },
    );

    expect(await engine.initialize(), isFalse);
    expect(factoryCalls, 0);
    await engine.dispose();
  });

  test('falls back when the supported Android recognizer cannot initialize', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'isSupported' => true,
            'isSherpaFallbackSupported' => true,
            _ => null,
          };
        });

    final fallback = _FakeSpeechToTextEngine();
    final engine = AndroidSpeechToTextEngine(
      fallbackFactory: () => fallback,
      systemRecognizerInitializer: (_) async => false,
    );

    expect(await engine.initialize(localeId: 'zh-CN'), isTrue);
    expect(fallback.localeId, 'zh-CN');
    await engine.dispose();
  });
}

class _FakeSpeechToTextEngine implements SpeechToTextEngine {
  final StreamController<SpeechResult> resultsController =
      StreamController<SpeechResult>.broadcast();
  final StreamController<bool> processingController =
      StreamController<bool>.broadcast();
  final List<int> processedSampleRates = [];

  bool disposed = false;
  String? localeId;
  int startedSegments = 0;
  int completedSegments = 0;

  @override
  bool get isSupported => true;

  @override
  bool get isReady => !disposed;

  @override
  Stream<SpeechResult> get results => resultsController.stream;

  @override
  Stream<bool> get processing => processingController.stream;

  @override
  Future<bool> initialize({String localeId = ''}) async {
    this.localeId = localeId;
    return true;
  }

  @override
  Future<void> startSegment() async => startedSegments++;

  @override
  Future<void> processPcm16(
    Uint8List data,
    int offset,
    int length,
    int sampleRate,
  ) async {
    processedSampleRates.add(sampleRate);
  }

  @override
  Future<void> completeSegment() async => completedSegments++;

  @override
  Future<void> splitSegment() async {}

  @override
  Future<void> resetSegment() async {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await resultsController.close();
    await processingController.close();
  }
}
