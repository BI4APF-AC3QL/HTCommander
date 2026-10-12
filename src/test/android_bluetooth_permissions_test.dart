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
}
