import 'dart:io';
import 'dart:typed_data';

import 'rolling_voice_clip_path.dart';

Future<Uint8List> readRollingVoiceClipBytes(
  String folder,
  String name, {
  required bool kept,
}) {
  return File(rollingVoiceClipPath(folder, name, kept: kept)).readAsBytes();
}
