import 'dart:async';
import 'dart:typed_data';
import '../data_broker.dart';
import '../../radio/gaia_protocol.dart';
import '../../aprs/aprs_events.dart';
import '../../aprs/remote_position.dart';
import 'remote_access_config.dart';
import '../../utils/map_source.dart';
import 'control_lease.dart';
import 'remote_audit.dart';
import 'aprs_shortcuts.dart';
import 'remote_dashboard.dart';
import 'remote_link_status.dart';

/// The mobile page uses typed controls rather than an unrestricted broker pipe.
class RemoteRadioController {
  RemoteRadioController({
    required this.target,
    DateTime Function()? clock,
    bool Function(int)? clientCanControl,
    this.onControlChanged,
  }) : _clock = clock ?? DateTime.now,
       _clientCanControl = clientCanControl ?? ((_) => false),
       _audit = RemoteAudit(clock: clock),
       _control = ControlLease(clock: clock ?? DateTime.now);
  final int Function() target;
  final bool Function(int) _clientCanControl;
  final void Function()? onControlChanged;
  final ControlLease _control;
  final RemoteAudit _audit;
  List<Map<String, Object>> get auditEvents => _audit.events;
  void audit(
    int clientId,
    String action,
    String result, {
    int? affectedClient,
    int? radioId,
  }) {
    if (!_audit.record(
      clientId: clientId,
      radioId: radioId ?? target(),
      action: action,
      result: result,
      affectedClient: affectedClient,
    )) {
      return;
    }
    DataBroker.dispatch(
      deviceId: 0,
      name: 'RemoteAudit',
      data: auditEvents,
      store: true,
    );
  }

  int? get controlOwner => _control.owner;
  List<int> get controlRequests {
    if (_control.prune()) _publishControl();
    return _control.requests;
  }

  /// Called only by the Windows host or a validated holder handoff.
  void grantControl(int id, {int actor = 0}) {
    if (id <= 0) throw ArgumentError.value(id);
    if (_control.owner == id) return;
    final previous = _control.owner;
    release();
    if (previous != null) _cancelAprs(previous);
    _control.grant(id);
    audit(actor, 'grantControl', 'accepted', affectedClient: id);
    _publishControl();
  }

  void recallControl() {
    final previous = _control.owner;
    final hadRequests = _control.requests.isNotEmpty;
    release();
    if (previous != null) _cancelAprs(previous);
    _control.recall();
    if (previous != null || hadRequests) {
      audit(0, 'recallControl', 'accepted', affectedClient: previous);
    }
    _publishControl();
  }

  void _cancelAprs(int id) => DataBroker.dispatch(
    deviceId: 0,
    name: 'CancelRemoteAprs',
    data: id,
    store: false,
  );

  void _publishControl() {
    DataBroker.dispatch(
      deviceId: 1,
      name: 'RemoteControlOwner',
      data: _control.owner ?? -1,
    );
    onControlChanged?.call();
  }

  final DateTime Function() _clock;
  int? _owner;
  int _txRadio = -1;
  Object? _txChannel;
  Timer? _idleTimer;
  Timer? _maximumTimer;
  DateTime? _rateWindow;
  int _bytesInWindow = 0;
  DateTime? _lastAprsSubmission;
  int _aprsRequestCounter = 0;
  final Map<int, List<double>> _viewports = {};
  final Map<int, DateTime> _radioReports = {};
  void observeRadioReport(int id, Object? status) {
    if (id <= 1 || id == 201) return;
    _radioReports.remove(id);
    if (status is Map &&
        ['isInRx', 'isInTx', 'isScan'].any((key) => status[key] is bool)) {
      _radioReports[id] = _clock().toUtc();
    }
    while (_radioReports.length > 32) {
      _radioReports.remove(_radioReports.keys.first);
    }
  }

  static const int microphoneFrameMagic = 0xf2;

  bool get _txAllowed =>
      DataBroker.getValue<int>(0, 'webServerEmergencyStopped', 0) != 1 &&
      RemoteAccessConfig.current.allowTransmit &&
      DataBroker.getValue<int>(0, 'AllowTransmit', 0) == 1;

