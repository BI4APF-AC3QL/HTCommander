/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import '../utils/num_parsing.dart';

/// Configuration for the app's own periodic APRS beacon
/// ([SoftwareBeaconHandler]).
///
/// Persisted as a JSON string in the [DataBroker] at device 0 under the key
/// `SoftwareBeaconConfig`. Unlike the radio's built-in beacon, the software
/// beacon uses the global station callsign + SSID and the configured RF or
/// verified APRS-IS destination. Saving the configuration does not arm it.
class SoftwareBeaconConfig {
  /// Beacon interval in seconds. 0 disables the beacon.
  final int intervalSeconds;

  /// APRS symbol table identifier (single character, '/' or '\').
  final String symbolTable;

  /// APRS symbol code (single character).
  final String symbolCode;

  /// Free-text comment/status appended to the beacon.
  final String message;

  /// When true, the current GPS/manual location is included as a position
  /// report; otherwise a status-only beacon is sent.
  final bool includeLocation;

  /// Explicit RF destination. -1 = Internet only. There is no radio fallback.
  final int radioDeviceId;

  const SoftwareBeaconConfig({
    this.intervalSeconds = 0,
    this.symbolTable = '/',
    this.symbolCode = '-',
    this.message = '',
    this.includeLocation = true,
    this.radioDeviceId = -1,
  });

  bool get enabled => intervalSeconds > 0;

  String? get validationError {
    if (intervalSeconds != 0 &&
        (intervalSeconds < 60 || intervalSeconds > 86400)) {
      return 'Beacon interval must be 60–86400 seconds, or off.';
    }
    if (!['/', '\\'].contains(symbolTable) ||
        symbolCode.length != 1 ||
        symbolCode.codeUnitAt(0) < 33 ||
        symbolCode.codeUnitAt(0) > 126) {
      return 'Use a valid APRS symbol.';
    }
    if (message.length > 60 ||
        message.codeUnits.any((c) => c < 32 || c > 126)) {
      return 'Beacon comment must be up to 60 printable ASCII characters.';
    }
    if (!includeLocation && message.trim().isEmpty && enabled) {
      return 'A status beacon needs a comment.';
    }
    if (radioDeviceId == 0 || radioDeviceId < -1) {
      return 'Select an explicit destination.';
    }
    return null;
  }

  SoftwareBeaconConfig copyWith({
    int? intervalSeconds,
    String? symbolTable,
    String? symbolCode,
    String? message,
    bool? includeLocation,
    int? radioDeviceId,
  }) {
    return SoftwareBeaconConfig(
      intervalSeconds: intervalSeconds ?? this.intervalSeconds,
      symbolTable: symbolTable ?? this.symbolTable,
      symbolCode: symbolCode ?? this.symbolCode,
      message: message ?? this.message,
      includeLocation: includeLocation ?? this.includeLocation,
      radioDeviceId: radioDeviceId ?? this.radioDeviceId,
    );
  }

  Map<String, dynamic> toJson() => {
    'intervalSeconds': intervalSeconds,
    'symbolTable': symbolTable,
    'symbolCode': symbolCode,
    'message': message,
    'includeLocation': includeLocation,
    'radioDeviceId': radioDeviceId,
  };

  static SoftwareBeaconConfig fromJson(Map<String, dynamic> json) {
    bool asBool(Object? v, bool fallback) {
      if (v is bool) return v;
      if (v is num) return v != 0;
      return fallback;
    }

    String asChar(Object? v, String fallback) {
      if (v is String && v.isNotEmpty) return v.substring(0, 1);
      return fallback;
    }

    return SoftwareBeaconConfig(
      intervalSeconds: asInt(json['intervalSeconds'], 0).clamp(0, 86400),
      symbolTable: asChar(json['symbolTable'], '/'),
      symbolCode: asChar(json['symbolCode'], '-'),
      message: json['message'] is String ? json['message'] as String : '',
      includeLocation: asBool(json['includeLocation'], true),
      radioDeviceId: asInt(json['radioDeviceId'], -1),
    );
  }
}
