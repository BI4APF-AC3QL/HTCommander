import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:htcommander/services/android_bluetooth_permissions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const deviceChannel = MethodChannel('com.htcommander/android_device');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, null);
  });

  test('opens Android Bluetooth settings through the native bridge', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, (call) async {
          calls.add(call);
          return true;
        });

    expect(await AndroidBluetoothPermissions.openBluetoothSettings(), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openBluetoothSettings');
  });

  test('reports Bluetooth settings launch failure without throwing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, (call) async {
          throw PlatformException(code: 'ANDROID_BLUETOOTH_SETTINGS');
        });

    expect(await AndroidBluetoothPermissions.openBluetoothSettings(), isFalse);
  });

  group('Android Bluetooth Connect permission', () {
    test(
      'does not start a radio connection until permission is granted',
      () async {
        var connectCalls = 0;
        var deniedCalls = 0;

        final result =
            await AndroidBluetoothPermissions.withConnectPermission<int>(
              status: () async => PermissionStatus.denied,
              request: () async => PermissionStatus.permanentlyDenied,
              connect: () async {
                connectCalls++;
                return 7;
              },
              onDenied: () => deniedCalls++,
            );

        expect(result, isNull);
        expect(connectCalls, 0);
        expect(deniedCalls, 1);
      },
    );

    test(
      'waits for permission before starting and returns connection result',
      () async {
        var connectCalls = 0;
        var permissionPromptCompleted = false;

        final result =
            await AndroidBluetoothPermissions.withConnectPermission<int>(
              status: () async => PermissionStatus.denied,
              request: () async {
                await Future<void>.delayed(Duration.zero);
                permissionPromptCompleted = true;
                return PermissionStatus.granted;
              },
              connect: () async {
                expect(permissionPromptCompleted, isTrue);
                connectCalls++;
                return 42;
              },
            );

        expect(result, 42);
        expect(connectCalls, 1);
      },
    );

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
