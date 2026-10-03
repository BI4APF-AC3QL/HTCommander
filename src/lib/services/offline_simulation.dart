import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../aprs/message_delivery.dart';
import 'web/remote_media.dart';

/// A dialog-scoped sandbox. No broker, transport, network, microphone, player
/// or persistence dependency exists here; events never enter real handlers.
class OfflineSimulation extends ChangeNotifier {
  OfflineSimulation() {
    _tracker = MessageDeliveryTracker(clock: () => _time, capacity: 20);
  }
  late final MessageDeliveryTracker _tracker;
  DateTime _time = DateTime.utc(2026, 1, 1);
  bool _connected = false, _disposed = false;
  int _sequence = 0, _rxFrames = 0, _normalBytes = 0, _lowBytes = 0;
  final _encoder = RemoteReceiveEncoder();
  bool get connected => _connected;
  int get rxFrames => _rxFrames;
  int get normalBytes => _normalBytes;
  int get lowBytes => _lowBytes;
  DateTime get time => _time;
  List<Map<String, Object>> get deliveries => _tracker.entries
      .map((e) => Map<String, Object>.unmodifiable(e.toJson()))
      .toList(growable: false);

  void connect() {
    if (_disposed || _connected) return;
    _connected = true;
    notifyListeners();
  }

  void disconnect() {
    if (_disposed || !_connected) return;
    _connected = false;
    _tracker.cancelAll();
    _encoder.reset();
    notifyListeners();
  }

  bool createMessage() {
    if (_disposed ||
        !_connected ||
        _tracker.entries.where((e) => e.pending).length >= 20) {
      return false;
    }
    final id = (++_sequence).toString();
    _tracker.start('demo-$id', 'DEMO-1', 'DEMO-2', id);
    notifyListeners();
    return true;
  }

  bool reply(String sequence, {bool rejected = false}) {
    if (_disposed || !_connected) return false;
    final result = _tracker.acknowledge(
      'DEMO-2',
      'DEMO-1',
      sequence,
      rejected: rejected,
    );
    if (result) notifyListeners();
    return result;
  }

  void advance() {
    if (_disposed) return;
    _time = _time.add(const Duration(seconds: 30));
    // Retry candidates stay inside the tracker. No dispatch callback exists.
    _tracker.tick(allowed: (_) => _connected);
    notifyListeners();
  }

  void receiveTone() {
    if (_disposed || !_connected) return;
    final pcm = Int16List.fromList(
      List.generate(
        3200,
        (i) => (8000 * math.sin(2 * math.pi * 1000 * i / 32000)).round(),
      ),
    );
    final standard = RemoteReceiveEncoder.normal(pcm, 32000, 1)!;
    final low = _encoder.low(pcm, 32000, 1)!;
    _rxFrames++;
    _normalBytes += standard.length;
    _lowBytes += low.length;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connected = false;
    _tracker.cancelAll();
    _encoder.reset();
    super.dispose();
  }
}
