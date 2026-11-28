import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/android_bluetooth_audio_diagnostics.dart';

void main() {
  test('maps normalized Android Bluetooth addresses to radio device IDs', () {
    final radios = [
      {'DeviceId': 1, 'MacAddress': 'AA:BB:CC:DD:EE:01'},
      {'DeviceId': 2, 'MacAddress': 'AA:BB:CC:DD:EE:FF'},
      {'deviceId': 3, 'macAddress': '10:20:30:40:50:60'},
    ];

    expect(radioDeviceIdForBluetoothAddress(radios, 'aa-bb-cc-dd-ee-ff'), 2);
    expect(radioDeviceIdForBluetoothAddress(radios, '10 20 30 40 50 60'), 3);
    expect(radioDeviceIdForBluetoothAddress(radios, 'unknown'), isNull);
    expect(radioDeviceIdForBluetoothAddress(radios, ''), isNull);
    expect(
      radioDeviceIdForBluetoothAddress([
        {'DeviceId': '2', 'MacAddress': 'AA:BB:CC:DD:EE:FF'},
      ], 'AA:BB:CC:DD:EE:FF'),
      isNull,
    );
  });
}
