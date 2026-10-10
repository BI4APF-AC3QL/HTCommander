import '../../radio/radio.dart' show SetLockData, SetUnlockData;
import '../../radio/radio_models.dart' show kSatelliteLockUsage;
import '../data_broker.dart';

/// Owns only tracking started by this remote controller; local tracking wins.
class RemoteSatelliteControl {
  int? _owner, _radio;
  Map? get _marker =>
      DataBroker.getValueDynamic(0, 'SatelliteTrackingMarker') is Map
      ? DataBroker.getValueDynamic(0, 'SatelliteTrackingMarker') as Map
      : null;
  Map<String, Object?> snapshot(DateTime now) {
    final value = DataBroker.getValueDynamic(0, 'SatelliteRemoteState');
    if (value is! Map) {
      return {
        'enabled': false,
        'observerKnown': false,
        'catalog': [],
        'positions': [],
        'tracking': _marker,
      };
    }
    final positions =
        (value['positions'] is List ? value['positions'] as List : [])
            .whereType<Map>()
            .take(128)
            .map((p) {
              final time = DateTime.tryParse('${p['utc']}');
              return {
                ...p,
                'fresh':
                    time != null &&
                    now.difference(time).inMilliseconds >= -5000 &&
                    now.difference(time).inMilliseconds <= 5000,
              };
            })
            .toList();
    return {
      ...Map<String, Object?>.from(value),
      'positions': positions,
      'tracking': _marker,
    };
  }

  String? start(int clientId, int radioId, Map command, DateTime now) {
    final state = snapshot(now),
        id = command['noradId'],
        index = command['usageIndex'];
    if (state['enabled'] != true || state['observerKnown'] != true) {
      return 'Enable satellite support and configure observer location on Windows.';
    }
    if (id is! int || index is! int || index < 0) {
      return 'Invalid satellite selection.';
    }
    final catalog = (state['catalog'] as List).whereType<Map>().where(
      (s) => s['id'] == id,
    );
    if (catalog.isEmpty) return 'Unknown satellite.';
    final usages = (catalog.first['usages'] as List).whereType<Map>().where(
      (u) => u['index'] == index,
    );
    if (usages.isEmpty) return 'Unknown satellite mode.';
    final pos = (state['positions'] as List).whereType<Map>().where(
      (p) => p['id'] == id && p['fresh'] == true,
    );
    if (pos.isEmpty) {
      return 'Satellite position is stale; wait for a fresh orbit update.';
    }
    final status = DataBroker.getValueDynamic(radioId, 'HtStatus'),
        lock = DataBroker.getValueDynamic(radioId, 'LockState');
    if (status is! Map ||
        status['isPowerOn'] != true ||
        status['isInTx'] == true ||
        status['isScan'] == true) {
      return 'Stop scanning and wait until the radio is idle.';
    }
    if (_marker != null && _marker?['remoteClientId'] != clientId) {
      return 'Radio is occupied by another local task.';
    }
    if (lock is Map &&
        lock['isLocked'] == true &&
        !(_marker?['remoteClientId'] == clientId &&
            _marker?['radioDeviceId'] == radioId)) {
      return 'Radio is occupied by another local task.';
    }
    stop();
    _owner = clientId;
    _radio = radioId;
    final marker = {
      'noradId': id,
      'usageIndex': index,
      'radioDeviceId': radioId,
      'remoteClientId': clientId,
      'name': catalog.first['name'],
      'receiveOnly': true,
    };
    DataBroker.dispatch(
      deviceId: radioId,
      name: 'SetLock',
      data: SetLockData(usage: kSatelliteLockUsage),
      store: false,
    );
    DataBroker.dispatch(
      deviceId: 0,
      name: 'SatelliteTrackingMarker',
      data: marker,
      store: true,
    );
    DataBroker.dispatch(
      deviceId: 0,
      name: 'SatelliteTrackTarget',
      data: {...marker, 'receiveOnly': true},
      store: false,
    );
    return null;
  }

  void stop([int? clientId]) {
    if (_owner == null || clientId != null && _owner != clientId) return;
    final owner = _owner, radio = _radio;
    _owner = _radio = null;
    if (_marker?['remoteClientId'] != owner ||
        _marker?['radioDeviceId'] != radio) {
      return;
    }
    DataBroker.dispatch(
      deviceId: 0,
      name: 'SatelliteTrackTarget',
      data: null,
      store: false,
    );
    DataBroker.dispatch(
      deviceId: 0,
      name: 'SatelliteTrackingMarker',
      data: null,
      store: true,
    );
    if (radio != null) {
      DataBroker.dispatch(
        deviceId: radio,
        name: 'SetUnlock',
        data: SetUnlockData(usage: kSatelliteLockUsage),
        store: false,
      );
    }
  }
}
