/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

Captures application log messages from application startup so the Debug tab does
not need to be opened first for messages to be recorded.
*/

import 'dart:async';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';
import '../services/data_broker.dart';
import '../services/data_broker_client.dart';
import '../services/diagnostic_log.dart';

/// Collects `LogInfo` / `LogError` messages (device 1) into the
/// `DebugLogEntries` Data Broker value starting at application launch,
/// independently of whether the Debug tab has ever been viewed.
///
/// The Debug tab simply reads and renders the stored `DebugLogEntries`.
class DebugLogHandler {
  final DataBrokerClient _broker = DataBrokerClient();
  final List<Map<String, dynamic>> _entries = <Map<String, dynamic>>[];
  bool _initialized = false;
  bool _disposed = false;
  Timer? _publishTimer;

  List<Map<String, Object>> get exportMetadata =>
      _entries.map(DiagnosticLog.metadata).toList(growable: false);

  Iterable<String> get _secrets sync* {
    for (final key in [
      'webServerPassword',
      'WinlinkPassword',
      'EchoLinkPassword',
      'EchoLinkProxyPassword',
      'homeAssistantPassword',
      'RepeaterBookToken',
      'AprsFiApiKey',
      'AllStarPassword',
      'AllStarWtToken',
      'AllStarNodePassword',
      'CallSign',
      'webServerPublicOrigin',
    ]) {
      final value = DataBroker.getValue<String>(0, key);
      if (value != null && value.isNotEmpty) yield value;
    }
  }

  String get _platformLabel {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  void init() {
    if (_initialized || _disposed) return;
    _initialized = true;

    // Restore any entries already stored in the broker (e.g. from a sub-window).
    final stored = DataBroker.getValue<List<dynamic>>(1, 'DebugLogEntries');
    if (stored != null) {
      for (final entry
          in stored
              .skip(
                (stored.length - DiagnosticLog.maxEntries).clamp(
                  0,
                  stored.length,
                ),
              )
              .whereType<Map>()
              .take(DiagnosticLog.maxEntries)) {
        if (entry['message'] is! String) continue;
        _entries.add({
          'time': entry['time'] is String
              ? entry['time']
              : DateTime.now().toUtc().toIso8601String(),
          'message': DiagnosticLog.localText(
            entry['message'] as String,
            secrets: _secrets,
          ),
          'isError': entry['isError'] == true,
        });
      }
      _dispatchEntries();
    }

    // Start capturing log messages right away.
    _broker.subscribeMultiple(
      deviceId: 1,
      names: const ['LogInfo', 'LogError'],
      callback: _onLogMessage,
    );

    // Allow the Debug tab (or anything else) to clear the captured log.
    _broker.subscribe(
      deviceId: 1,
      name: 'ClearDebugLog',
      callback: _onClearDebugLog,
    );

    // Emit the startup banner only on a fresh start.
    if (_entries.isEmpty) {
      PackageInfo.fromPlatform().then((info) {
        if (_disposed) return;
        _broker.logInfo(
          'HTCommander ${info.version} started on $_platformLabel',
        );
      }, onError: (Object _) {});
    }
  }

  void _onLogMessage(int deviceId, String name, Object? data) {
    if (_disposed || data is! String) return;
    _entries.add(<String, dynamic>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'message': DiagnosticLog.localText(data, secrets: _secrets),
      'isError': name == 'LogError',
    });
    if (_entries.length > DiagnosticLog.maxEntries) _entries.removeAt(0);
    _publishTimer ??= Timer(const Duration(milliseconds: 250), () {
      _publishTimer = null;
      if (!_disposed) _dispatchEntries();
    });
  }

  void _onClearDebugLog(int deviceId, String name, Object? data) {
    _entries.clear();
    _publishTimer?.cancel();
    _publishTimer = null;
    _dispatchEntries();
  }

  void _dispatchEntries() {
    _broker.dispatch(
      deviceId: 1,
      name: 'DebugLogEntries',
      data: List<Map<String, dynamic>>.unmodifiable(
        _entries.map((entry) => Map<String, dynamic>.unmodifiable(entry)),
      ),
      store: true,
    );
  }

  void dispose() {
    _disposed = true;
    _publishTimer?.cancel();
    _broker.dispose();
    _entries.clear();
  }
}
