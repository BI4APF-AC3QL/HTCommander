import 'dart:math' as math;
import 'dart:typed_data';

/// Adjusts 16-bit mono PCM and smoothly limits boosted peaks to avoid clipping.
Uint8List applyTtsOutputGain(Uint8List pcm, double requestedGain) {
  final gain = requestedGain.isFinite ? requestedGain.clamp(0.5, 4.0) : 1.0;
  if (gain == 1.0 || pcm.length < 2) return pcm;
  final result = Uint8List.fromList(pcm);
  final input = ByteData.sublistView(pcm);
  final output = ByteData.sublistView(result);
  for (var offset = 0; offset + 1 < pcm.length; offset += 2) {
    var sample = input.getInt16(offset, Endian.little) / 32768.0 * gain;
    final magnitude = sample.abs();
    if (gain > 1 && magnitude > 0.8) {
      final limited = 0.8 + 0.2 * (1 - math.exp(-(magnitude - 0.8) / 0.2));
      sample = sample.isNegative ? -limited : limited;
    }
    output.setInt16(
      offset,
      (sample * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return result;
}
