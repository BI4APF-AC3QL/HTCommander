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
    if (message.seqId.isNotEmpty &&
        _messages.any(
          (e) =>
              e['source'] == source &&
              e['destination'] == destination &&
              e['sequence'] == message.seqId &&
              e['text'] == message.msgText &&
              time.difference(DateTime.parse(e['time'] as String)).abs() <
                  const Duration(minutes: 5),
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
      'text': message.msgText.length > 512
          ? message.msgText.substring(0, 512)
          : message.msgText,
      'time': time.toIso8601String(),
      'viaInternet': packet.fromAprsIs,
    });
    while (_messages.length > capacity) {
      _messages.removeAt(0);
    }
    return true;
  }
}
