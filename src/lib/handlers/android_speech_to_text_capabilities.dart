import 'package:flutter/services.dart';

/// Android recognition capabilities exposed by the native application plugin.
/// Kept separate from native recognizer engines so browser builds can query
/// Android UI state without importing dart:ffi libraries.
class AndroidSpeechToTextCapabilities {
  AndroidSpeechToTextCapabilities._();

  static const MethodChannel _channel = MethodChannel(
    'com.htcommander/android_speech_to_text',
  );

  static Future<bool> get systemRecognizerAvailable async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> get sherpaFallbackAvailable async {
    try {
      return await _channel.invokeMethod<bool>('isSherpaFallbackSupported') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
