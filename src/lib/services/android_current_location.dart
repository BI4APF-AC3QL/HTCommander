import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Reads one fresh Android location fix after an explicit user action.
/// The resulting coordinates are saved through the existing manual-location
/// setting, so radio beacons, APRS-IS filtering and satellite tracking share it.
class AndroidCurrentLocation {
  static const _channel = MethodChannel('com.htcommander/device_location');
  static const _updates = EventChannel('com.htcommander/device_location_updates');

  /// Requests the foreground location permission from an explicit UI action.
  static Future<void> requestPermission() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Device location is only available on Android.');
    }
    final permission = await Permission.locationWhenInUse.request();
    if (!permission.isGranted && !permission.isLimited) {
      throw const AndroidLocationException('permission_denied');
    }
  }

  static Future<AndroidCoordinates> getCurrentPosition() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Device location is only available on Android.');
    }
    final permission = await Permission.locationWhenInUse.request();
    if (!permission.isGranted && !permission.isLimited) {
      throw const AndroidLocationException('permission_denied');
    }
    final value = await _channel.invokeMapMethod<String, Object?>(
      'getCurrentPosition',
    );
    if (value == null) {
      throw const AndroidLocationException('location_unavailable');
    }
    return parsePosition(value);
  }

  /// Streams fresh positions while Android's explicit location foreground
  /// service is active. Permission must have been granted from the UI first.
  static Stream<AndroidCoordinates> watchPosition() {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Device location is only available on Android.');
    }
    return _validatedUpdates();
  }

  static Stream<AndroidCoordinates> _validatedUpdates() async* {
    await for (final event in _updates.receiveBroadcastStream()) {
      try {
        if (event is! Map) continue;
        yield parsePosition(Map<String, Object?>.from(event));
      } on AndroidLocationException {
        // Android may emit a cached or incomplete provider fix before a fresh
        // location arrives. Ignore that sample without ending the live stream.
      }
    }
  }

  static AndroidCoordinates parsePosition(
    Map<String, Object?> value, {
    DateTime? now,
  }) {
    final latitude = (value['latitude'] as num?)?.toDouble();
    final longitude = (value['longitude'] as num?)?.toDouble();
    final timestamp = value['timestamp'] as int?;
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180 ||
        (latitude == 0 && longitude == 0) ||
        timestamp == null) {
      throw const AndroidLocationException('invalid_fix');
    }
    final age = (now ?? DateTime.now()).millisecondsSinceEpoch - timestamp;
    if (age < -30000 || age > const Duration(minutes: 2).inMilliseconds) {
      throw const AndroidLocationException('stale_fix');
    }
    return AndroidCoordinates(latitude, longitude);
  }
}

class AndroidCoordinates {
  const AndroidCoordinates(this.latitude, this.longitude);
  final double latitude;
  final double longitude;
}

class AndroidLocationException implements Exception {
  const AndroidLocationException(this.code);
  final String code;
}
