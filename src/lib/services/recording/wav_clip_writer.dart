import 'dart:io';
import 'dart:typed_data';

/// Ordered, bounded WAV writer for live audio callbacks.
///
/// Audio frames are copied into a small queue and written asynchronously so a
/// slow disk cannot block the radio/UI isolate. If storage falls behind, new
/// frames are dropped once the queue is full instead of growing memory without
/// limit.
class WavClipWriter {
  WavClipWriter._(this._file, this.sampleRate);

  static const int maxPendingBytes = 512 * 1024;

  final RandomAccessFile _file;
  final int sampleRate;
  Future<void> _writeTail = Future<void>.value();
  Future<WavClipWriterResult>? _closeFuture;
  int _pendingBytes = 0;
  int _dataBytes = 0;
  int _droppedBytes = 0;
  bool _closing = false;
  bool _writeFailed = false;

  int get pendingBytes => _pendingBytes;
  int get droppedBytes => _droppedBytes;

  static WavClipWriter? open(String path, int sampleRate) {
    RandomAccessFile? file;
    try {
      file = File(path).openSync(mode: FileMode.write);
      file.writeFromSync(_header(0, sampleRate));
      return WavClipWriter._(file, sampleRate);
    } catch (_) {
      try {
        file?.closeSync();
      } catch (_) {}
      return null;
    }
  }

  /// Queues a PCM slice and returns immediately. The bytes are copied because
  /// Bluetooth audio buffers may be reused by the producer after this callback.
  bool write(Uint8List bytes, int offset, int length) {
    if (_closing ||
        length <= 0 ||
        length.isOdd ||
        offset < 0 ||
        offset + length > bytes.length) {
      return false;
    }
    if (_pendingBytes + length > maxPendingBytes) {
      _droppedBytes += length;
      return false;
    }

    final chunk = Uint8List.fromList(bytes.sublist(offset, offset + length));
    _pendingBytes += length;
    _writeTail = _writeTail.then((_) async {
      try {
        if (_writeFailed) {
          _droppedBytes += chunk.length;
          return;
        }
        await _file.writeFrom(chunk);
        _dataBytes += chunk.length;
      } catch (_) {
        _writeFailed = true;
        _droppedBytes += chunk.length;
      } finally {
        _pendingBytes -= chunk.length;
      }
    });
    return true;
  }

  Future<WavClipWriterResult> close() => _closeFuture ??= _close();

  Future<WavClipWriterResult> _close() async {
    _closing = true;
    var closeFailed = false;
    await _writeTail;
    try {
      await _file.setPosition(0);
      await _file.writeFrom(_header(_dataBytes, sampleRate));
      await _file.flush();
    } catch (_) {
      closeFailed = true;
    } finally {
      try {
        await _file.close();
      } catch (_) {
        closeFailed = true;
      }
    }
    return WavClipWriterResult(
      dataBytes: _dataBytes,
      droppedBytes: _droppedBytes,
      failed: _writeFailed || closeFailed,
    );
  }

  static Uint8List _header(int dataBytes, int sampleRate) {
    const channels = 1;
    const bitsPerSample = 16;
    final bytes = Uint8List(44);
    final bd = ByteData.sublistView(bytes);
    void tag(int at, String value) => bytes.setRange(
      at,
      at + value.length,
      value.codeUnits,
    );

    tag(0, 'RIFF');
    bd.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, channels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * channels * bitsPerSample ~/ 8, Endian.little);
    bd.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    bd.setUint16(34, bitsPerSample, Endian.little);
    tag(36, 'data');
    bd.setUint32(40, dataBytes, Endian.little);
    return bytes;
  }
}

class WavClipWriterResult {
  const WavClipWriterResult({
    required this.dataBytes,
    required this.droppedBytes,
    required this.failed,
  });

  final int dataBytes;
  final int droppedBytes;
  final bool failed;
}
