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
  // devices can be enumerated. BLE scanning is attempted separately below so
  // a denied scan permission does not hide bonded Classic radios.
  if (!await _ensureAndroidBluetoothPermissions()) {
    service._broker.logError(
      '[Android] Bluetooth Connect permission was not granted',
    );
    return const [];
  }

  // Keep bonded Classic radios (including the VR-N7500) available, then add
  // compatible BLE radios for devices that expose the GATT control service.
  final classic = await _findCompatibleDevicesClassic(service);
  final sdkInt = await AndroidBluetoothPermissions.sdkInt();
  if (sdkInt == null) {
    service._broker.logInfo(
      '[Android] Could not read API level; keeping Classic results only',
    );
    return classic;
  }

  final scanAllowed = await AndroidBluetoothPermissions.ensureScan(
    sdkInt: sdkInt,
    scanStatus: () => Permission.bluetoothScan.status,
    requestScan: () => Permission.bluetoothScan.request(),
    locationStatus: () => Permission.locationWhenInUse.status,
    requestLocation: () => Permission.locationWhenInUse.request(),
  );
  if (!scanAllowed) {
    service._broker.logInfo(
      '[Android] BLE scan permission not granted; keeping Classic results',
    );
    return classic;
  }

  final ble = await _findCompatibleDevicesBle(
    service,
    timeout: timeout,
    useServiceScanFilter: true,
    matchByName: false,
    returnEarlyOnFirstMatch: false,
    androidUsesFineLocation: sdkInt < 31,
  );
  final devicesByAddress = <String, DiscoveredDevice>{};
  String key(String id) => id
      .toUpperCase()
      .replaceAll(RegExp(r'[^0-9A-F]'), '');
  // Classic has priority when the same physical radio is visible through both
  // transports. This preserves N7500's bonded RFCOMM control path.
  for (final device in ble) {
    devicesByAddress[key(device.id)] = device;
  }
  for (final device in classic) {
    devicesByAddress[key(device.id)] = device;
  }
  return devicesByAddress.values.toList(growable: false);
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
  BluetoothType bluetoothType,
) async {
  if (bluetoothType == BluetoothType.ble) {
    return _connectToRadioBleImpl(
      service,
      macAddress,
      friendlyName,
      webFastMode: false,
    );
  }
  return _connectToRadioClassicImpl(service, macAddress, friendlyName);
}
