import 'dart:typed_data';

import 'rolling_voice_clip_reader_stub.dart'
    if (dart.library.io) 'rolling_voice_clip_reader_io.dart' as platform;

/// Reads a completed local recording without exposing dart:io to web UI code.
Future<Uint8List> readRollingVoiceClipBytes(
  String folder,
  String name, {
  required bool kept,
}) {
  return platform.readRollingVoiceClipBytes(folder, name, kept: kept);
}
