import 'dart:async';

import '../services/android_server_lifecycle.dart';
import '../services/data_broker_client.dart';

/// Holds Android's foreground service while a TCP/MQTT integration is enabled.
/// The Android Activity remains the Flutter engine host; the service only keeps
/// that process eligible to run while the app is backgrounded.
class AndroidNetworkServicesHandler {
  AndroidNetworkServicesHandler()
    : _broker = DataBrokerClient(),
      _lifecycle = AndroidServerLifecycle();

  final DataBrokerClient _broker;
  final AndroidServerLifecycle _lifecycle;
  Future<void> _transition = Future<void>.value();
  bool _active = false;
  bool _disposed = false;

  void init() {
    _broker.subscribeMultiple(
      deviceId: 0,
      names: const ['agwpeServerEnabled', 'homeAssistantEnabled'],
      callback: _onSettingChanged,
    );
    _apply();
  }

  void _onSettingChanged(int deviceId, String name, Object? value) => _apply();

  bool get _shouldRun =>
      (_broker.getValue<int>(0, 'agwpeServerEnabled', 0) ?? 0) == 1 ||
      (_broker.getValue<int>(0, 'homeAssistantEnabled', 0) ?? 0) == 1;

  void _apply() {
    if (_disposed) return;
    final desired = _shouldRun;
    if (desired == _active) return;
    _active = desired;
    _transition = _transition
        .catchError((Object _) {})
        .then((_) async {
          try {
            if (desired) {
              await _lifecycle.start(reason: 'networkServices');
            } else {
              await _lifecycle.stop(reason: 'networkServices');
            }
          } catch (error) {
            _broker.logError(
              'Android network-services background service failed: $error',
            );
          }
        });
  }

  Future<void> dispose() async {
    _disposed = true;
    if (!_active) return;
    _active = false;
    _transition = _transition
        .catchError((Object _) {})
        .then((_) => _lifecycle.stop(reason: 'networkServices'));
    await _transition;
  }
}
