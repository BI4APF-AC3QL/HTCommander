import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/conversation_history.dart';
import 'package:htcommander/aprs/aprs_events.dart';
import 'package:htcommander/aprs/aprs_packet.dart';
import 'package:htcommander/radio/ax25_address.dart';
import 'package:htcommander/radio/ax25_packet.dart';

AprsFrameEventArgs message(
  String source,
  String target,
  String text, {
  DateTime? time,
  bool internet = false,
}) {
  final frame = AX25Packet(
    addresses: [AX25Address.parse('APRS')!, AX25Address.parse(source)!],
    dataStr: ':${target.padRight(9)}:$text',
    type: FrameType.uFrameUi,
    command: true,
    time: time ?? DateTime(2026),
  );
  frame.pid = 240;
  final packet = AprsPacket.parse(frame)!;
  packet.fromAprsIs = internet;
  return AprsFrameEventArgs(packet, frame, null);
}

void main() {
  test(
    'conversation includes local incoming/outgoing and excludes ACK and others',
    () {
      final history = ConversationHistory();
      expect(history.add(message('BI4APF', 'AC3QL', 'Hello{1'), 'AC3QL'), true);
      expect(history.add(message('AC3QL', 'BI4APF', 'Reply{2'), 'AC3QL'), true);
      expect(history.messages.first['incoming'], true);
      expect(history.messages.last['incoming'], false);
      expect(history.messages.last['peer'], 'BI4APF');
      expect(history.add(message('BI4APF', 'AC3QL', 'ack2'), 'AC3QL'), false);
      expect(
        history.add(message('BI4APF', 'OTHER', 'Other{3'), 'AC3QL'),
        false,
      );
    },
  );
  test(
    'RF/IS duplicate suppression expires and history has bounded memory',
    () {
      final history = ConversationHistory(capacity: 2);
      final now = DateTime(2026);
      expect(history.add(message('BI4APF', 'AC3QL', 'Hello{1'), 'AC3QL'), true);
      expect(
        history.add(
          message('BI4APF', 'AC3QL', 'Hello{1', internet: true),
          'AC3QL',
        ),
        false,
      );
      expect(
        history.add(
          message(
            'BI4APF',
            'AC3QL',
            'Hello{1',
            time: now.add(const Duration(minutes: 6)),
          ),
          'AC3QL',
        ),
        true,
      );
      expect(history.add(message('AC3QL', 'BI4APF', 'Reply{2'), 'AC3QL'), true);
      expect(history.messages, hasLength(2));
      expect(history.messages.first['id'], 3);
      expect(history.messages.last['id'], 2);
      expect(
        () => history.messages.first['text'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );
  test(
    'late history cannot evict newer messages and clear keeps IDs unique',
    () {
      final history = ConversationHistory(capacity: 2);
      final now = DateTime(2026);
      history.add(message('W1AW', 'AC3QL', 'Live{3', time: now), 'AC3QL');
      history.add(
        message(
          'W1AW',
          'AC3QL',
          'Middle{2',
          time: now.subtract(const Duration(minutes: 1)),
        ),
        'AC3QL',
      );
      expect(
        history.add(
          message(
            'W1AW',
            'AC3QL',
            'Old{1',
            time: now.subtract(const Duration(minutes: 2)),
          ),
          'AC3QL',
        ),
        false,
      );
      expect(history.messages.map((m) => m['text']), ['Middle', 'Live']);
      final ids = history.messages.map((m) => m['id'] as int).toList();
      history.clear();
      expect(history.messages, isEmpty);
      history.add(message('W1AW', 'AC3QL', 'New{4'), 'AC3QL');
      expect(history.messages.single['id'] as int, greaterThan(ids.last));
    },
  );
}
