import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

class _OutputFrame {
  _OutputFrame(this.data, this.bytes, this.audio, this.created);
  final Object data;
  final int bytes;
  final bool audio;
  final Duration created;
}

/// Serializes writes against the socket's stream backpressure. Budget includes
/// the active frame; it is not a measurement of OS buffers or TCP delivery.
class BoundedWebSocketOutput {
  BoundedWebSocketOutput({
    required Future<void> Function(Object) write,
    required void Function(String) onFailure,
    Duration Function()? clock,
    this.maxBytes = 512 * 1024,
    this.maxMessages = 128,
    this.writeTimeout = const Duration(seconds: 3),
    this.audioMaxAge = const Duration(milliseconds: 500),
    // Public callback names keep construction readable.
    // ignore: prefer_initializing_formals
  }) : _write = write,
       // ignore: prefer_initializing_formals
       _onFailure = onFailure {
    final watch = Stopwatch()..start();
    _clock = clock ?? () => watch.elapsed;
  }

  final Future<void> Function(Object) _write;
  final void Function(String) _onFailure;
  late final Duration Function() _clock;
  final int maxBytes, maxMessages;
  final Duration writeTimeout, audioMaxAge;
  final Queue<_OutputFrame> _queue = Queue();
  _OutputFrame? _active;
  Timer? _writeTimer, _pumpTimer;
  int _bytes = 0, droppedAudioBlocks = 0;
  bool _closed = false;
  String? failure;

  Map<String, Object> get snapshot => {
    'queuedPayloadBytes': _bytes,
    'queuedMessages': _queue.length + (_active == null ? 0 : 1),
    'writing': _active != null,
    'droppedAudioBlocks': droppedAudioBlocks,
  };

  bool get closed => _closed;

  bool enqueue(Object data, {bool audio = false}) {
    if (_closed) return false;
    final bytes = data is String
        ? utf8.encode(data).length
        : (data as List<int>).length;
    if (bytes > maxBytes) {
      if (audio) {
        droppedAudioBlocks++;
      } else {
        _fail('output_message_too_large');
      }
      return false;
    }
    _expireAudio();
    bool fits() =>
        _bytes + bytes <= maxBytes &&
        _queue.length + (_active == null ? 0 : 1) < maxMessages;
    while (!fits()) {
      final candidates = _queue.where((frame) => frame.audio);
      if (candidates.isEmpty) break;
      _discard(candidates.first);
    }
    if (!fits()) {
      if (audio) {
        droppedAudioBlocks++;
      } else {
        _fail('output_queue_overflow');
      }
      return false;
    }
    // Socket output must not retain caller-owned mutable radio PCM buffers.
    final payload = data is String
        ? data
        : Uint8List.fromList(data as List<int>);
    _queue.add(_OutputFrame(payload, bytes, audio, _clock()));
    _bytes += bytes;
    if (_pumpTimer == null) _pump();
    return true;
  }

  void _discard(_OutputFrame frame) {
    _queue.remove(frame);
    _bytes -= frame.bytes;
    droppedAudioBlocks++;
  }

  void _expireAudio() {
    final now = _clock();
    for (final frame in _queue.toList()) {
      if (frame.audio && now - frame.created >= audioMaxAge) _discard(frame);
    }
  }

  void _pump() {
    if (_closed || _active != null) return;
    _expireAudio();
    if (_queue.isEmpty) return;
    final frame = _active = _queue.removeFirst();
    _writeTimer = Timer(writeTimeout, () => _fail('output_write_timeout'));
    Future<void>.sync(() => _write(frame.data)).then<void>((_) {
      if (_closed || !identical(_active, frame)) return;
      _writeTimer?.cancel();
      _writeTimer = null;
      _bytes -= frame.bytes;
      _active = null;
      // Yield to input/paint/other clients even if writes finish immediately.
      if (_queue.isNotEmpty) {
        _pumpTimer = Timer(Duration.zero, () {
          _pumpTimer = null;
          _pump();
        });
      }
    }, onError: (Object _, StackTrace _) => _fail('output_write_failed'));
  }

  void _fail(String reason) {
    if (_closed) return;
    failure = reason;
    close();
    _onFailure(reason);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _writeTimer?.cancel();
    _pumpTimer?.cancel();
    _writeTimer = _pumpTimer = null;
    _queue.clear();
    _active = null;
    _bytes = 0;
  }
}
