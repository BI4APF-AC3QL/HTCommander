import 'dart:async';

import '../services/android_server_lifecycle.dart';
import '../services/data_broker_client.dart';

/// Holds Android's foreground service while a radio or TCP/MQTT service is active.
/// The Android Activity remains the Flutter engine host; the service keeps that
/// process eligible to run while the app is backgrounded.
class AndroidNetworkServicesHandler {
  AndroidNetworkServicesHandler({this._startService, this._stopService})
    : _broker = DataBrokerClient(),
      _lifecycle = AndroidServerLifecycle();

  final DataBrokerClient _broker;
  final AndroidServerLifecycle _lifecycle;
  final Future<void> Function()? _startService;
  final Future<void> Function()? _stopService;
  Future<void> _transition = Future<void>.value();
  bool _active = false;
  bool _disposed = false;
  Timer? _retryTimer;
  var _retryDelay = const Duration(seconds: 2);

  void init() {
    _broker.subscribeMultiple(
      deviceId: 0,
      names: const ['agwpeServerEnabled', 'homeAssistantEnabled'],
      callback: _onSettingChanged,
    );
    _broker.subscribe(
      deviceId: 1,
      name: 'ConnectedRadios',
      callback: _onSettingChanged,
    );
    _apply();
  }

  void _onSettingChanged(int deviceId, String name, Object? value) => _apply();

  bool get _shouldRun =>
      (_broker.getValue<int>(0, 'agwpeServerEnabled', 0) ?? 0) == 1 ||
      (_broker.getValue<int>(0, 'homeAssistantEnabled', 0) ?? 0) == 1 ||
      _hasConnectedRadio;

  bool get _hasConnectedRadio {
    final radios = _broker.getValueDynamic(1, 'ConnectedRadios');
    return radios is List && radios.isNotEmpty;
  }

  void _apply() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _transition = _transition.catchError((Object _) {}).then((_) async {
      if (_disposed) return;
      final desired = _shouldRun;
      if (desired == _active) return;
      try {
        if (desired) {
          await (_startService?.call() ??
              _lifecycle.start(reason: 'networkServices'));
        } else {
          await (_stopService?.call() ??
              _lifecycle.stop(reason: 'networkServices'));
        }
        _active = desired;
        _retryDelay = const Duration(seconds: 2);
      } catch (error) {
        _broker.logError(
          'Android network-services background service failed: $error',
        );
        _scheduleRetry();
      }
    });
  }

  void _scheduleRetry() {
    if (_disposed || _retryTimer != null) return;
    final delay = _retryDelay;
    _retryDelay = Duration(
      seconds: (_retryDelay.inSeconds * 2).clamp(2, 60).toInt(),
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _apply();
    });
  }

  Future<void> dispose() async {
    if (_disposed) return _transition;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _broker.dispose();
    _transition = _transition.catchError((Object _) {}).then((_) async {
      if (!_active) return;
      try {
        await (_stopService?.call() ??
            _lifecycle.stop(reason: 'networkServices'));
        _active = false;
      } catch (error) {
        _broker.logError(
          'Android network-services background service failed to stop: $error',
        );
      }
    });
    await _transition;
  }
}