  Map<String, Object?> snapshot([int? clientId]) {
    final id = target();
    final bounds = _viewports[clientId];
    final stations =
        (DataBroker.getValueDynamic(1, 'RemoteMapStations', []) as List)
            .whereType<Map>()
            .where((s) {
              final lat = s['lat'], lon = s['lon'];
              if (lat is! num ||
                  lon is! num ||
                  !lat.isFinite ||
                  !lon.isFinite ||
                  lat.abs() > 90 ||
                  lon.abs() > 180) {
                return false;
              }
              final time = s['time'] is String
                  ? DateTime.tryParse(s['time'] as String)
                  : null;
              if (s['time'] != null &&
                  (time == null ||
                      _clock().difference(time) > const Duration(hours: 24) ||
                      time.isAfter(_clock().add(const Duration(minutes: 5))))) {
                return false;
              }
              if (bounds == null) return true;
              return lat >= bounds[0] &&
                  lat <= bounds[2] &&
                  (bounds[1] <= bounds[3]
                      ? lon >= bounds[1] && lon <= bounds[3]
                      : lon >= bounds[1] || lon <= bounds[3]);
            })
            .take(256)
            .toList();
    return {
      'linkDiagnostics': RemoteLinkStatus.snapshot(id),
      'dashboard': RemoteDashboard.build(
        radioId: id,
        now: _clock(),
        radioReportAt: _radioReports[id],
        audit: auditEvents,
      ),
      'controlOwner': _control.owner,
      'auditEvents': auditEvents.reversed.take(20).toList(),
      'aprsShortcuts': AprsShortcuts.current.toJson(),
      'controlRequests': controlRequests,
      'controlRequested': _control.requests.contains(clientId),
      'controlApprovalRequired':
          RemoteAccessConfig.current.requireControlApproval,
      'emergencyStopped':
          DataBroker.getValue<int>(0, 'webServerEmergencyStopped', 0) == 1,
      'mapStations': stations,
      'mapSources':
          {
                ...{for (final s in MapSource.builtIn) s.id: s},
                MapSource.current.id: MapSource.current,
              }.values
              .map(
                (s) => {
                  'id': s.id,
                  'name': s.name,
                  'url':
                      '/remote-tiles/${s.id}/{z}/{x}/{y}.png?v=${s.cacheNamespace}',
                  'attribution': s.attribution,
                },
              )
              .toList(),
      'mapSource': MapSource.current.id,
      'radioId': id,
      'connected': id > 0,
      'audio': DataBroker.getValue<bool>(id, 'AudioState', false) ?? false,
      'txAllowed': _txAllowed,
      'aprsAllowed':
          RemoteAccessConfig.current.allowAprs &&
          DataBroker.getValue<int>(0, 'AllowTransmit', 0) == 1,
      'positionAllowed':
          RemoteAccessConfig.current.allowPosition &&
          DataBroker.getValue<int>(0, 'AllowTransmit', 0) == 1,
      'txOwner': _owner,
      'radioPosition': DataBroker.getValueDynamic(id, 'Position', null),
      'positionStatus': DataBroker.getValueDynamic(
        1,
        'RemotePositionStatus',
        null,
      ),
      'gatewayMetrics': DataBroker.getValueDynamic(201, 'GateMetrics', {}),
      'gatewayHealth': DataBroker.getValueDynamic(201, 'GateHealth', []),
      'aprsMessages': DataBroker.getValueDynamic(1, 'RemoteAprsMessages', []),
      'aprsDeliveries': DataBroker.getValueDynamic(
        1,
        'RemoteAprsDeliveries',
        [],
      ),
      'settings': DataBroker.getValueDynamic(id, 'Settings', null),
      'status': DataBroker.getValueDynamic(id, 'HtStatus', null),
      'volume': DataBroker.getValue<int>(id, 'Volume', 0),
      'channels': _channels(id)
          .map(
            (c) => {
              'channelId': c['channelId'],
              'name': c['name'],
              'rxFreq': c['rxFreq'],
            },
          )
          .toList(),
    };
  }

  List<Map> _channels(int id) =>
      (DataBroker.getValueDynamic(id, 'Channels', null) as List? ?? [])
          .whereType<Map>()
          .toList();

  String? command(int clientId, Map message) {
    final result = _command(clientId, message);
    final op = message['op'];
    if (op != 'state') {
      audit(
        clientId,
        RemoteAudit.actions.contains(op) ? op as String : 'invalidCommand',
        result == null ? 'accepted' : 'denied',
      );
    }
    return result;
  }

