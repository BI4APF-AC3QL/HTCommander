import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/handlers/rolling_voice_handler.dart';
import 'package:htcommander/dialogs/rolling_voice_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  void set(int id, String name, Object? data) =>
      DataBroker.dispatch(deviceId: id, name: name, data: data, store: true);
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
}
