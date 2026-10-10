/* Copyright 2026 Ylian Saint-Hilaire. Apache License 2.0. */
import 'dart:async';
import 'dart:convert';

import '../aprs/aprs_events.dart';
import '../aprs/aprs_packet.dart';
import '../aprs/aprs_util.dart';
import '../gps/gps_data.dart';
import '../radio/ax25_address.dart';
import '../radio/ax25_packet.dart';
import '../radio/radio.dart';
import '../services/data_broker.dart';
import '../services/data_broker_client.dart';
import 'beacon_schedule.dart';
import 'software_beacon_config.dart';

/// Host-owned beacon task. Saving settings and app startup never arm it.
/// Only a separately approved current revision starts the next full interval.
class SoftwareBeaconHandler {
  SoftwareBeaconHandler({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _schedule = BeaconSchedule(clock: _clock);
  }
  static const frameTag = 'software-beacon';
  final DateTime Function() _clock;
  final DataBrokerClient _broker = DataBrokerClient();
  late final BeaconSchedule _schedule;
  SoftwareBeaconConfig _config = const SoftwareBeaconConfig();
  Timer? _timer;
  DateTime? _radioReportAt;
  bool _disposed = false, _initialized = false;
  SoftwareBeaconConfig get config => _config;

  void init() {
    if (_initialized || _disposed) return;
    _initialized = true;
    _loadConfig(_broker.getValueDynamic(0, 'SoftwareBeaconConfig'));
    _schedule.configure(_config.intervalSeconds);
    _schedule.pause(_config.enabled ? 'restart' : 'disabled');
    _broker.subscribe(
      deviceId: 0,
      name: 'SoftwareBeaconConfig',
      callback: (_, _, value) {
        _pause('configuration');
        _radioReportAt = null;
        _loadConfig(value);
        _schedule.configure(_config.intervalSeconds);
        _publish();
      },
    );
    _broker.subscribe(
      deviceId: 0,
      name: 'SoftwareBeaconPause',
      callback: (_, _, _) => _pause('host'),
    );
    _broker.subscribe(
      deviceId: 0,
      name: 'SoftwareBeaconResume',
      callback: (_, _, revision) {
        if (revision is! int || _unavailable() != null) return;
        if (_schedule.resume(revision)) _publish();
      },
    );
    _broker.subscribeMultiple(
      deviceId: DataBroker.allDevices,
      names: [
        'webServerEmergencyStopped',
        'AllowTransmit',
        'ConnectedRadios',
        'State',
        'Channels',
        'AprsIsEnabled',
        'AprsIsState',
        'CallSign',
        'StationId',
      ],
      callback: (_, name, _) {
        if (name == 'CallSign' || name == 'StationId') {
          _pause('configuration');
          _schedule.revision++;
          _publish();
        } else if (_schedule.armed) {
          final reason = _unavailable();
          if (reason != null) _pause(reason);
        }
      },
    );
    _broker.subscribe(
      deviceId: DataBroker.allDevices,
      name: 'HtStatus',
      callback: (id, _, _) {
        if (id == _config.radioDeviceId) _radioReportAt = _clock();
      },
    );
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      if (_schedule.armed) {
        final reason = _unavailable();
        if (reason != null) {
          _pause(reason);
        } else if (_schedule.due()) {
          _sendBeacon();
        }
      }
      _publish();
    });
    _publish();
  }

  void dispose() {
    if (_disposed) return;
    _pause('disposed');
    _disposed = true;
    _timer?.cancel();
    _broker.dispose();
  }

  void _pause(String reason) {
    if (_disposed) return;
    _schedule.pause(reason);
    _broker.dispatch(
      deviceId: DataBroker.allDevices,
      name: 'CancelSoftwareBeaconFrames',
      data: frameTag,
      store: false,
    );
    _publish();
  }

  void _publish() {
    _broker.dispatch(
      deviceId: 0,
      name: 'SoftwareBeaconStatus',
      data: {
        ..._schedule.snapshot,
        'radioId': _config.radioDeviceId,
        'availability': _unavailable(),
      },
      store: true,
    );
  }

  void _loadConfig(Object? raw) {
    try {
      final data = raw is String ? jsonDecode(raw) : raw;
      _config = data is SoftwareBeaconConfig
          ? data
          : data is Map<String, dynamic>
          ? SoftwareBeaconConfig.fromJson(data)
          : const SoftwareBeaconConfig();
    } catch (_) {
      _config = const SoftwareBeaconConfig();
    }
  }

  String? _unavailable() {
    if (!_config.enabled) return 'disabled';
    if (_config.validationError != null || _sourceAddress() == null) {
      return 'configuration';
    }
    if (_broker.getValue<int>(0, 'webServerEmergencyStopped', 0) == 1) {
      return 'emergency';
    }
    final id = _config.radioDeviceId;
    if (id <= 0) {
      if (_broker.getValue<int>(0, 'AprsIsEnabled', 0) != 1 ||
          _broker.getValue<String>(201, 'AprsIsState', '') !=
              'Connected (verified)') {
        return 'internet';
      }
    } else {
      if (_broker.getValue<int>(0, 'AllowTransmit', 0) != 1) {
        return 'permission';
      }
      final connected = _broker.getValueDynamic(1, 'ConnectedRadios');
      if (connected is! List ||
          !connected.any((r) => r is Map && r['DeviceId'] == id) ||
          _broker.getValue<String>(id, 'State', '') != 'Connected' ||
          _channelId(id) < 0) {
        return 'radio';
      }
    }
    return null;
  }

  AX25Address? _sourceAddress() {
    final callsign = (_broker.getValue<String>(0, 'CallSign', '') ?? '')
        .trim()
        .toUpperCase();
    final station = _broker.getValue<int>(0, 'StationId', 0) ?? 0;
    if (!RegExp(r'^[A-Z0-9]{1,6}$').hasMatch(callsign) ||
        station < 0 ||
        station > 15) {
      return null;
    }
    return AX25Address.parse(station == 0 ? callsign : '$callsign-$station');
  }

  int _channelId(int id) {
    final channels = _broker.getValueDynamic(id, 'Channels');
    if (channels is List) {
      for (final c in channels.whereType<Map>()) {
        if (c['name'] == 'APRS' &&
            c['channelId'] is int &&
            c['channelId'] >= 0 &&
            c['channelId'] <= 255) {
          return c['channelId'];
        }
      }
    }
    return -1;
  }

  void _sendBeacon() {
    if (_disposed || !_schedule.armed || _unavailable() != null) return;
    final id = _config.radioDeviceId;
    final status = _broker.getValueDynamic(id, 'HtStatus');
    if (id > 0 &&
        (_radioReportAt == null ||
            _clock().difference(_radioReportAt!).isNegative ||
            _clock().difference(_radioReportAt!) >
                const Duration(seconds: 15) ||
            status is! Map ||
            status['isInTx'] != false ||
            status['isInRx'] != false ||
            status['rssi'] != 0 ||
            _broker.getValueDynamic(id, 'LockState') != null)) {
      _schedule.skipped++;
      return;
    }
    final info = _information();
    if (info == null) {
      _schedule.skipped++;
      return;
    }
    final now = _clock();
    final packet =
        AX25Packet(
            addresses: [AX25Address.parse('APRS')!, _sourceAddress()!],
            dataStr: info,
            time: now,
            command: true,
          )
          ..incoming = false
          ..sent = false
          ..channelName = 'APRS'
          ..tag = frameTag
          ..deadline = now.add(const Duration(seconds: 15));
    if (id > 0) {
      packet.channelId = _channelId(id);
      _broker.dispatch(
        deviceId: id,
        name: 'TransmitDataFrame',
        data: TransmitDataFrameData(
          packet: packet,
          channelId: packet.channelId,
          regionId: -1,
        ),
        store: false,
      );
      _schedule.requested++;
    } else {
      // The verified manager writes synchronously. No offline/backoff queue,
      // therefore a paused task cannot be replayed after reconnection.
      _broker.dispatch(
        deviceId: 0,
        name: 'SoftwareBeaconInternetAccepted',
        data: false,
        store: true,
      );
      _broker.dispatch(
        deviceId: 0,
        name: 'SoftwareBeaconInternetSend',
        data: packet,
        store: false,
      );
      if (_broker.getValue<bool>(0, 'SoftwareBeaconInternetAccepted', false) !=
          true) {
        _schedule.skipped++;
        return;
      }
      _schedule.requested++;
    }
    _schedule.lastAt = now;
    final aprs = AprsPacket.parse(packet);
    if (aprs != null) {
      _broker.dispatch(
        deviceId: 1,
        name: 'AprsFrame',
        data: AprsFrameEventArgs(aprs, packet, null),
        store: false,
      );
    }
  }

  String? _information() {
    if (!_config.includeLocation) {
      return _config.message.trim().isEmpty
          ? null
          : '>${_config.message.trim()}';
    }
    final raw = _broker.getValueDynamic(1, 'GpsData');
    final gps = raw is GpsData
        ? raw
        : raw is Map<String, dynamic>
        ? GpsData.fromJson(raw)
        : null;
    if (gps == null ||
        !gps.isFixed ||
        !gps.latitude.isFinite ||
        !gps.longitude.isFinite ||
        gps.latitude.abs() > 90 ||
        gps.longitude.abs() > 180) {
      return null;
    }
    final age = _clock().difference(gps.gpsTime);
    if (age.isNegative || age > const Duration(minutes: 2)) return null;
    return '=${AprsUtil.convertLatToNmea(gps.latitude)}${_config.symbolTable}'
        '${AprsUtil.convertLonToNmea(gps.longitude)}${_config.symbolCode}${_config.message.trim()}';
  }
}
