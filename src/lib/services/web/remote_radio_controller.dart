import 'dart:async';
import 'dart:typed_data';
import '../data_broker.dart';
import '../../radio/gaia_protocol.dart';
import 'remote_access_config.dart';

/// The mobile page uses typed controls rather than an unrestricted broker pipe.
class RemoteRadioController {
  RemoteRadioController({required this.target, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final int Function() target;
  final DateTime Function() _clock;
  int? _owner;
  int _txRadio = -1;
  Object? _txChannel;
  Timer? _idleTimer;
  Timer? _maximumTimer;
  DateTime? _rateWindow;
  int _bytesInWindow = 0;
  static const int microphoneFrameMagic = 0xf2;

  bool get _txAllowed =>
      RemoteAccessConfig.current.allowTransmit &&
      DataBroker.getValue<int>(0, 'AllowTransmit', 0) == 1;

  Map<String, Object?> snapshot() {
    final id = target();
    return {
      'radioId': id,
      'connected': id > 0,
      'audio': DataBroker.getValue<bool>(id, 'AudioState', false) ?? false,
      'txAllowed': _txAllowed,
      'txOwner': _owner,
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
    final op = message['op'];
    if (op == 'state') return null;
    if (op == 'pttStop') {
      if (_owner == clientId) release(cancel: false);
      return null;
    }
    final id = target();
    if (id <= 0) return 'Connect the radio on the Windows host first.';
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

  bool microphone(int clientId, Uint8List frame) {
    if (_owner != clientId) return false;
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
    if (_owner == id) release();
  }

  void release({bool cancel = true}) {
    final id = _txRadio;
    _owner = null;
    _txRadio = -1;
    _idleTimer?.cancel();
    _maximumTimer?.cancel();
    if (id > 0) {
      _dispatch(id, 'TransmitVoicePCM', {'hold': false});
      if (cancel) _dispatch(id, 'CancelVoiceTransmit', true);
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
      RadioBasicCommand.setVolume,
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
