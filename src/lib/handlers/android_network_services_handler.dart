import 'dart:async';

import '../allstar/allstar_client.dart' show allStarDeviceId;
import '../allstar/allstar_node.dart' show allStarNodeDeviceId;
import '../echolink/echolink_client.dart' show echoLinkDeviceId;
import '../services/android_server_lifecycle.dart';
import '../services/data_broker_client.dart';

/// Holds Android's foreground service while a radio or network session is active.
/// The application-owned Flutter engine keeps the Dart radio and network handlers
/// alive; this service keeps the process eligible to run in the background.
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
  bool _allStarNodeActive = false;
  bool _winlinkBusy = false;
  bool _disposed = false;
  Timer? _retryTimer;
  var _retryDelay = const Duration(seconds: 2);

  void init() {
    _broker.subscribeMultiple(
      deviceId: 0,
      names: const [
        'agwpeServerEnabled',
        'homeAssistantEnabled',
        'homeAssistantMqttUrl',
        'AprsIsEnabled',
      ],
      callback: _onSettingChanged,
    );
    _broker.subscribe(
      deviceId: 1,
      name: 'ConnectedRadios',
      callback: _onSettingChanged,
    );
    _broker.subscribe(
      deviceId: 1,
      name: 'WinlinkBusy',
      callback: _onWinlinkBusyChanged,
    );
    for (final deviceId in const [echoLinkDeviceId, allStarDeviceId]) {
      _broker.subscribe(
        deviceId: deviceId,
        name: 'State',
        callback: _onSettingChanged,
      );
    }
    _broker.subscribe(
      deviceId: allStarNodeDeviceId,
      name: 'State',
      callback: _onAllStarNodeStateChanged,
    );
    _apply();
  }

  void _onSettingChanged(int deviceId, String name, Object? value) => _apply();

  void _onWinlinkBusyChanged(int deviceId, String name, Object? value) {
    _winlinkBusy = value == true;
    _apply();
  }

  void _onAllStarNodeStateChanged(int deviceId, String name, Object? value) {
    _allStarNodeActive = value == 'Starting' || value == 'Hosting';
    _apply();
  }

  bool get _shouldRun =>
      (_broker.getValue<int>(0, 'agwpeServerEnabled', 0) ?? 0) == 1 ||
      ((_broker.getValue<int>(0, 'homeAssistantEnabled', 0) ?? 0) == 1 &&
          (_broker.getValue<String>(0, 'homeAssistantMqttUrl', '') ?? '')
              .trim()
              .isNotEmpty) ||
      // APRS-IS is a persistent TCP session even when no physical radio is
      // connected. Keep the process alive while it is enabled so reconnect,
      // inbox and internet-only beacon work continue when Android backgrounds
      // the app.
      (_broker.getValue<int>(0, 'AprsIsEnabled', 0) ?? 0) == 1 ||
      // EchoLink and AllStarLink can operate as internet-only radios and are
      // intentionally absent from ConnectedRadios.
      _hasActiveInternetRadio ||
      // Hosted AllStar node state is event-only; keep the session we observed
      // during this process alive even if its attached radio disconnects.
      _allStarNodeActive ||
      // Winlink TCP retries are transient but must survive Android background
      // scheduling until the retry succeeds, is cancelled, or is exhausted.
      _winlinkBusy ||
      _hasConnectedRadio;

  bool get _hasActiveInternetRadio =>
      _isInternetRadioActive(echoLinkDeviceId) ||
      _isInternetRadioActive(allStarDeviceId);

  bool _isInternetRadioActive(int deviceId) {
    final state = _broker.getValueDynamic(deviceId, 'State');
    return state == 'Online' || state == 'Connecting' || state == 'Connected';
  }

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
