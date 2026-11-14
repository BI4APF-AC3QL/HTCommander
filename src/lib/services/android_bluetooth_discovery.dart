/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0
http://www.apache.org/licenses/LICENSE-2.0
*/

import '../radio/radio_transport.dart';

/// Combines Android's bonded Bluetooth Classic radios with radios found by a
/// BLE scan. A radio visible through both transports must keep the Classic
/// entry because some models (including VR-N7500) use Classic RFCOMM for
/// control even when a BLE advertisement is also present.
class AndroidBluetoothDiscovery {
  const AndroidBluetoothDiscovery._();

  static List<DiscoveredDevice> merge({
    required Iterable<DiscoveredDevice> classic,
    required Iterable<DiscoveredDevice> ble,
  }) {
    final devicesByAddress = <String, DiscoveredDevice>{};

    // Insert BLE first so Classic can replace it for the same physical radio.
    for (final device in ble) {
      devicesByAddress[_addressKey(device.id)] = device;
    }
    for (final device in classic) {
      devicesByAddress[_addressKey(device.id)] = device;
    }

    return List<DiscoveredDevice>.unmodifiable(devicesByAddress.values);
  }

  static String _addressKey(String id) =>
      id.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
}