  String? _command(int clientId, Map message) {
    final op = message['op'];
    if (op == 'state') {
      final bounds = message['mapBounds'];
      if (bounds is List &&
          bounds.length == 4 &&
          bounds.every((e) => e is num && e.isFinite)) {
        final values = bounds.map((e) => (e as num).toDouble()).toList();
        if (values[0] >= -90 &&
            values[2] <= 90 &&
            values[0] <= values[2] &&
            values[1].abs() <= 180 &&
            values[3].abs() <= 180) {
          if (_viewports.length < 8 || _viewports.containsKey(clientId)) {
            _viewports[clientId] = values;
          }
        }
      }
      return null;
    }
    if (op == 'pttStop') {
      if (_owner == clientId) release(cancel: false);
      return null;
    }
    if (op == 'releaseControl') {
      disconnected(clientId);
      return null;
    }
    if (DataBroker.getValue<int>(0, 'webServerEmergencyStopped', 0) == 1) {
      return 'Remote control is stopped on the Windows host.';
    }
    if (op == 'requestControl') {
      if (!_control.request(clientId)) return 'Control request queue is full.';
      _publishControl();
      return null;
    }
    if (_control.owner != clientId) {
      return 'Request exclusive control before operating the radio.';
    }
    if (op == 'handoffControl') {
      final next = message['clientId'];
      if (RemoteAccessConfig.current.requireControlApproval) {
        return 'The Windows host must approve control handoff.';
      }
      if (next is! int ||
          !controlRequests.contains(next) ||
          !_clientCanControl(next)) {
        return 'Select a waiting client with control permission.';
      }
      grantControl(next, actor: clientId);
      return null;
    }
    final id = target();
    if (id <= 0) return 'Connect the radio on the Windows host first.';
    if (op == 'aprsMessage') return _sendAprs(id, message, clientId);
    if (op == 'aprsPosition') return _sendPosition(id, clientId, message);
    if (op == 'pttStart') {
      if (!_txAllowed) {
        return 'Enable remote TX and Allow transmit on the host.';
      }
      if (_owner != null) return 'A remote transmitter already owns PTT.';
      if (DataBroker.getValue<bool>(id, 'AudioState', false) != true) {
        return 'Enable the radio audio channel on Windows first.';
      }
      final status = DataBroker.getValueDynamic(id, 'HtStatus', null);
      final lock = DataBroker.getValueDynamic(id, 'LockState', null);
      if (status is! Map ||
          status['isPowerOn'] != true ||
          status['isInTx'] == true ||
          (lock is Map && lock['isLocked'] == true)) {
        return 'Radio is busy or its status is not ready.';
      }
      final settings = DataBroker.getValueDynamic(id, 'Settings', null);
      if (settings is! Map) return 'Radio settings are not ready.';
      if (settings['doubleChannel'] == 2 || settings['doubleChannel'] == 3) {
        return 'Select a channel in VFO A on the mobile page before PTT.';
      }
      final vfo = settings['doubleChannel'] == 2 ? 'channelB' : 'channelA';
      final channel = _channels(
        id,
      ).where((c) => c['channelId'] == settings[vfo]);
      if (channel.isEmpty || channel.first['txDisable'] != false) {
        return 'Selected channel does not allow transmission.';
      }
      _owner = clientId;
      DataBroker.dispatch(deviceId: 1, name: 'RemotePttOwner', data: clientId);
      _txRadio = id;
      _txChannel = settings['channelA'];
      _rateWindow = _clock();
      _bytesInWindow = 0;
      _maximumTimer = Timer(const Duration(seconds: 60), () => release());
      _resetIdle();
      return null;
    }
    if (_owner != null) return 'Release PTT before changing radio controls.';
    switch (op) {
      case 'channel':
        final channel = message['value'];
        if (channel is! int ||
            !_channels(id).any((c) => c['channelId'] == channel)) {
          return 'Unknown channel.';
        }
        _dispatch(
          id,
          message['vfo'] == 'B' ? 'ChannelChangeVfoB' : 'ChannelChangeVfoA',
          channel,
        );
        return null;
      case 'volume':
        final value = message['value'];
        if (value is! int || value < 0 || value > 15) {
          return 'Volume must be 0–15.';
        }
        _dispatch(id, 'SetVolumeLevel', value);
        return null;
      case 'scan':
        if (message['value'] is! bool) return 'Invalid scan value.';
        _dispatch(id, 'Scan', message['value']);
        return null;
      default:
        return 'Unsupported remote command.';
    }
  }

