import '../data_broker.dart';
import '../../aprsis/gate_health.dart';
import 'remote_audit.dart';

/// Read-only, bounded summary. Unknown values remain null; snapshot time is
/// never presented as the time of a fresh radio status report.
abstract final class RemoteDashboard {
  static const gatewayStates = {
    'Connecting',
    'Disconnected',
    'Connected (verified)',
    'Connected (read-only)',
  };
  static const radioStates = {'Connected', 'Connecting', 'Disconnected'};
  static int? _count(Object? value) =>
      value is int && value >= 0 && value <= 9007199254740991 ? value : null;

  static Map<String, Object?> build({
    required int radioId,
    required DateTime now,
    required DateTime? radioReportAt,
    required List<Map<String, Object>> audit,
  }) {
    now = now.toUtc();
    final statusValue = DataBroker.getValueDynamic(radioId, 'HtStatus', null);
    final registered = radioId > 1 && radioId != 201;
    final link = DataBroker.getValueDynamic(radioId, 'State', null);
    final status = registered && link == 'Connected' && statusValue is Map
        ? statusValue
        : const <String, Object?>{};
    final settings = DataBroker.getValueDynamic(radioId, 'Settings', null);
    final selected = status['currChId'] is int
        ? status['currChId']
        : settings is Map
        ? settings['channelA']
        : null;
    final channels = DataBroker.getValueDynamic(radioId, 'Channels', null);
    Map? channel;
    if (registered &&
        link == 'Connected' &&
        channels is List &&
        selected is int) {
      for (final candidate in channels.take(256).whereType<Map>()) {
        if (candidate['channelId'] == selected) {
          channel = candidate;
          break;
        }
      }
    }
    final frequency = channel?['rxFreq'];
    final name = channel?['name'];
    final gateway = DataBroker.getValueDynamic(201, 'AprsIsState', null);
    final health = DataBroker.getValueDynamic(201, 'GateHealth', null);
    final hour = DateTime.utc(now.year, now.month, now.day, now.hour);
    final totals = <String, int?>{
      for (final key in GateHealth.counters) key: health is List ? 0 : null,
    };
    final seen = <DateTime>{};
    if (health is List) {
      for (final record in health.take(24).whereType<Map>()) {
        final time = record['hour'] is String
            ? DateTime.tryParse(record['hour'])?.toUtc()
            : null;
        if (time == null ||
            time.minute != 0 ||
            time.second != 0 ||
            time.millisecond != 0 ||
            time.microsecond != 0 ||
            time.isBefore(hour.subtract(const Duration(hours: 23))) ||
            time.isAfter(hour) ||
            GateHealth.counters.any((key) => _count(record[key]) == null) ||
            !seen.add(time)) {
          continue;
        }
        for (final key in totals.keys) {
          final number = _count(record[key]);
          final before = totals[key];
          totals[key] = number == null || before == null
              ? null
              : _count(before + number);
        }
      }
    }
    final deliveries = DataBroker.getValueDynamic(
      1,
      'RemoteAprsDeliveries',
      null,
    );
    final messages = <String, int?>{
      for (final key in [
        'waiting',
        'acknowledged',
        'rejected',
        'timedOut',
        'cancelled',
      ])
        key: deliveries is List ? 0 : null,
    };
    if (deliveries is List) {
      for (final entry in deliveries.take(100).whereType<Map>()) {
        if (messages.containsKey(entry['status'])) {
          final key = entry['status'] as String;
          messages[key] = messages[key]! + 1;
        }
      }
    }
    final recent = <Map<String, Object>>[];
    for (final event in audit.take(200).toList().reversed) {
      if (!RemoteAudit.actions.contains(event['action']) ||
          !RemoteAudit.results.contains(event['result']) ||
          _count(event['clientId']) == null) {
        continue;
      }
      final stamp = event['time'] is String
          ? DateTime.tryParse(event['time'] as String)
          : null;
      if (stamp == null || stamp.isAfter(now)) continue;
      recent.add({
        'time': stamp.toUtc().toIso8601String(),
        'clientId': event['clientId']!,
        'action': event['action']!,
        'result': event['result']!,
      });
      if (recent.length == 5) break;
    }
    final age = radioReportAt != null && !radioReportAt.isAfter(now)
        ? now.difference(radioReportAt).inSeconds
        : null;
    final rssi = status['rssi'];
    final clients = DataBroker.getValueDynamic(0, 'RemoteClients', null);
    return {
      'generatedAt': now.toIso8601String(),
      'radio': {
        'registered': registered,
        'link': !registered
            ? 'Disconnected'
            : radioStates.contains(link)
            ? link
            : null,
        'reportAgeSeconds': registered ? age : null,
        'reportAt': registered && age != null
            ? radioReportAt!.toUtc().toIso8601String()
            : null,
        'receiving': status['isInRx'] is bool ? status['isInRx'] : null,
        'transmitting': status['isInTx'] is bool ? status['isInTx'] : null,
        'scan': status['isScan'] is bool ? status['isScan'] : null,
        // Vendor RSSI is a 0..15 indicator, not a calibrated dBm measurement.
        'signalLevel': rssi is int && rssi >= 0 && rssi <= 15 ? rssi : null,
        'channel': name is String
            ? name.substring(0, name.length.clamp(0, 128))
            : null,
        'channelSource': channel == null
            ? null
            : status['currChId'] is int
            ? 'report'
            : 'settingsA',
        'rxFrequency':
            registered &&
                frequency is num &&
                frequency.isFinite &&
                frequency > 0 &&
                frequency <= 10000000000
            ? frequency
            : null,
      },
      'gateway': {
        'enabled': DataBroker.getValue<int>(0, 'AprsIsEnabled', 0) == 1,
        'link': gatewayStates.contains(gateway) ? gateway : null,
        'health': totals,
      },
      'messages': messages,
      'clientCount': clients is List ? clients.length : null,
      'activity': recent,
    };
  }
}
