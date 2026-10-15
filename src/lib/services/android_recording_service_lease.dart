import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'android_server_lifecycle.dart';

/// Keeps Android's microphone-capable foreground service active while one or
/// more local microphone inputs are open.
///
/// Calls are serialized so simultaneous input starts/stops cannot drop the
/// shared `microphone` service reason while another input is still capturing.
class AndroidRecordingServiceLease {
  AndroidRecordingServiceLease({
    bool? enabled,
    this.startService,
    this.stopService,
  }) : _enabled = enabled ?? (!kIsWeb && Platform.isAndroid);

  final bool _enabled;
  final Future<void> Function()? startService;
  final Future<void> Function()? stopService;
  final AndroidServerLifecycle _lifecycle = AndroidServerLifecycle();

  Future<void> _transition = Future<void>.value();
  int _leases = 0;

  Future<void> acquire() => _enqueue(() async {
    if (_leases == 0 && _enabled) {
      await (startService?.call() ?? _lifecycle.start(reason: 'microphone'));
    }
    _leases++;
  });

  Future<void> release() => _enqueue(() async {
    if (_leases == 0) return;
    _leases--;
    if (_leases == 0 && _enabled) {
      await (stopService?.call() ?? _lifecycle.stop(reason: 'microphone'));
    }
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _transition.then((_) => action());
    _transition = next.catchError((Object _) {});
    return next;
  }
}
