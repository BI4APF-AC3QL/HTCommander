import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/handlers/rolling_voice_handler.dart';
import 'package:htcommander/dialogs/rolling_voice_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void set(int id, String name, Object? data) =>
      DataBroker.dispatch(deviceId: id, name: name, data: data, store: true);
  Future<void> waitFor(bool Function() predicate) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(predicate(), isTrue, reason: 'condition did not settle');
  }
  tearDown(DataBroker.reset);
  test(
    'production audio broker captures only selected received voice',
    () async {
      final dir = Directory.systemTemp.createTempSync('htc-rolling-handler-');
      final handler = RollingVoiceHandler(folderProvider: () async => dir.path);
      try {
        set(0, 'RollingVoiceEnabled', true);
        set(1, 'SelectedRadioDeviceId', 2);
        handler.init();
        for (var i = 0; i < 100; i++) {
          if ((DataBroker.getValueDynamic(0, 'RollingVoiceStatus')
                  as Map?)?['running'] ==
              true) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          (DataBroker.getValueDynamic(0, 'RollingVoiceStatus')
              as Map)['running'],
          true,
        );
        final pcm = Uint8List.fromList([1, 2, 3, 4]),
            normal = {
              'data': pcm,
              'offset': 0,
              'length': 4,
              'channelName': 'Voice',
              'transmit': false,
              'muted': false,
              'usage': null,
            };
        void emit(int id, Map frame) => DataBroker.dispatch(
          deviceId: id,
          name: 'AudioDataAvailable',
          data: frame,
          store: false,
        );
        emit(2, normal);
        emit(3, normal);
        emit(200, normal);
        emit(2, {...normal, 'transmit': true});
        emit(2, {...normal, 'muted': true});
        emit(2, {...normal, 'channelName': 'APRS'});
        emit(2, {...normal, 'usage': 'BBS'});
        emit(2, {...normal, 'offset': 10});
        emit(2, {...normal, 'usage': 'Satellite'});
        await handler.close();
        final files = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.wav'))
            .toList();
        expect(files, hasLength(1));
        expect(files.single.readAsBytesSync().sublist(44), [...pcm, ...pcm]);
      } finally {
        await handler.close();
        dir.deleteSync(recursive: true);
      }
    },
  );
  test('disabling during Android service startup releases the late start', () async {
    final serviceStart = Completer<void>();
    final startCalled = Completer<void>();
    var stopCalls = 0;
    final handler = RollingVoiceHandler(
      isAndroid: true,
      startAndroidService: () {
        startCalled.complete();
        return serviceStart.future;
      },
      stopAndroidService: () async {
        stopCalls++;
      },
    );
    try {
      set(0, 'RollingVoiceEnabled', true);
      handler.init();
      await startCalled.future.timeout(const Duration(seconds: 2));

      set(0, 'RollingVoiceEnabled', false);
      serviceStart.complete();
      await waitFor(() => stopCalls == 1);

      expect(stopCalls, 1);
      expect(
        (DataBroker.getValueDynamic(0, 'RollingVoiceStatus') as Map)['running'],
        false,
      );
    } finally {
      if (!serviceStart.isCompleted) serviceStart.complete();
      await handler.close();
    }
  });
  test('closing during Android service startup stops the late start', () async {
    final serviceStart = Completer<void>();
    final startCalled = Completer<void>();
    var stopCalls = 0;
    final handler = RollingVoiceHandler(
      isAndroid: true,
      startAndroidService: () {
        startCalled.complete();
        return serviceStart.future;
      },
      stopAndroidService: () async {
        stopCalls++;
      },
    );
    try {
      set(0, 'RollingVoiceEnabled', true);
      handler.init();
      await startCalled.future.timeout(const Duration(seconds: 2));

      final closing = handler.close();
      serviceStart.complete();
      await closing;
      expect(stopCalls, 1);
    } finally {
      if (!serviceStart.isCompleted) serviceStart.complete();
      await handler.close();
    }
  });
  test(
    'retries stopping Android recording service after transient failure',
    () async {
      final dir = Directory.systemTemp.createTempSync('htc-rolling-service-');
      var starts = 0;
      var stops = 0;
      final handler = RollingVoiceHandler(
        folderProvider: () async => dir.path,
        isAndroid: true,
        startAndroidService: () async {
          starts++;
        },
        stopAndroidService: () async {
          stops++;
          if (stops == 1) throw StateError('temporary stop failure');
        },
        retryDelay: const Duration(milliseconds: 5),
      );
      try {
        set(0, 'RollingVoiceEnabled', true);
        handler.init();
        await waitFor(
          () =>
              (DataBroker.getValueDynamic(0, 'RollingVoiceStatus') as Map?)?[
                  'running'
              ] ==
              true,
        );
        expect(starts, 1);

        set(0, 'RollingVoiceEnabled', false);
        await waitFor(() => stops == 2);

        expect(stops, 2);
        expect(
          (DataBroker.getValueDynamic(0, 'RollingVoiceStatus') as Map)[
            'running'
          ],
          false,
        );
      } finally {
        await handler.close();
        dir.deleteSync(recursive: true);
      }
    },
  );
  testWidgets('local dialog default 24h and explicit start persist config', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RollingVoiceDialog())),
    );
    expect(find.text('24 小时'), findsOneWidget);
    expect(DataBroker.getValue<bool>(0, 'RollingVoiceEnabled', false), false);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(DataBroker.getValue<bool>(0, 'RollingVoiceEnabled', false), true);
    expect(find.text('保留最新片段'), findsOneWidget);
  });
  testWidgets('status updates fit narrow host dialog and sanitized errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    set(0, 'RollingVoiceStatus', {
      'running': false,
      'error': 'storage_write_failed',
      'files': 5,
      'keptFiles': 2,
    });
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RollingVoiceDialog())),
    );
    expect(find.textContaining('录音写入失败'), findsOneWidget);
    expect(find.textContaining('循环片段 5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Android dialog offers WAV export instead of opening a folder', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      set(0, 'RollingVoiceStatus', {
        'running': true,
        'folder': '/app/support/rolling-voice',
        'files': 1,
        'keptFiles': 0,
        'recent': [
          {'name': 'rx_123_2_abcd1234_0.wav', 'bytes': 4096, 'kept': false},
        ],
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RollingVoiceDialog())),
      );
      expect(find.byTooltip('导出 WAV'), findsOneWidget);
      expect(find.text('打开录音目录'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = originalPlatform;
    }
  });
  testWidgets('Android exports protected clips from the kept subdirectory', (
    tester,
  ) async {
    final originalPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final directory = Directory.systemTemp.createTempSync(
      'htc-rolling-kept-export-',
    );
    const name = 'rx_123_2_abcd1234_0.wav';
    final wavBytes = Uint8List.fromList([1, 2, 3, 4]);
    final clip = File(
      '${directory.path}${Platform.pathSeparator}kept'
      '${Platform.pathSeparator}$name',
    )..createSync(recursive: true);
    clip.writeAsBytesSync(wavBytes);
    final exportedBytes = Completer<Uint8List>();
    const filePicker = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(filePicker, (call) async {
      expect(call.method, 'save');
      exportedBytes.complete((call.arguments as Map)['bytes'] as Uint8List);
      return null;
    });
    try {
      set(0, 'RollingVoiceStatus', {
        'running': true,
        'folder': directory.path,
        'files': 0,
        'keptFiles': 1,
        'recent': [
          {'name': name, 'bytes': wavBytes.length, 'kept': true},
        ],
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RollingVoiceDialog())),
      );
      await tester.ensureVisible(find.byTooltip('导出 WAV'));
      await tester.tap(find.byTooltip('导出 WAV'));
      final exported = await tester.runAsync(
        () => exportedBytes.future.timeout(const Duration(seconds: 2)),
      );
      expect(exported, orderedEquals(wavBytes));
    } finally {
      messenger.setMockMethodCallHandler(filePicker, null);
      debugDefaultTargetPlatformOverride = originalPlatform;
      directory.deleteSync(recursive: true);
    }
  });
}
