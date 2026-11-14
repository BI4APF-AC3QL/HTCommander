import 'dart:math' as math;
import 'dart:typed_data';

/// Receive-only, per-connection preference and application-payload counters.
/// These counters are submitted bytes, not TCP delivery or RF packet loss.
class RemoteMediaProfile {
  bool lowBandwidth = false;
  int audioBytes = 0;
  int audioFrames = 0;
  int skippedBlocks = 0;

  static bool validCommand(Map command) =>
      command.length == 2 &&
      command['op'] == 'media' &&
      command['lowBandwidth'] is bool;

  Map<String, Object> get snapshot => {
    'lowBandwidth': lowBandwidth,
    'audioPayloadBytes': audioBytes,
    'audioFrames': audioFrames,
    'skippedBlocks': skippedBlocks,
    'receiveSampleRate': lowBandwidth ? 8000 : 0,
  };

  void submitted(int bytes) {
    audioBytes += bytes;
    audioFrames++;
  }
}

/// Streaming mono 8 kHz voice receive converter. A windowed-sinc FIR prevents
/// high-frequency input from aliasing into the voice band. Fractional phases
/// support 44.1 kHz as well as integral source/output ratios. History/filter
/// memory is fixed; source format changes reset history without old playback.
class RemoteReceiveEncoder {
  static const outputRate = 8000;
  static const _taps = 95;
  static const _phases = 128;
  final _history = Float64List(_taps);
  List<Float64List> _filters = [];
  int _rate = 0, _channels = 0, _cursor = 0, _phase = 0;

  void reset() {
    _rate = _channels = _cursor = _phase = 0;
    _history.fillRange(0, _taps, 0);
    _filters = [];
  }

  static bool valid(Int16List pcm, int rate, int channels) =>
      rate >= 8000 &&
      rate <= 48000 &&
      (channels == 1 || channels == 2) &&
      pcm.isNotEmpty &&
      pcm.length % channels == 0 &&
      pcm.length ~/ channels <= rate; // At most one second per source block.

  static Uint8List? normal(Int16List pcm, int rate, int channels) {
    if (!valid(pcm, rate, channels)) return null;
    final packet = Uint8List(4 + pcm.length * 2);
    final data = ByteData.sublistView(packet);
    packet[0] = 0xf1;
    packet[1] = channels;
    data.setUint16(2, rate, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      data.setInt16(4 + 2 * i, pcm[i], Endian.little);
    }
    return packet;
  }

  void _configure(int rate, int channels) {
    if (_rate == rate && _channels == channels) return;
    reset();
    _rate = rate;
    _channels = channels;
    if (rate == outputRate) return;
    final cutoff = 3200 / rate;
    _filters = List.generate(_phases, (phase) {
      final filter = Float64List(_taps);
      final delay = (_taps - 1) / 2 + phase / _phases;
      var sum = 0.0;
      for (var k = 0; k < _taps; k++) {
        final x = k - delay;
        final sinc = x.abs() < 1e-9
            ? 2 * cutoff
            : math.sin(2 * math.pi * cutoff * x) / (math.pi * x);
        final window = .54 - .46 * math.cos(2 * math.pi * k / (_taps - 1));
        filter[k] = sinc * window;
        sum += filter[k];
      }
      for (var k = 0; k < _taps; k++) {
        filter[k] /= sum;
      }
      return filter;
    }, growable: false);
  }

  Uint8List? low(Int16List pcm, int rate, int channels) {
    if (!valid(pcm, rate, channels)) {
      reset();
      return null;
    }
    _configure(rate, channels);
    final frames = pcm.length ~/ channels;
    final count = (_phase + frames * outputRate) ~/ rate;
    if (count == 0) {
      // Still consume the block so tiny source blocks do not lose time.
      _consume(pcm, frames, channels, null);
      return null;
    }
    final packet = Uint8List(4 + count * 2);
    packet[0] = 0xf1;
    packet[1] = 1;
    final data = ByteData.sublistView(packet);
    data.setUint16(2, outputRate, Endian.little);
    _consume(pcm, frames, channels, data);
    return packet;
  }

  void _consume(Int16List pcm, int frames, int channels, ByteData? output) {
    var out = 0;
    for (var i = 0; i < frames; i++) {
      final value = channels == 1
          ? pcm[i].toDouble()
          : (pcm[2 * i] + pcm[2 * i + 1]) / 2;
      _cursor = (_cursor + 1) % _taps;
      _history[_cursor] = value;
      _phase += outputRate;
      if (_phase < _rate) continue;
      _phase -= _rate;
      var sample = value;
      if (_rate != outputRate) {
        final filter =
            _filters[(_phase * _phases ~/ outputRate).clamp(0, _phases - 1)];
        sample = 0;
        for (var k = 0; k < _taps; k++) {
          sample += _history[(_cursor - k + _taps) % _taps] * filter[k];
        }
      }
      output?.setInt16(
        4 + 2 * out,
        sample.round().clamp(-32768, 32767),
        Endian.little,
      );
      out++;
    }
  }
}
