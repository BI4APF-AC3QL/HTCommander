import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:htcommander/services/android_bluetooth_permissions.dart';

void main() {
  group('Android Bluetooth Connect permission', () {
    test('does not prompt again when already granted', () async {
      var requestCalls = 0;

      final granted = await AndroidBluetoothPermissions.ensureConnect(
        status: () async => PermissionStatus.granted,
        request: () async {
          requestCalls++;
          return PermissionStatus.granted;
        },
      );

      expect(granted, isTrue);
      expect(requestCalls, 0);
    });

    test('waits for and returns the runtime permission decision', () async {
      var requestCalls = 0;

      final granted = await AndroidBluetoothPermissions.ensureConnect(
        status: () async => PermissionStatus.denied,
        request: () async {
          requestCalls++;
          return PermissionStatus.granted;
        },
      );

      expect(granted, isTrue);
      expect(requestCalls, 1);
    });

    test('reports denial without pretending Bluetooth is available', () async {
      final granted = await AndroidBluetoothPermissions.ensureConnect(
        status: () async => PermissionStatus.denied,
        request: () async => PermissionStatus.permanentlyDenied,
      );

      expect(granted, isFalse);
    });

    test('tries requesting permission if reading status fails', () async {
      var requestCalls = 0;

      final granted = await AndroidBluetoothPermissions.ensureConnect(
        status: () async => throw StateError('status unavailable'),
        request: () async {
          requestCalls++;
          return PermissionStatus.granted;
        },
      );

      expect(granted, isTrue);
      expect(requestCalls, 1);
    });

    test('handles unavailable permission plugin gracefully', () async {
      final granted = await AndroidBluetoothPermissions.ensureConnect(
        status: () async => throw StateError('plugin unavailable'),
        request: () async => throw StateError('request unavailable'),
      );

      expect(granted, isFalse);
    });
  });

  group('Android BLE scan permission', () {
    test('Android 12+ requests Bluetooth Scan only', () async {
      var scanRequests = 0;
      var locationRequests = 0;
      final granted = await AndroidBluetoothPermissions.ensureScan(
        sdkInt: 31,
        scanStatus: () async => PermissionStatus.denied,
        requestScan: () async {
          scanRequests++;
          return PermissionStatus.granted;
        },
        locationStatus: () async => PermissionStatus.denied,
        requestLocation: () async {
          locationRequests++;
          return PermissionStatus.granted;
        },
      );

      expect(granted, isTrue);
      expect(scanRequests, 1);
      expect(locationRequests, 0);
    });

    test('Android 11 and older request location for BLE scanning', () async {
      var scanRequests = 0;
      var locationRequests = 0;
      final granted = await AndroidBluetoothPermissions.ensureScan(
        sdkInt: 30,
        scanStatus: () async => PermissionStatus.denied,
        requestScan: () async {
          scanRequests++;
          return PermissionStatus.granted;
        },
        locationStatus: () async => PermissionStatus.denied,
        requestLocation: () async {
          locationRequests++;
          return PermissionStatus.granted;
        },
      );

      expect(granted, isTrue);
      expect(scanRequests, 0);
      expect(locationRequests, 1);
    });

    test('permission denial allows caller to preserve Classic discovery', () async {
      final granted = await AndroidBluetoothPermissions.ensureScan(
        sdkInt: 33,
        scanStatus: () async => PermissionStatus.denied,
        requestScan: () async => PermissionStatus.permanentlyDenied,
        locationStatus: () async => PermissionStatus.denied,
        requestLocation: () async => PermissionStatus.granted,
      );

      expect(granted, isFalse);
    });
  });
}
