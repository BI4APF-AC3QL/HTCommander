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
    this.retryDelay = const Duration(seconds: 2),
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _positions = positions ?? AndroidCurrentLocation.watchPosition,
       _broker = DataBrokerClient(),
       _lifecycle = AndroidServerLifecycle(),
       _retryDelay = retryDelay {
    assert(
      retryDelay > Duration.zero && retryDelay <= const Duration(minutes: 1),
    );
  }

  static const _enabledKey = 'PhoneGpsTrackingEnabled';
  final bool _isAndroid;
  final Stream<AndroidCoordinates> Function() _positions;
  final Future<void> Function()? startService;
  final Future<void> Function()? stopService;
  final Duration retryDelay;
  final DataBrokerClient _broker;
  final AndroidServerLifecycle _lifecycle;
  StreamSubscription<AndroidCoordinates>? _subscription;
  Future<void> _transition = Future<void>.value();
  Timer? _retryTimer;
  Duration _retryDelay;
  bool _active = false;
  bool _serviceRequested = false;
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
    _retryTimer?.cancel();
    _retryTimer = null;
    _transition = _transition.catchError((Object _) {}).then((_) async {
      if (_disposed) return;
      if (_enabled) {
        await _startTracking();
      } else {
        await _stopTracking();
      }
    });
  }

  Future<void> _startTracking() async {
    if (_active) return;
    try {
      if (!_serviceRequested) {
        // Record the request before awaiting the platform call. If the channel
        // reports an error after Android accepted the start command, the error
        // path still attempts to release the native service.
        _serviceRequested = true;
        await (startService?.call() ?? _lifecycle.start(reason: 'location'));
      }
      if (_disposed || !_enabled) {
        await _stopLocationService();
        return;
      }
      _subscription = _positions().listen(
        _onPosition,
        onError: _onStreamError,
        onDone: _onStreamDone,
        cancelOnError: true,
      );
      _active = true;
      _retryDelay = retryDelay;
    } on Object catch (error) {
      _broker.logError('Android phone GPS could not start: $error');
      _broker.dispatch(deviceId: 0, name: _enabledKey, data: 0);
      await _stopLocationService();
    }
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
    try {
      await _subscription?.cancel();
    } on Object catch (error) {
      _broker.logError('Android phone GPS stream could not stop: $error');
    }
    _subscription = null;
    _active = false;
    await _stopLocationService();
  }

  Future<void> _stopLocationService() async {
    if (!_serviceRequested) return;
    try {
      await (stopService?.call() ?? _lifecycle.stop(reason: 'location'));
      _serviceRequested = false;
      _retryDelay = retryDelay;
    } on Object catch (error) {
      _broker.logError('Android phone GPS service could not stop: $error');
      _scheduleStopRetry();
    }
  }

  void _scheduleStopRetry() {
    if (_disposed || _retryTimer != null || !_serviceRequested) return;
    final delay = _retryDelay;
    _retryDelay = Duration(
      milliseconds: (_retryDelay.inMilliseconds * 2)
          .clamp(
            retryDelay.inMilliseconds,
            const Duration(minutes: 1).inMilliseconds,
          )
          .toInt(),
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _apply();
    });
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _broker.dispose();
    _transition = _transition.catchError((Object _) {}).then((_) async {
      await _stopTracking();
    });
    await _transition;
  }
}
