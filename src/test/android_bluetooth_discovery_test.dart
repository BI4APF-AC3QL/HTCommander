import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/radio/radio_transport.dart';
import 'package:htcommander/services/android_bluetooth_discovery.dart';

DiscoveredDevice _device(String id, String name, BluetoothType type) =>
    DiscoveredDevice(id: id, name: name, type: type);

void main() {
  test(
    'Classic entry wins when the same radio is found by BLE and Classic',
    () {
      final merged = AndroidBluetoothDiscovery.merge(
        ble: [_device('aa-bb-cc-dd-ee-ff', 'N7500 BLE', BluetoothType.ble)],
        classic: [
          _device('AA:BB:CC:DD:EE:FF', 'VR-N7500', BluetoothType.classic),
        ],
      );

      expect(merged, hasLength(1));
      expect(merged.single.name, 'VR-N7500');
      expect(merged.single.type, BluetoothType.classic);
    },
  );

  test('keeps different radios while normalizing address punctuation', () {
    final merged = AndroidBluetoothDiscovery.merge(
      ble: [
        _device('AA:BB:CC:DD:EE:FF', 'BLE radio', BluetoothType.ble),
        _device('10-20-30-40-50-60', 'Second BLE radio', BluetoothType.ble),
      ],
      classic: [
        _device('aa bb cc dd ee ff', 'Classic radio', BluetoothType.classic),
      ],
    );

    expect(merged, hasLength(2));
    expect(merged.map((device) => device.name), [
      'Classic radio',
      'Second BLE radio',
    ]);
  });
}
