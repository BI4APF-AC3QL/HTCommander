import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/radio/pcm_player.dart';
import 'package:htcommander/radio/radio.dart';
import 'package:htcommander/radio/radio_audio.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/android_bluetooth_audio_diagnostics.dart';
import 'package:htcommander/services/web/remote_link_status.dart';

class _Player implements PcmPlayer {
  PcmFeedCallback? drained;
  bool fail = false;
  int feeds = 0;
  @override
  Future<void> setLogLevelError() async {}
  @override
  Future<void> setup({
    required int sampleRate,
    required int channelCount,
    String? deviceId,
  }) async {}
  @override
  Future<void> setFeedThreshold(int frames) async {}
  @override
  void setFeedCallback(PcmFeedCallback? callback) {
    drained = callback;
  }

  @override
  void start() {}
  @override
  Future<void> feed(Int16List pcm) async {
    feeds++;
    if (fail) throw StateError('private error');
  }

  @override
  Future<void> release() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(DataBroker.reset);
  test(
    'production RadioAudio observes native RX, actual feed/drop/drain errors and stop',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const native = MethodChannel('com.htcommander/bluetooth_classic');
      const controlEvents = MethodChannel(
        'com.htcommander/bluetooth_classic_data',
      );
      const audioEvents = MethodChannel(
        'com.htcommander/bluetooth_classic_audio',
      );
      final calls = <String>[];
      messenger.setMockMethodCallHandler(native, (call) async {
        calls.add(call.method);
        return true;
      });
      messenger.setMockMethodCallHandler(controlEvents, (_) async => null);
      messenger.setMockMethodCallHandler(audioEvents, (_) async => null);
      addTearDown(() {
        for (final c in [native, controlEvents, audioEvents]) {
          messenger.setMockMethodCallHandler(c, null);
        }
      });
      final player = _Player(),
          radio = Radio(deviceId: 2, macAddress: '00:00:00:00:00:01');
      ReceivePort? engine;
      Future<void> spawn(List<Object?> args) async {
        final host = args[0] as SendPort;
        engine = ReceivePort();
        engine!.listen((msg) {
          final command = (msg as Map)['cmd'];
          if (command == 'init') host.send({'evt': 'ready'});
          if (command == 'rx') {
            final bytes = (msg['bytes'] as TransferableTypedData)
                .materialize()
                .asUint8List();
            final frames = bytes[0] == 1 ? 16000 : 640;
            host.send({'evt': 'play', 'pcm': Uint8List(frames * 2)});
          }
        });
        host.send({'evt': 'port', 'port': engine!.sendPort});
      }

      final audio = RadioAudio(
        radio: radio,
        deviceId: 2,
        macAddress: radio.macAddress,
        playback: player,
        engineSpawner: spawn,
        audioReconnectDelay: (_) => const Duration(milliseconds: 100),
      );
      Map status() =>
          DataBroker.getValueDynamic(2, 'RadioAudioDiagnostics', {}) as Map;
      Future<void> rx(int kind) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          'com.htcommander/bluetooth_classic_audio',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event': 'data',
            'address': radio.macAddress,
            'data': Uint8List.fromList([kind, 2, 3]),
          }),
          (_) => done.complete(),
        );
        await done.future;
        // Let real ReceivePort messages arrive; no real platform channel is opened.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      }

      Future<void> disconnectAudioChannel() async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          'com.htcommander/bluetooth_classic_audio',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event': 'disconnected',
            'address': radio.macAddress,
            'reason': 'remote_closed',
          }),
          (_) => done.complete(),
        );
        await done.future;
      }

      try {
        await audio.start().timeout(const Duration(seconds: 4));
        expect(status()['state'], 'running');
        DataBroker.dispatch(
          deviceId: 2,
          name: androidBluetoothAudioQueueEventName,
          data: {'kind': 'overrun', 'droppedChunks': 3, 'droppedBytes': 420},
          store: false,
        );
        expect(status()['androidDroppedChunks'], 3);
        expect(status()['androidDroppedBytes'], 420);
        expect(status()['lastAndroidQueueDropAt'], isNotNull);
        expect(status()['failureReason'], 'androidQueueOverrun');
        final exported = RemoteLinkStatus.audio(status())!;
        expect(exported['androidDroppedChunks'], 3);
        expect(exported['androidDroppedBytes'], 420);
        expect(exported['failureReason'], 'androidQueueOverrun');
        DataBroker.dispatch(
          deviceId: 2,
          name: androidBluetoothAudioQueueEventName,
          data: const {'kind': 'reset'},
          store: false,
        );
        expect(status()['androidDroppedChunks'], 0);
        expect(status()['lastAndroidQueueDropAt'], isNull);
        expect(status()['failureReason'], isNull);
        await rx(1);
        expect(player.feeds, 1);
        expect(status()['bufferedMs'], 500);
        expect(status()['receivedBytes'], 3);
        await rx(1);
        expect(player.feeds, 1);
        expect(status()['droppedBlocks'], 1);
        expect(status()['droppedFrames'], 16000);
        player.drained!(0);
        player.fail = true;
        await rx(2);
        expect(player.feeds, 2);
        expect(status()['feedErrors'], 1);
        expect(status()['bufferedMs'], 0);
        expect(status()['receivedBytes'], 9);
        expect(status()['lastRxAt'], isNotNull);

        // A transient Android Classic audio-channel loss should recover while
        // audio remains enabled.
        await disconnectAudioChannel();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(calls.where((call) => call == 'connectAudio'), hasLength(2));
        expect(status()['state'], 'running');

        // Once another retry is queued, an explicit user stop cancels it.
        await disconnectAudioChannel();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        DataBroker.dispatch(
          deviceId: 2,
          name: 'SetAudio',
          data: false,
          store: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(status()['state'], 'stopped');
        expect(status()['bufferedMs'], 0);
        expect(calls.where((call) => call == 'connectAudio'), hasLength(2));
        expect(calls, contains('connectAudio'));
        expect(calls, contains('disconnectAudio'));
        expect(calls, isNot(contains('sendAudio')));
      } finally {
        await audio.dispose();
        radio.dispose();
        engine?.close();
      }
    },
  );
}
