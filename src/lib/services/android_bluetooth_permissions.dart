import 'package:permission_handler/permission_handler.dart';

/// Requests only the Android Bluetooth permission required to enumerate and
/// connect to bonded Classic radios. Scanning permission is optional: the
/// native bridge uses it only to cancel discovery as a connection-speed
/// optimization.
abstract final class AndroidBluetoothPermissions {
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
}
