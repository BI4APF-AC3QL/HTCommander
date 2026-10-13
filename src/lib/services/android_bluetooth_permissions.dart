import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android runtime Bluetooth permissions and device information helpers.
abstract final class AndroidBluetoothPermissions {
  static const MethodChannel _deviceChannel = MethodChannel(
    'com.htcommander/android_device',
  );

  static Future<int?> sdkInt() async {
    try {
      return await _deviceChannel.invokeMethod<int>('getSdkInt');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> ensureConnect({
    required Future<PermissionStatus> Function() status,
    required Future<PermissionStatus> Function() request,
  }) async {
    try {
      if ((await status()).isGranted) return true;
    } catch (_) {
      // Still try the request path; some platform integrations can report a
      // status-query error while the runtime permission prompt remains usable.
    }
    try {
      return (await request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Runs an Android Bluetooth connection only after the user has granted the
  /// runtime permission required by both bonded Classic RFCOMM and BLE.
  ///
  /// Keep permission prompting in Dart, where the result can be awaited. The
  /// native Classic bridge deliberately fails a connection immediately when
  /// permission is missing; asking there and returning at once makes a user
  /// grant look like a radio connection failure.
  static Future<T?> withConnectPermission<T>({
    required Future<PermissionStatus> Function() status,
    required Future<PermissionStatus> Function() request,
    required Future<T?> Function() connect,
    void Function()? onDenied,
  }) async {
    if (!await ensureConnect(status: status, request: request)) {
      onDenied?.call();
      return null;
    }
    return connect();
  }

  /// BLE scanning requires runtime location permission before Android 12 and
  /// BLUETOOTH_SCAN on Android 12+. Keep failures isolated so bonded Classic
  /// radios remain discoverable even when BLE permission is denied.
  static Future<bool> ensureScan({
    required int sdkInt,
    required Future<PermissionStatus> Function() scanStatus,
    required Future<PermissionStatus> Function() requestScan,
    required Future<PermissionStatus> Function() locationStatus,
    required Future<PermissionStatus> Function() requestLocation,
  }) async {
    final status = sdkInt >= 31 ? scanStatus : locationStatus;
    final request = sdkInt >= 31 ? requestScan : requestLocation;
    try {
      if ((await status()).isGranted) return true;
    } catch (_) {
      // Still try requesting; permission status may be unavailable on some
      // vendor builds even though their runtime permission prompt works.
    }
    try {
      return (await request()).isGranted;
    } catch (_) {
      return false;
    }
  }
}
