import 'package:flutter/services.dart';

/// Keeps the Android process alive while a foreground radio, network server,
/// or local recording feature is explicitly enabled. Other platforms simply
/// ignore a missing plugin.
class AndroidServerLifecycle {
  static const MethodChannel _channel = MethodChannel(
    'com.htcommander/server_lifecycle',
  );

  Future<void> start({String reason = 'server'}) async {
    try {
      await _channel.invokeMethod<void>('start', {'reason': reason});
    } on MissingPluginException {
      // The desktop and web implementations do not register this channel.
    }
  }

  Future<void> stop({String reason = 'server'}) async {
    try {
      await _channel.invokeMethod<void>('stop', {'reason': reason});
    } on MissingPluginException {
      // The desktop and web implementations do not register this channel.
    }
  }

  Future<bool> consumeServiceRecoveryMode() async {
    try {
      return await _channel.invokeMethod<bool>('consumeServiceRecoveryMode') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
