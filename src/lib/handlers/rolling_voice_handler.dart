import 'dart:async';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../services/data_broker.dart';
import '../services/data_broker_client.dart';
import '../services/recording/rolling_voice_recorder.dart';

/// Local-only, opt-in received voice capture for the selected physical radio.
class RollingVoiceHandler {
  RollingVoiceHandler({this.folderProvider});
  final Future<String> Function()? folderProvider;
  final _broker = DataBrokerClient();
  late final RollingVoiceRecorder _recorder = RollingVoiceRecorder(
    onState: _state,
  );
  bool _disposed = false;
  int _revision = 0;
  String? _folder;
  Map<String, Object?> _last = {};
  void init() {
    _broker.subscribeMultiple(
      deviceId: 0,
      names: ['RollingVoiceEnabled', 'RollingVoiceHours'],
      callback: (_, _, _) => unawaited(_apply()),
    );
    _broker.subscribe(
      deviceId: 0,
      name: 'RollingVoicePreserve',
      callback: (_, _, _) => _recorder.preserveLatest(),
    );
    _broker.subscribe(
      deviceId: DataBroker.allDevices,
      name: 'AudioDataAvailable',
      callback: _audio,
    );
    unawaited(_apply());
  }

  int get _hours {
    final h = _broker.getValue<int>(0, 'RollingVoiceHours', 24) ?? 24;
    return h.clamp(1, 168);
  }

  void _state(Map<String, Object?> value) {
    _last = {
      ..._last,
      ...value,
      'starting': value['starting'] == true && value['running'] != true,
    };
    if (!_disposed) {
      _broker.dispatch(
        deviceId: 0,
        name: 'RollingVoiceStatus',
        data: {
          ..._last,
          'enabled':
              _broker.getValue<bool>(0, 'RollingVoiceEnabled', false) == true,
          'retentionHours': _hours,
        },
        store: true,
      );
    }
  }

  Future<void> _apply() async {
    final revision = ++_revision;
    if (_disposed) return;
    if (_broker.getValue<bool>(0, 'RollingVoiceEnabled', false) != true) {
      await _recorder.stop();
      if (revision == _revision) {
        _state({'running': false, 'folder': _folder, 'retentionHours': _hours});
      }
      return;
    }
    if (_recorder.ready) {
      _recorder.setHours(_hours);
      return;
    }
    _state({'running': false, 'starting': true});
    try {
      _folder ??= folderProvider != null
          ? await folderProvider!()
          : '${(await getApplicationSupportDirectory()).path}/rolling-voice';
      if (_disposed || revision != _revision) return;
      await _recorder.start(_folder!, _hours);
    } catch (_) {
      if (revision == _revision) {
        _state({'running': false, 'error': 'storage_open_failed'});
      }
    }
  }

  void _audio(int id, String name, Object? value) {
    if (_disposed ||
        !_recorder.ready ||
        id <= 1 ||
        id >= 200 ||
        value is! Map) {
      return;
    }
    var target = _broker.getValue<int>(1, 'SelectedRadioDeviceId', -1) ?? -1;
    if (target < 2) {
      final radios = _broker.getValueDynamic(1, 'ConnectedRadios');
      if (radios is List) {
        for (final radio in radios.whereType<Map>()) {
          final candidate = radio['DeviceId'] ?? radio['deviceId'];
          if (candidate is int && candidate > 1 && candidate < 200) {
            target = candidate;
            break;
          }
        }
      }
    }
    if (id != target ||
        value['transmit'] == true ||
        value['muted'] == true ||
        value['channelName'] == 'APRS') {
      return;
    }
    final usage = value['usage'];
    if (usage != null && usage != 'Satellite') return;
    final bytes = value['data'],
        offset = value['offset'] ?? 0,
        length = value['length'];
    if (bytes is! Uint8List ||
        offset is! int ||
        length is! int ||
        offset < 0 ||
        length <= 0 ||
        length.isOdd ||
        offset + length > bytes.length) {
      return;
    }
    _recorder.append(
      id,
      '${value['channelName'] ?? ''}',
      Uint8List.sublistView(bytes, offset, offset + length),
    );
  }

  Future<void> close() {
    if (!_disposed) {
      _disposed = true;
      _revision++;
      _broker.dispose();
    }
    return _recorder.stop();
  }

  void dispose() => unawaited(close());
}
