import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'rolling_voice_store.dart';

void _worker(Map message) {
  final port = ReceivePort(), host = message['host'] as SendPort;
  RollingVoiceStore? store;
  Timer? timer;
  void publish([String? error]) {
    host.send({'event': 'state', ...?(store?.snapshot()), 'error': error});
  }

  try {
    store = RollingVoiceStore(
      Directory(message['folder'] as String),
      retention: Duration(hours: message['hours'] as int),
    );
  } catch (_) {
    host.send({'event': 'fatal', 'error': 'storage_open_failed'});
    port.close();
    return;
  }
  host.send({'event': 'ready', 'port': port.sendPort});
  publish();
  timer = Timer.periodic(const Duration(minutes: 1), (_) {
    try {
      store!.maintenance();
      publish();
    } catch (_) {
      host.send({'event': 'fatal', 'error': 'storage_write_failed'});
      timer?.cancel();
      port.close();
    }
  });
  port.listen((dynamic raw) {
    final m = raw as Map;
    try {
      switch (m['op']) {
        case 'pcm':
          final pcm = (m['pcm'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          store!.append(m['radio'] as int, m['channel'] as String, pcm);
          break;
        case 'status':
          publish();
          break;
        case 'hours':
          store!.retention = Duration(hours: m['hours'] as int);
          store.prune();
          publish();
          break;
        case 'preserve':
          publish(store!.preserveLatest());
          break;
        case 'stop':
          store!.finish();
          publish();
          timer?.cancel();
          port.close();
          host.send({'event': 'stopped'});
          return;
      }
      if (m['op'] == 'pcm') host.send({'event': 'ack', 'bytes': m['bytes']});
    } catch (_) {
      host.send({'event': 'fatal', 'error': 'storage_write_failed'});
      try {
        store?.finish();
      } catch (_) {}
      timer?.cancel();
      port.close();
    }
  });
}

/// A bounded host-to-worker mailbox; it never waits for disk on the UI isolate.
class RollingVoiceRecorder {
  RollingVoiceRecorder({required this.onState});
  final void Function(Map<String, Object?>) onState;
  Isolate? _isolate;
  ReceivePort? _receive;
  SendPort? _port;
  Completer<void>? _ready, _stopped;
  Timer? _poll;
  int _pendingBytes = 0, _droppedBytes = 0, _generation = 0;
  bool _closing = false, _wanted = false;
  int _request = 0;
  Future<void> _transition = Future.value();
  static const maxPendingBytes = 512 * 1024;
  int get pendingBytes => _pendingBytes;
  bool get ready => _port != null && !_closing && _wanted;
  Future<void> start(String folder, int hours) {
    final request = ++_request;
    _wanted = true;
    return _transition = _transition.catchError((Object _) {}).then((_) async {
      if (request != _request) return;
      await _stopInternal();
      if (request != _request) return;
      await _start(folder, hours);
      if (request != _request) await _stopInternal();
    });
  }

  Future<void> _start(String folder, int hours) async {
    _closing = false;
    final generation = ++_generation;
    _ready = Completer<void>();
    _stopped = Completer<void>();
    _receive = ReceivePort();
    _receive!.listen((dynamic raw) {
      if (generation != _generation) return;
      if ((raw == null || raw is List) && _closing) return;
      final m = raw is Map
          ? Map<String, Object?>.from(raw)
          : <String, Object?>{'event': 'fatal', 'error': 'worker_stopped'};
      switch (m['event']) {
        case 'ready':
          _port = m['port'] as SendPort;
          if (!_ready!.isCompleted) _ready!.complete();
          break;
        case 'ack':
          _pendingBytes = (_pendingBytes - (m['bytes'] as int)).clamp(
            0,
            maxPendingBytes,
          );
          break;
        case 'state':
          onState({
            ...m,
            'pendingBytes': _pendingBytes,
            'droppedBytes': _droppedBytes,
            'running': !_closing,
          });
          break;
        case 'fatal':
          onState({...m, 'running': false, 'droppedBytes': _droppedBytes});
          if (!_ready!.isCompleted) {
            _ready!.completeError(StateError('Recorder unavailable'));
          }
          unawaited(stop());
          break;
        case 'stopped':
          if (!_stopped!.isCompleted) _stopped!.complete();
          break;
      }
    });
    try {
      final spawn =
          Isolate.spawn(
            _worker,
            {'host': _receive!.sendPort, 'folder': folder, 'hours': hours},
            onExit: _receive!.sendPort,
            onError: _receive!.sendPort,
          ).then<void>((isolate) {
            if (generation != _generation) {
              isolate.kill(priority: Isolate.immediate);
            } else {
              _isolate = isolate;
            }
          });
      await Future.wait<void>([
        spawn,
        _ready!.future.timeout(const Duration(seconds: 10)),
      ], eagerError: true);
      if (generation != _generation) return;
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _port?.send({'op': 'status'}),
      );
    } catch (_) {
      await _stopInternal();
      rethrow;
    }
  }

  bool append(int radio, String channel, Uint8List pcm) {
    if (!ready || pcm.isEmpty || pcm.length.isOdd || pcm.length > 256 * 1024) {
      return false;
    }
    if (_pendingBytes + pcm.length > maxPendingBytes) {
      _droppedBytes += pcm.length;
      return false;
    }
    _pendingBytes += pcm.length;
    _port!.send({
      'op': 'pcm',
      'radio': radio,
      'channel': channel,
      'bytes': pcm.length,
      'pcm': TransferableTypedData.fromList([pcm]),
    });
    return true;
  }

  void setHours(int hours) => _port?.send({'op': 'hours', 'hours': hours});
  void preserveLatest() => _port?.send({'op': 'preserve'});
  Future<void> stop() {
    _wanted = false;
    _request++;
    return _transition = _transition
        .catchError((Object _) {})
        .then((_) => _stopInternal());
  }

  Future<void> _stopInternal() async {
    if (_closing) return;
    _closing = true;
    _poll?.cancel();
    _poll = null;
    final stopped = _stopped, port = _port;
    _port = null;
    if (port != null) {
      port.send({'op': 'stop'});
      try {
        await stopped?.future.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    _generation++;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receive?.close();
    _receive = null;
    _pendingBytes = 0;
  }
}
