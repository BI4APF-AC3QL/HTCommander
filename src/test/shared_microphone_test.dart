import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/android_recording_service_lease.dart';
import 'package:htcommander/services/microphone_capture.dart';
import 'package:htcommander/services/shared_microphone.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps one microphone service lease for all shared consumers', () async {
    final events = <String>[];
    final capture = _FakeMicrophoneCapture(events: events);
    final service = AndroidRecordingServiceLease(
      enabled: true,
      startService: () async => events.add('serviceStart'),
      stopService: () async => events.add('serviceStop'),
    );
    final microphone = SharedMicrophone.forTesting(
      capture: capture,
      recordingService: service,
    );

    final ptt = await microphone.acquire((_) {});
    final spectrum = await microphone.acquire((_) {});
    expect(ptt, isNotNull);
    expect(spectrum, isNotNull);
    expect(events, ['permission', 'serviceStart', 'captureStart']);

    await ptt!.cancel();
    expect(events, isNot(contains('serviceStop')));
    await spectrum!.cancel();
    expect(events, [
      'permission',
      'serviceStart',
      'captureStart',
      'captureStop',
      'serviceStop',
    ]);
  });

  test('does not start microphone service when permission is denied', () async {
    final events = <String>[];
    final capture = _FakeMicrophoneCapture(
      events: events,
      permissionGranted: false,
    );
    final service = AndroidRecordingServiceLease(
      enabled: true,
      startService: () async => events.add('serviceStart'),
      stopService: () async => events.add('serviceStop'),
    );
    final microphone = SharedMicrophone.forTesting(
      capture: capture,
      recordingService: service,
    );

    expect(await microphone.acquire((_) {}), isNull);
    expect(events, ['permission']);
    expect(capture.starts, 0);
  });

  test(
    'releases the service lease if microphone capture cannot start',
    () async {
      final events = <String>[];
      final capture = _FakeMicrophoneCapture(
        events: events,
        startResult: false,
      );
      final service = AndroidRecordingServiceLease(
        enabled: true,
        startService: () async => events.add('serviceStart'),
        stopService: () async => events.add('serviceStop'),
      );
      final microphone = SharedMicrophone.forTesting(
        capture: capture,
        recordingService: service,
      );

      expect(await microphone.acquire((_) {}), isNull);
      expect(events, [
        'permission',
        'serviceStart',
        'captureStart',
        'serviceStop',
      ]);
    },
  );

  test(
    'restarts on the latest device when selection changes during startup',
    () async {
      final firstStartEntered = Completer<void>();
      final firstStartGate = Completer<void>();
      final capture = _FakeMicrophoneCapture(
        events: <String>[],
        startGates: <int, Completer<void>>{1: firstStartGate},
        startEntered: <int, Completer<void>>{1: firstStartEntered},
      );
      final microphone = SharedMicrophone.forTesting(
        capture: capture,
        recordingService: AndroidRecordingServiceLease(enabled: false),
      );

      final acquiring = microphone.acquire((_) {});
      await firstStartEntered.future;
      final changingDevice = microphone.setDeviceId('usb-mic');
      firstStartGate.complete();

      final handle = await acquiring;
      await changingDevice;

      expect(handle, isNotNull);
      expect(capture.startedDevices, <String?>[null, 'usb-mic']);
      expect(capture.starts, 2);
      await handle!.cancel();
    },
  );

  test('joins capture while a device replacement is still starting', () async {
    final replacementStartEntered = Completer<void>();
    final replacementStartGate = Completer<void>();
    final capture = _FakeMicrophoneCapture(
      events: <String>[],
      startGates: <int, Completer<void>>{2: replacementStartGate},
      startEntered: <int, Completer<void>>{2: replacementStartEntered},
    );
    final microphone = SharedMicrophone.forTesting(
      capture: capture,
      recordingService: AndroidRecordingServiceLease(enabled: false),
    );

    final firstHandle = await microphone.acquire((_) {});
    final changingDevice = microphone.setDeviceId('usb-mic');
    await replacementStartEntered.future;
    final secondAcquire = microphone.acquire((_) {});
    replacementStartGate.complete();

    final secondHandle = await secondAcquire;
    await changingDevice;

    expect(firstHandle, isNotNull);
    expect(secondHandle, isNotNull);
    expect(capture.starts, 2);
    expect(capture.startedDevices, <String?>[null, 'usb-mic']);
    await firstHandle!.cancel();
    await secondHandle!.cancel();
  });
}

class _FakeMicrophoneCapture implements MicrophoneCaptureSource {
  _FakeMicrophoneCapture({
    required this.events,
    this.permissionGranted = true,
    this.startResult = true,
    this.startGates = const <int, Completer<void>>{},
    this.startEntered = const <int, Completer<void>>{},
  });

  final List<String> events;
  final bool permissionGranted;
  final bool startResult;
  final Map<int, Completer<void>> startGates;
  final Map<int, Completer<void>> startEntered;
  final List<String?> startedDevices = <String?>[];
  @override
  double gain = 1.0;
  @override
  String? deviceId;
  var starts = 0;
  var _capturing = false;

  @override
  bool get isCapturing => _capturing;

  @override
  Future<bool> hasPermission() async {
    events.add('permission');
    return permissionGranted;
  }

  @override
  Future<bool> start(void Function(Uint8List pcm16) onData) async {
    events.add('captureStart');
    starts++;
    startedDevices.add(deviceId);
    startEntered[starts]?.complete();
    await startGates[starts]?.future;
    _capturing = startResult;
    return startResult;
  }

  @override
  Future<void> stop() async {
    if (_capturing) events.add('captureStop');
    _capturing = false;
  }
}
