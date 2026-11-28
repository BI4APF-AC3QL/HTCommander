/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'android_recording_service_lease.dart';
import 'microphone_capture.dart';

/// A handle returned by [SharedMicrophone.acquire]. Cancel it to stop receiving
/// microphone PCM; the underlying hardware is released once the last handle is
/// cancelled.
class MicrophoneHandle {
  MicrophoneHandle._(this._owner, this._onPcm);

  final SharedMicrophone _owner;
  final void Function(Uint8List pcm16) _onPcm;
  bool _active = true;

  /// Stops delivering microphone PCM to this consumer.
  Future<void> cancel() async {
    if (!_active) return;
    _active = false;
    await _owner._release(this);
  }
}

/// Process-wide microphone owner shared by every consumer (the Comms tab's
/// push-to-talk and the Audio tab's spectrograph).
///
/// Only ONE underlying [MicrophoneCapture] (and therefore one native audio
/// recorder) ever runs: opening a second recorder on the same input device
/// fails or crashes on desktop platforms. Consumers [acquire] a [MicrophoneHandle]
/// and the captured PCM is fanned out to all of them; the hardware starts with
/// the first consumer and stops with the last.
class SharedMicrophone {
  SharedMicrophone._()
    : _capture = MicrophoneCapture(sampleRate: 32000),
      _recordingService = AndroidRecordingServiceLease.shared;

  @visibleForTesting
  SharedMicrophone.forTesting({
    required this._capture,
    required this._recordingService,
  });

  /// The single shared instance.
  static final SharedMicrophone instance = SharedMicrophone._();

  /// Whether microphone capture is supported on the current platform.
  static bool get isSupported => MicrophoneCapture.isSupported;

  final MicrophoneCaptureSource _capture;
  final AndroidRecordingServiceLease _recordingService;
  final List<MicrophoneHandle> _handles = <MicrophoneHandle>[];
  Future<bool>? _startFuture;
  Future<void>? _stopFuture;
  Future<void>? _deviceChangeFuture;
  bool _serviceLeaseHeld = false;

  double _gain = 1.0;
  String? _deviceId;
  String? _capturingDeviceId;

  /// Whether the microphone hardware is currently running.
  bool get isCapturing => _capture.isCapturing;

  /// The linear gain applied to captured PCM before it is delivered.
  double get gain => _gain;
  set gain(double value) {
    _gain = value;
    _capture.gain = value;
  }

  /// Selects the input (microphone) device (null / empty = OS default). A live
  /// capture is restarted so it re-opens on the new device.
  Future<void> setDeviceId(String? id) async {
    final normalized = (id == null || id.isEmpty) ? null : id;
    if (normalized == _deviceId) return;
    _deviceId = normalized;
    if (_capture.isCapturing || _startFuture != null) {
      await _synchronizeCaptureDevice();
    }
  }

  /// Begins delivering microphone PCM to [onPcm]. The first consumer starts the
  /// hardware; subsequent consumers share the same capture. Returns a handle on
  /// success, or null if the microphone could not be started (e.g. permission
  /// denied) and this was the only consumer requesting it.
  Future<MicrophoneHandle?> acquire(
    void Function(Uint8List pcm16) onPcm,
  ) async {
    if (!isSupported) return null;

    final handle = MicrophoneHandle._(this, onPcm);
    _handles.add(handle);

    // Wait for any device switch to finish before joining or starting capture.
    // The loop also closes the small window where a second switch is queued as
    // the first one completes.
    while (true) {
      final changingDevice = _deviceChangeFuture;
      if (changingDevice != null) {
        await changingDevice;
        continue;
      }
      final stopping = _stopFuture;
      if (stopping != null) {
        await stopping;
        continue;
      }
      break;
    }

    // Already running (or another acquire is warming it up): just join.
    if (_capture.isCapturing) return handle;

    final bool ok = await _ensureCaptureStarted();

    if (!ok) {
      handle._active = false;
      _handles.remove(handle);
      return null;
    }

    // Everyone cancelled while the hardware was starting up.
    if (_handles.isEmpty) {
      await _stopCapture();
    }
    return handle;
  }

  Future<bool> _startCapture() async {
    final deviceId = _deviceId;
    try {
      // Android requires RECORD_AUDIO before promoting a service to its
      // microphone foreground type, so check permission before acquiring the
      // process-wide service lease.
      if (!await _capture.hasPermission()) return false;
      await _recordingService.acquire();
      _serviceLeaseHeld = true;
      _capture.gain = _gain;
      _capture.deviceId = deviceId;
      final started = await _capture.start(_fanOut);
      if (started) {
        _capturingDeviceId = deviceId;
      } else {
        _capturingDeviceId = null;
        await _releaseServiceLease();
      }
      return started;
    } catch (_) {
      _capturingDeviceId = null;
      await _releaseServiceLease();
      return false;
    }
  }

  Future<bool> _ensureCaptureStarted() async {
    final starting = _startFuture ??= _startCapture();
    final bool started = await starting;
    if (identical(_startFuture, starting)) _startFuture = null;
    return started;
  }

  Future<void> _synchronizeCaptureDevice() {
    final existing = _deviceChangeFuture;
    if (existing != null) return existing;
    late final Future<void> changing;
    changing = _synchronizeCaptureDeviceImpl().whenComplete(() {
      if (identical(_deviceChangeFuture, changing)) {
        _deviceChangeFuture = null;
      }
    });
    _deviceChangeFuture = changing;
    return changing;
  }

  Future<void> _synchronizeCaptureDeviceImpl() async {
    while (_handles.isNotEmpty) {
      final starting = _startFuture;
      if (starting != null) await starting;
      if (!_capture.isCapturing) return;
      if (_capturingDeviceId == _deviceId) return;

      await _stopCapture();
      if (_handles.isEmpty) return;
      if (!await _ensureCaptureStarted()) return;
    }

    // A consumer may cancel while a replacement device is starting.
    if (_capture.isCapturing) await _stopCapture();
  }

  void _fanOut(Uint8List pcm16) {
    // Iterate a copy so a consumer cancelling during delivery is safe.
    for (final handle in List<MicrophoneHandle>.of(_handles)) {
      if (handle._active) {
        try {
          handle._onPcm(pcm16);
        } catch (e) {
          debugPrint('SharedMicrophone: consumer error: $e');
        }
      }
    }
  }

  Future<void> _release(MicrophoneHandle handle) async {
    _handles.remove(handle);
    if (_handles.isEmpty && _startFuture == null) {
      await _stopCapture();
    }
  }

  Future<void> _stopCapture() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    late final Future<void> stopping;
    stopping = _stopCaptureImpl().whenComplete(() {
      if (identical(_stopFuture, stopping)) _stopFuture = null;
    });
    _stopFuture = stopping;
    return stopping;
  }

  Future<void> _stopCaptureImpl() async {
    try {
      await _capture.stop();
    } finally {
      _capturingDeviceId = null;
      await _releaseServiceLease();
    }
  }

  Future<void> _releaseServiceLease() async {
    if (!_serviceLeaseHeld) return;
    _serviceLeaseHeld = false;
    try {
      await _recordingService.release();
    } catch (_) {
      // Capture teardown should finish if Android rejects an update while the
      // process is shutting down.
    }
  }
}
