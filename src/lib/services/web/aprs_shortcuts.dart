import 'dart:convert';
import '../data_broker.dart';

class AprsTemplate {
  const AprsTemplate(this.name, this.text);
  final String name, text;
  Map<String, String> toJson() => {'name': name, 'text': text};
}

/// Host-managed shortcuts. Selecting a shortcut never submits a radio packet.
class AprsShortcuts {
  AprsShortcuts({
    List<String> favorites = const [],
    List<AprsTemplate> templates = const [],
  }) : favorites = List.unmodifiable(favorites),
       templates = List.unmodifiable(templates);
  final List<String> favorites;
  final List<AprsTemplate> templates;
  static const setting = 'RemoteAprsShortcuts';
  static final callsign = RegExp(r'^[A-Z0-9]{1,6}(?:-(?:[0-9]|1[0-5]))?$');
  static String? messageError(String value) =>
      value.trim().isEmpty ||
          value.length > 67 ||
          !RegExp(r'^[\x20-\x7e]+$').hasMatch(value) ||
          RegExp(r'[{|~]').hasMatch(value)
      ? 'Message must be 1–67 printable ASCII characters without { | ~.'
      : null;

  factory AprsShortcuts.parse(String favorites, String templates) {
    final calls = favorites
        .split('\n')
        .map((e) => e.trim().toUpperCase())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    final values = <AprsTemplate>[];
    for (final line
        in templates.split('\n').where((e) => e.trim().isNotEmpty)) {
      final split = line.indexOf(':');
      if (split <= 0) {
        throw const FormatException('Use Name: message for each template.');
      }
      values.add(
        AprsTemplate(
          line.substring(0, split).trim(),
          line.substring(split + 1).trim(),
        ),
      );
    }
    return AprsShortcuts(favorites: calls, templates: values)..validate();
  }

  void validate() {
    if (favorites.length > 20 || templates.length > 16) {
      throw const FormatException('Maximum 20 callsigns and 16 templates.');
    }
    for (final call in favorites) {
      if (call.length > 9 || !callsign.hasMatch(call)) {
        throw const FormatException('Invalid callsign/SSID.');
      }
    }
    final names = <String>{};
    for (final item in templates) {
      if (item.name.trim().isEmpty ||
          item.name.length > 24 ||
          RegExp(r'[\x00-\x1f\x7f:]').hasMatch(item.name) ||
          !names.add(item.name.toUpperCase())) {
        throw const FormatException(
          'Template names must be unique, 1–24 characters, without control characters or colons.',
        );
      }
      final error = messageError(item.text);
      if (error != null) throw FormatException(error);
    }
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'favorites': favorites,
    'templates': templates.map((e) => e.toJson()).toList(),
  };
  String encode() {
    validate();
    return jsonEncode(toJson());
  }

  static AprsShortcuts decode(String value) {
    try {
      if (value.length > 16384) return AprsShortcuts();
      final data = jsonDecode(value) as Map;
      if (data['version'] != 1) return AprsShortcuts();
      final result = AprsShortcuts(
        favorites: (data['favorites'] as List).cast<String>(),
        templates: (data['templates'] as List)
            .map((e) => AprsTemplate(e['name'] as String, e['text'] as String))
            .toList(),
      );
      result.validate();
      return result;
    } catch (_) {
      return AprsShortcuts();
    }
  }

  static AprsShortcuts get current =>
      decode(DataBroker.getValue<String>(0, setting, '') ?? '');
  void save() => DataBroker.dispatch(
    deviceId: 0,
    name: setting,
    data: encode(),
    store: true,
  );
}
