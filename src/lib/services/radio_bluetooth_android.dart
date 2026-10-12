part of 'bluetooth_service.dart';

Future<bool> _checkBluetoothAndroid() async {
  if (!await _ensureAndroidBluetoothPermissions()) return false;
  return _checkBluetoothBleAdapter();
}

Future<bool> _isBluetoothOnAndroid() async {
  return _isBluetoothOnBleAdapter();
}

Future<List<DiscoveredDevice>> _findCompatibleDevicesAndroid(
  BluetoothService service, {
  required Duration timeout,
}) async {
  // Android 12+ (API 31+) requires BLUETOOTH_CONNECT before paired Classic
  // devices can be enumerated. Scan permission is optional because discovery
  // cancellation is only a connection-speed optimization.
  if (!await _ensureAndroidBluetoothPermissions()) {
    service._broker.logError(
      '[Android] Bluetooth Connect permission was not granted',
    );
    return const [];
  }

  // Android uses Bluetooth Classic (RFCOMM/SPP) for the radio control channel.
  // Compatible radios must be paired (bonded) in the Android Bluetooth settings;
  // they are enumerated from the bonded device list by the native plugin.
  return _findCompatibleDevicesClassic(service);
}

/// Requests the runtime Bluetooth Connect permission needed to enumerate and
/// connect to paired Classic devices on Android 12+, waiting for the user's
/// response. Bluetooth Scan is not required for bonded-device enumeration.
///
/// A missing permission plugin or a denied request is reported as unavailable;
/// callers can then show their normal Bluetooth-unavailable guidance.
Future<bool> _ensureAndroidBluetoothPermissions() =>
    AndroidBluetoothPermissions.ensureConnect(
      status: () => Permission.bluetoothConnect.status,
      request: () => Permission.bluetoothConnect.request(),
    );

Future<int?> _connectToRadioAndroid(
  BluetoothService service,
  String macAddress,
  String friendlyName,
) async {
  // Android connects over Bluetooth Classic (RFCOMM/SPP) via the native plugin,
  // reusing the shared Classic connect flow (control channel).
  return _connectToRadioClassicImpl(service, macAddress, friendlyName);
}
