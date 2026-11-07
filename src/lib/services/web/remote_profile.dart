import 'dart:convert';
import '../../aprsis/gateway_policy.dart';
import '../../utils/map_source.dart';
import '../data_broker.dart';
import 'remote_access_config.dart';

/// Portable host settings only, never a dump of the broker/preferences.
/// Activation and credentials are deliberately not portable.
abstract final class RemoteProfile {
  static const format = 'htcommander-remote-profile';
  static const defaults = <String, Object>{
    'webServerPort': 18080,
    'webServerPublicOrigin': '',
    'webServerDefaultReadOnly': 1,
    'webServerRequireControlApproval': 1,
    'MapSource': 'osm',
    'AprsIsServer': 'rotate.aprs2.net',
    'AprsIsPort': 14580,
    'AprsIsRangeKm': 0,
    'AprsIsRfPath': '',
    'AprsIsRfPerMinute': 6,
  };
  static const stoppedSettings = <String, int>{
    'AllowTransmit': 0,
    'webServerEmergencyStopped': 1,
    'webServerEnabled': 0,
    'webServerRemoteEnabled': 0,
    'webServerAllowTransmit': 0,
    'webServerAllowAprs': 0,
    'webServerAllowPosition': 0,
    'AprsIsEnabled': 0,
    'AprsIsGateToRf': 0,
    'AprsIsGateToInternet': 0,
  };
  static const omitted = [
    'passwords',
    'tokens',
    'certificate/private-key files',
    'custom map URLs/keys',
    'APRS messages/templates',
    'positions',
    'audio',
    'login sessions',
    'activation/permission switches',
  ];

  static bool _valid(String key, Object? value) {
    bool integer(int min, int max) =>
        value is int && value >= min && value <= max;
    switch (key) {
      case 'webServerPort':
      case 'AprsIsPort':
        return integer(1, 65535);
      case 'webServerDefaultReadOnly':
      case 'webServerRequireControlApproval':
        return integer(0, 1);
      case 'AprsIsRangeKm':
        return integer(0, 10000);
      case 'AprsIsRfPerMinute':
        return integer(1, 30);
      case 'webServerPublicOrigin':
        return value is String &&
            value.length <= 512 &&
            RemoteAccessConfig.validateOrigin(value) == null;
      case 'MapSource':
        return MapSource.builtIn.any((source) => source.id == value);
      case 'AprsIsRfPath':
        return GatewayPolicy.paths.contains(value);
      case 'AprsIsServer':
        if (value is! String ||
            value.isEmpty ||
            value.length > 253 ||
            RegExp(r'[^a-zA-Z0-9.:-]').hasMatch(value)) {
          return false;
        }
        // No credentials, query, path or combined host:port.
        final uri = Uri.tryParse(
          value.contains(':') ? 'http://[$value]' : 'http://$value',
        );
        return uri != null &&
            uri.host.isNotEmpty &&
            !uri.hasPort &&
            uri.path.isEmpty &&
            uri.userInfo.isEmpty;
      default:
        return false;
    }
  }

  static Object _normalize(String key, Object value) =>
      key == 'webServerPublicOrigin' && (value as String).trim().isNotEmpty
      ? Uri.parse(value.trim()).origin
      : value;

  static Map<String, Object> get settings => {
    for (final entry in defaults.entries)
      entry.key: _valid(entry.key, DataBroker.getValueDynamic(0, entry.key))
          ? _normalize(
              entry.key,
              DataBroker.getValueDynamic(0, entry.key) as Object,
            )
          : entry.value,
  };

  static String export() => const JsonEncoder.withIndent('  ').convert({
    'format': format,
    'version': 1,
    'settings': settings,
    'omitted': omitted,
    'importBehavior':
        'Preview first. Stop remote access, gateway and transmit; never resume automatically.',
  });

  static RemoteProfilePlan preview(String text) {
    if (utf8.encode(text).length > 32768) {
      throw const FormatException('Profile exceeds 32 KiB.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const FormatException('Invalid profile JSON.');
    }
    if (decoded is! Map ||
        decoded['format'] != format ||
        decoded['version'] != 1 ||
        decoded['settings'] is! Map ||
        decoded.keys.any(
          (key) => ![
            'format',
            'version',
            'settings',
            'omitted',
            'importBehavior',
          ].contains(key),
        )) {
      throw const FormatException('Unsupported remote profile format.');
    }
    final incoming = decoded['settings'] as Map;
    if (incoming.isEmpty ||
        incoming.length > defaults.length ||
        incoming.keys.any(
          (key) => key is! String || !defaults.containsKey(key),
        )) {
      throw const FormatException('Unknown or forbidden profile settings.');
    }
    final values = <String, Object>{};
    for (final entry in incoming.entries) {
      if (!_valid(entry.key as String, entry.value)) {
        // Never echo imported text/keys into an error or log.
        throw const FormatException('Invalid profile setting value.');
      }
      values[entry.key as String] = _normalize(
        entry.key as String,
        entry.value as Object,
      );
    }
    return RemoteProfilePlan._(values);
  }
}

class RemoteProfilePlan {
  RemoteProfilePlan._(Map<String, Object> values)
    : values = Map.unmodifiable(values),
      before = Map.unmodifiable({
        for (final key in {
          ...values.keys,
          ...RemoteProfile.stoppedSettings.keys,
        })
          key: DataBroker.getValueDynamic(0, key),
      });
  final Map<String, Object> values;
  final Map<String, Object?> before;
  bool _applied = false;
  bool get canApply =>
      !_applied &&
      before.entries.every(
        (entry) => DataBroker.getValueDynamic(0, entry.key) == entry.value,
      );
  Map<String, Object> get after => {
    ...RemoteProfile.stoppedSettings,
    ...values,
  };

  void apply() {
    if (!canApply) throw StateError('Settings changed; preview again.');
    _applied = true;
    // Stop/cancel before changing endpoints or forwarding rules. Nothing from
    // the profile can re-enable a service, resume TX, or restore a login.
    for (final entry in RemoteProfile.stoppedSettings.entries) {
      DataBroker.dispatch(deviceId: 0, name: entry.key, data: entry.value);
    }
    DataBroker.dispatch(
      deviceId: 0,
      name: 'RemoteControlRecall',
      data: true,
      store: false,
    );
    DataBroker.dispatch(
      deviceId: 0,
      name: 'CancelRemoteAprs',
      data: null,
      store: false,
    );
    for (final entry in values.entries) {
      DataBroker.dispatch(deviceId: 0, name: entry.key, data: entry.value);
    }
    DataBroker.dispatch(
      deviceId: 0,
      name: 'RemoteProfileRevision',
      data: (DataBroker.getValue<int>(0, 'RemoteProfileRevision', 0) ?? 0) + 1,
    );
  }
}
