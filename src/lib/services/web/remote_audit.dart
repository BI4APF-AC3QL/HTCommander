import 'dart:collection';
import 'dart:convert';

/// Memory-only event metadata. Never accepts message text, credentials,
/// addresses, coordinates, audio, or user-provided error strings.
class RemoteAudit {
  RemoteAudit({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  final _events = ListQueue<Map<String, Object>>();
  int _sequence = 0;
  final _lastDenial = <(int, String), DateTime>{};
  static const actions = {
    'requestControl',
    'releaseControl',
    'handoffControl',
    'grantControl',
    'recallControl',
    'disconnect',
    'revokeLogin',
    'readOnlyRole',
    'channel',
    'volume',
    'squelch',
    'satelliteStart',
    'satelliteStop',
    'scan',
    'aprsMessage',
    'aprsPosition',
    'pttStart',
    'pttStop',
    'pttRelease',
    'invalidCommand',
    'rawWrite',
    'writeDenied',
  };
  static const results = {'accepted', 'denied', 'released'};

  bool record({
    required int clientId,
    required int radioId,
    required String action,
    required String result,
    int? affectedClient,
  }) {
    if (!actions.contains(action) || !results.contains(result)) {
      throw ArgumentError('Only known audit metadata is allowed');
    }
    final now = _clock();
    if (result == 'denied') {
      final key = (clientId, action);
      final previous = _lastDenial[key];
      if (previous != null &&
          now.difference(previous) < const Duration(seconds: 1)) {
        return false;
      }
      _lastDenial.remove(key);
      _lastDenial[key] = now;
      if (_lastDenial.length > 200) _lastDenial.remove(_lastDenial.keys.first);
    }
    _events.add(
      Map<String, Object>.unmodifiable({
        'id': ++_sequence,
        'time': now.toUtc().toIso8601String(),
        'clientId': clientId,
        'radioId': radioId,
        'action': action,
        'result': result,
        'affectedClient': ?affectedClient,
      }),
    );
    while (_events.length > 200) {
      _events.removeFirst();
    }
    return true;
  }

  List<Map<String, Object>> get events => List.unmodifiable(_events);
  static Map<String, Object> _safeEvent(Map event) {
    final value = <String, Object>{};
    for (final key in ['id', 'clientId', 'radioId', 'affectedClient']) {
      final number = event[key];
      if (number is int) value[key] = number;
    }
    final time = event['time'];
    if (time is String && time.length <= 64) {
      final parsed = DateTime.tryParse(time);
      if (parsed != null) value['time'] = parsed.toUtc().toIso8601String();
    }
    value['action'] = event['action'] as String;
    value['result'] = event['result'] as String;
    return value;
  }

  static String export(List<Map> events) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': 'htcommander-remote-audit-v1',
        'notice':
            'Accepted means a software request was accepted, not RF delivery.',
        'events': events
            .take(200)
            .where(
              (event) =>
                  actions.contains(event['action']) &&
                  results.contains(event['result']),
            )
            .map(_safeEvent)
            .toList(),
      });
}
