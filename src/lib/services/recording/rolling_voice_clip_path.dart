import 'package:path/path.dart' as path;

/// Resolves a clip listed in recorder status to its local WAV path.
String rollingVoiceClipPath(String folder, String name, {required bool kept}) {
  return kept ? path.join(folder, 'kept', name) : path.join(folder, name);
}