  String? _sendAprs(int id, Map message, int clientId) {
    if (!RemoteAccessConfig.current.allowAprs ||
        DataBroker.getValue<int>(0, 'AllowTransmit', 0) != 1) {
      return 'Enable remote APRS messages and Allow transmit on Windows.';
    }
    final destination = message['destination'];
    final text = message['text'];
    if (destination is! String ||
        !RegExp(
          r'^[A-Z0-9]{1,6}(?:-(?:[0-9]|1[0-5]))?$',
        ).hasMatch(destination) ||
        destination.length > 9) {
      return 'Invalid destination callsign/SSID.';
    }
    if (text is! String ||
        text.trim().isEmpty ||
        text.length > 67 ||
        !RegExp(r'^[\x20-\x7e]+$').hasMatch(text) ||
        text.contains('{') ||
        text.contains('|') ||
        text.contains('~')) {
      return 'APRS text must be 1–67 printable ASCII characters without { | ~.';
    }
    if ((DataBroker.getValue<String>(0, 'CallSign', '') ?? '').isEmpty) {
      return 'Configure the station callsign on Windows.';
    }
    final status = DataBroker.getValueDynamic(id, 'HtStatus', null);
    final lock = DataBroker.getValueDynamic(id, 'LockState', null);
    if (_owner != null ||
        status is! Map ||
        status['isPowerOn'] != true ||
        status['isInTx'] == true ||
        (lock is Map && lock['isLocked'] == true)) {
      return 'Radio is busy or not ready for APRS.';
    }
    final aprs = _channels(id).where((c) => c['name'] == 'APRS');
    if (aprs.isEmpty || aprs.first['txDisable'] != false) {
      return 'Configure a transmit-enabled APRS channel on Windows.';
    }
    final now = _clock();
    if (_lastAprsSubmission != null &&
        now.difference(_lastAprsSubmission!) < const Duration(seconds: 10)) {
      return 'Wait 10 seconds between APRS submissions.';
    }
    _lastAprsSubmission = now;
    _dispatch(
      1,
      'SendAprsMessage',
      AprsSendMessageData(
        destination: destination,
        message: text,
        radioDeviceId: id,
        remoteClientId: clientId,
        remoteRequestId:
            '${now.microsecondsSinceEpoch}-${++_aprsRequestCounter}',
      ),
    );
    return null;
  }

  String? _sendPosition(int id, int clientId, Map message) {
    if (!RemoteAccessConfig.current.allowPosition ||
        DataBroker.getValue<int>(0, 'AllowTransmit', 0) != 1) {
      return 'Enable remote position packets and Allow transmit on Windows.';
    }
    if (message['confirmed'] != true) {
      return 'Confirm position transmission first.';
    }
    final radio = message['source'] == 'radio';
    if (!radio && message['source'] != 'phone') {
      return 'Invalid position source.';
    }
    final value = radio
        ? DataBroker.getValueDynamic(id, 'Position', null)
        : message['position'];
    if (radio) {
      final preview = message['position'];
      if (preview is! Map ||
          value is! Map ||
          preview['latitude'] != value['latitude'] ||
          preview['longitude'] != value['longitude'] ||
          preview['capturedAt'] != value['receivedTime']) {
        return 'Radio position changed; preview it again before confirming.';
      }
    }
    final fix = value is Map
        ? RemotePositionFix.parse(value, _clock(), radio: radio)
        : null;
    if (fix == null) {
      return 'Position must be fresh (2 minutes), fixed, and accurate within 100 m.';
    }
    final status = DataBroker.getValueDynamic(id, 'HtStatus', null);
    final lock = DataBroker.getValueDynamic(id, 'LockState', null);
    final aprs = _channels(id).where((c) => c['name'] == 'APRS');
    if (_owner != null ||
        status is! Map ||
        status['isPowerOn'] != true ||
        status['isInTx'] == true ||
        (lock is Map && lock['isLocked'] == true) ||
        aprs.isEmpty ||
        aprs.first['txDisable'] != false ||
        (DataBroker.getValue<String>(0, 'CallSign', '') ?? '').isEmpty) {
      return 'Configure callsign and a transmit-enabled APRS channel; radio must be idle.';
    }
    final now = _clock();
    if (_lastAprsSubmission != null &&
        now.difference(_lastAprsSubmission!) < const Duration(seconds: 10)) {
      return 'Wait 10 seconds between APRS submissions.';
    }
    _lastAprsSubmission = now;
    _dispatch(
      1,
      'SendRemoteAprsPosition',
      RemotePositionRequest(id, clientId, fix),
    );
    return null;
  }

