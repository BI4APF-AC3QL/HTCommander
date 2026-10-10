import 'aprs_events.dart';
import 'message_data.dart';

/// Host-owned bounded conversation view. ACK/REJ are tracked separately.
class ConversationHistory {
  ConversationHistory({this.capacity = 100}) {
    if (capacity < 1) throw ArgumentError.value(capacity);
  }
  final int capacity;
  final List<Map<String, Object>> _messages = [];
  int _nextId = 0;
  List<Map<String, Object>> get messages =>
      _messages.map((e) => Map<String, Object>.unmodifiable(e)).toList();

  // Keep IDs monotonic so a connected phone does not confuse a new message
  // with a previously read one after the host clears history.
  void clear() => _messages.clear();

  bool add(AprsFrameEventArgs event, String localCallsign) {
    final packet = event.aprsPacket;
    final message = packet.messageData;
    if (message.msgType != MessageType.mtGeneral || message.msgText.isEmpty) {
      return false;
    }
    String normalize(String value) =>
        value.trim().toUpperCase().replaceFirst(RegExp(r'-0$'), '');
    final source = normalize(packet.sourceCallsignWithId);
    final destination = normalize(message.addressee);
    final local = normalize(localCallsign);
    if (local.isEmpty || (source != local && destination != local)) {
      return false;
    }
    final incoming = source != local;
    final time = event.ax25Packet.time;
    final text = message.msgText.length > 512
        ? message.msgText.substring(0, 512)
        : message.msgText;
    if (_messages.any(
      (e) =>
          e['source'] == source &&
          e['destination'] == destination &&
          e['sequence'] == message.seqId &&
          e['text'] == text &&
          (message.seqId.isEmpty
              ? time.isAtSameMomentAs(DateTime.parse(e['time'] as String))
              : time.difference(DateTime.parse(e['time'] as String)).abs() <
                    const Duration(minutes: 5)),
    )) {
      return false;
    }
    _messages.add({
      'id': ++_nextId,
      'source': source,
      'destination': destination,
      'peer': incoming ? source : destination,
      'incoming': incoming,
      'sequence': message.seqId,
      'text': text,
      'time': time.toUtc().toIso8601String(),
      'viaInternet': packet.fromAprsIs,
    });
    _messages.sort((a, b) {
      final order = DateTime.parse(
        a['time'] as String,
      ).compareTo(DateTime.parse(b['time'] as String));
      return order == 0 ? (a['id'] as int).compareTo(b['id'] as int) : order;
    });
    while (_messages.length > capacity) {
      _messages.removeAt(0);
    }
    return _messages.any((e) => e['id'] == _nextId);
  }
}
