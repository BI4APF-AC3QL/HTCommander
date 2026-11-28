/// DataBroker event used to report native Android RFCOMM audio-queue drops.
const String androidBluetoothAudioQueueEventName =
    'AndroidBluetoothAudioQueueEvent';

/// Finds the app radio associated with a Bluetooth address.
///
/// The address is used only for this in-process lookup and is never copied into
/// the exported diagnostics payload.
int? radioDeviceIdForBluetoothAddress(Object? connectedRadios, String address) {
  if (connectedRadios is! List || address.trim().isEmpty) return null;
  final wanted = _normalizeBluetoothAddress(address);
  for (final radio in connectedRadios.whereType<Map>()) {
    final id = radio['DeviceId'] ?? radio['deviceId'];
    final rawAddress = radio['MacAddress'] ?? radio['macAddress'];
    if (id is int &&
        id > 1 &&
        rawAddress is String &&
        _normalizeBluetoothAddress(rawAddress) == wanted) {
      return id;
    }
  }
  return null;
}

String _normalizeBluetoothAddress(String address) =>
    address.trim().toUpperCase().replaceAll(RegExp(r'[\s:-]'), '');
