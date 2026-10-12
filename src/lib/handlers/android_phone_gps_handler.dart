import 'dart:async';
import 'dart:io' show Platform;

import '../services/android_current_location.dart';
import '../services/android_server_lifecycle.dart';
import '../services/data_broker_client.dart';

/// Feeds explicitly enabled Android phone GPS fixes into the same location
/// settings consumed by the radio, APRS-IS range filter and satellite tracker.
class AndroidPhoneGpsHandler {
  AndroidPhoneGpsHandler({
    bool? isAndroid,
    Stream<AndroidCoordinates> Function()? positions,
    this.startService,
    this.stopService,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _positions = positions ?? AndroidCurrentLocation.watchPosition,
       _broker = DataBrokerClient(),
       _lifecycle = AndroidServerLifecycle();

  static const _enabledKey = 'PhoneGpsTrackingEnabled';
  final bool _isAndroid;
  final Stream<AndroidCoordinates> Function() _positions;
  final Future<void> Function()? startService;
  final Future<void> Function()? stopService;
  final DataBrokerClient _broker;
  final AndroidServerLifecycle _lifecycle;
  StreamSubscription<AndroidCoordinates>? _subscription;
  Future<void> _transition = Future<void>.value();
  bool _active = false;
  bool _disposed = false;

  void init() {
    _broker.subscribe(
      deviceId: 0,
      name: _enabledKey,
      callback: (_, _, _) => _apply(),
    );
    _apply();
  }

  bool get _enabled =>
      (_broker.getValue<int>(0, _enabledKey, 0) ?? 0) == 1;

  void _apply() {
    if (_disposed || !_isAndroid) return;
    _transition = _transition.catchError((Object _) {}).then((_) async {
      if (_disposed) return;
      final desired = _enabled;
      if (desired == _active) return;
      if (desired) {
        try {
          await (startService?.call() ?? _lifecycle.start(reason: 'location'));
          if (_disposed || !_enabled) {
            await (stopService?.call() ?? _lifecycle.stop(reason: 'location'));
            return;
          }
          _subscription = _positions().listen(
            _onPosition,
            onError: _onStreamError,
            onDone: _onStreamDone,
            cancelOnError: true,
          );
          _active = true;
        } on Object catch (error) {
          _broker.logError('Android phone GPS could not start: $error');
          _broker.dispatch(
            deviceId: 0,
            name: _enabledKey,
            data: 0,
          );
          try {
            await (stopService?.call() ??
                _lifecycle.stop(reason: 'location'));
          } on Object {
            // Keep the original startup failure for the application log.
          }
        }
      } else {
        await _stopTracking();
      }
    });
  }

  void _onPosition(AndroidCoordinates position) {
    if (!_active && _subscription == null) return;
    _broker.dispatch(
      deviceId: 0,
      name: 'ManualLocationEnabled',
      data: 1,
    );
    _broker.dispatch(
      deviceId: 0,
      name: 'ManualLatitude',
      data: position.latitude,
    );
    _broker.dispatch(
      deviceId: 0,
      name: 'ManualLongitude',
      data: position.longitude,
    );
  }

  void _onStreamError(Object error, StackTrace stack) {
    _broker.logError('Android phone GPS update stopped: $error');
    _broker.dispatch(
      deviceId: 0,
      name: _enabledKey,
      data: 0,
    );
  }

  void _onStreamDone() {
    if (_active) {
      _onStreamError(StateError('location stream ended'), StackTrace.current);
    }
  }

  Future<void> _stopTracking() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_active) return;
    _active = false;
    await (stopService?.call() ?? _lifecycle.stop(reason: 'location'));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _broker.dispose();
    _transition = _transition.catchError((Object _) {}).then((_) async {
      await _stopTracking();
    });
    await _transition;
  }
}