  bool microphone(int clientId, Uint8List frame) {
    if (_owner != clientId || _control.owner != clientId) return false;
    final settings = DataBroker.getValueDynamic(_txRadio, 'Settings', null);
    final lock = DataBroker.getValueDynamic(_txRadio, 'LockState', null);
    if (!_txAllowed ||
        target() != _txRadio ||
        DataBroker.getValue<bool>(_txRadio, 'AudioState', false) != true ||
        settings is! Map ||
        settings['channelA'] != _txChannel ||
        settings['doubleChannel'] == 2 ||
        settings['doubleChannel'] == 3 ||
        (lock is Map && lock['isLocked'] == true) ||
        frame.length < 6 ||
        frame.length > 8196 ||
        (frame.length - 4).isOdd ||
        frame[0] != microphoneFrameMagic ||
        frame[1] != 1 ||
        frame[2] != 0 ||
        frame[3] != 125) {
      release();
      return false;
    }
    final now = _clock();
    if (now.difference(_rateWindow!) >= const Duration(seconds: 1)) {
      _rateWindow = now;
      _bytesInWindow = 0;
    }
    _bytesInWindow += frame.length - 4;
    if (_bytesInWindow > 96000) {
      release();
      return false;
    }
    _resetIdle();
    _dispatch(_txRadio, 'TransmitVoicePCM', {
      'data': Uint8List.fromList(frame.sublist(4)),
      'playLocally': false,
      'hold': true,
    });
    return true;
  }

  void _resetIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 1500), () => release());
  }

  void disconnected(int id) {
    _viewports.remove(id);
    if (_owner == id) release();
    final previous = _control.owner;
    _control.remove(id);
    if (previous == id) _cancelAprs(id);
    _publishControl();
  }

  void release({bool cancel = true}) {
    final id = _txRadio;
    final clientId = _owner;
    _owner = null;
    DataBroker.dispatch(deviceId: 1, name: 'RemotePttOwner', data: -1);
    _txRadio = -1;
    _idleTimer?.cancel();
    _maximumTimer?.cancel();
    if (id > 0) {
      _dispatch(id, 'TransmitVoicePCM', {'hold': false});
      if (cancel) _dispatch(id, 'CancelVoiceTransmit', true);
      if (clientId != null) {
        audit(clientId, 'pttRelease', 'released', radioId: id);
      }
    }
  }

  void _dispatch(int id, String name, Object? value) =>
      DataBroker.dispatch(deviceId: id, name: name, data: value, store: false);

  /// Hosted Flutter clients may inspect the radio; firmware writes and raw TX
  /// are excluded. TX is only available through the bounded mobile PTT stream.
  static bool safeRawCommand(Uint8List frame) {
    if (frame.length < 4 || frame[0] != 0 || frame[1] != 2 || frame[2] != 0) {
      return false;
    }
    final command = RadioBasicCommand.fromValue(frame[3]);
    return {
      RadioBasicCommand.getDevId,
      RadioBasicCommand.getDevInfo,
      RadioBasicCommand.readStatus,
      RadioBasicCommand.registerNotification,
      RadioBasicCommand.cancelNotification,
      RadioBasicCommand.getNotification,
      RadioBasicCommand.readSettings,
      RadioBasicCommand.readRfCh,
      RadioBasicCommand.getInScan,
      RadioBasicCommand.getHtStatus,
      RadioBasicCommand.getVolume,
      RadioBasicCommand.radioGetStatus,
      RadioBasicCommand.readAdvancedSettings,
      RadioBasicCommand.readBssSettings,
      RadioBasicCommand.freqModeGetStatus,
      RadioBasicCommand.readFreqRange,
      RadioBasicCommand.getIba,
      RadioBasicCommand.getVoc,
      RadioBasicCommand.readRfStatus,
      RadioBasicCommand.getDid,
      RadioBasicCommand.getPf,
      RadioBasicCommand.getMsg,
      RadioBasicCommand.getPpId,
      RadioBasicCommand.readAdvancedSettings2,
      RadioBasicCommand.getAprsPath,
      RadioBasicCommand.readRegionName,
      RadioBasicCommand.getPfActions,
      RadioBasicCommand.getPosition,
    }.contains(command);
  }
}
