import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/recording/rolling_voice_store.dart';
import 'package:htcommander/services/recording/rolling_voice_recorder.dart';

void main() {
  late Directory dir;
  late DateTime now;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('htc-rolling-');
    now = DateTime.utc(2026, 10, 4);
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });
  test('WAV header and exact PCM survive minute/channel/radio split', () {
    final store = RollingVoiceStore(dir, clock: () => now);
    final pcm = Uint8List.fromList([1, 0, 255, 127, 0, 128]);
    store.append(2, 'Voice', pcm);
    now = now.add(const Duration(minutes: 1));
    store.append(2, 'Voice', pcm);
    store.append(2, 'Other', pcm);
    store.append(3, 'Voice', pcm);
    store.finish();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.wav'))
        .toList();
    expect(files, hasLength(4));
    for (final f in files) {
      final bytes = f.readAsBytesSync(), header = ByteData.sublistView(bytes);
      expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
      expect(header.getUint32(24, Endian.little), 32000);
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint32(40, Endian.little), 6);
      expect(bytes.sublist(44), pcm);
    }
  });
  test('24h expiry affects only managed files; kept clip survives', () {
    final user = File('${dir.path}/my-important.wav')
      ..writeAsBytesSync([1, 2, 3]);
    final store = RollingVoiceStore(dir, clock: () => now);
    store.append(2, 'Voice', Uint8List(100));
    expect(store.preserveLatest(), 'saved');
    store.append(2, 'Voice', Uint8List(100));
    store.finish();
    now = now.add(const Duration(hours: 24, minutes: 1));
    store.maintenance();
    expect(store.snapshot()['files'], 0);
    expect(store.snapshot()['keptFiles'], 1);
    expect(user.readAsBytesSync(), [1, 2, 3]);
  });
  test(
    'disk budget reserves active minute and deletes oldest completed clips',
    () {
      final store = RollingVoiceStore(
        dir,
        clock: () => now,
        maxBytes: 8 * 1024 * 1024,
      );
      for (var minute = 0; minute < 8; minute++) {
        store.append(2, 'Voice', Uint8List(256 * 1024));
        for (var i = 0; i < 13; i++) {
          store.append(2, 'Voice', Uint8List(256 * 1024));
        }
        now = now.add(const Duration(minutes: 1));
        store.maintenance();
        expect(store.snapshot()['bytes'], lessThanOrEqualTo(8 * 1024 * 1024));
      }
      expect(store.snapshot()['files'], lessThan(8));
      expect(store.snapshot()['files'], greaterThan(0));
    },
  );
  test('partial file recovers exact even payload without appending header', () {
    final f = File(
      '${dir.path}/rx_${now.millisecondsSinceEpoch}_2_abcdef01_0.part',
    );
    f.writeAsBytesSync([...RollingVoiceStore.header(0), 1, 2, 3, 4, 5]);
    final store = RollingVoiceStore(dir, clock: () => now);
    expect(store.snapshot()['files'], 1);
    final bytes = dir.listSync().whereType<File>().single.readAsBytesSync();
    expect(bytes.length, 48);
    expect(ByteData.sublistView(bytes).getUint32(40, Endian.little), 4);
    expect(bytes.sublist(44), [1, 2, 3, 4]);
  });
  test('pin quota refuses safely; stopped idle creates no empty files', () {
    final store = RollingVoiceStore(dir, clock: () => now, maxPinnedBytes: 50);
    store.maintenance();
    expect(store.snapshot()['files'], 0);
    expect(store.preserveLatest(), 'no_recording');
    store.append(2, 'Voice', Uint8List(20));
    expect(store.preserveLatest(), 'kept_storage_full');
    expect(store.snapshot()['files'], 1);
    expect(store.snapshot()['keptFiles'], 0);
  });
  test('deleted kept files release pin budget without restarting', () {
    final store = RollingVoiceStore(dir, clock: () => now, maxPinnedBytes: 70);
    store.append(2, 'Voice', Uint8List(20));
    expect(store.preserveLatest(), 'saved');
    store.pinned.listSync().whereType<File>().single.deleteSync();
    store.append(2, 'Voice', Uint8List(20));
    expect(store.preserveLatest(), 'saved');
    expect(store.snapshot()['keptFiles'], 1);
  });
  test(
    'worker flood bounded; off-main writes finalize to valid files',
    () async {
      final state = <Map<String, Object?>>[];
      final recorder = RollingVoiceRecorder(onState: state.add);
      try {
        await recorder.start(dir.path, 24);
        final chunk = Uint8List(16384);
        var accepted = 0;
        for (var i = 0; i < 100000; i++) {
          if (recorder.append(2, 'Voice', chunk)) accepted++;
          expect(recorder.pendingBytes, lessThanOrEqualTo(512 * 1024));
        }
        expect(accepted, lessThanOrEqualTo(32));
        expect(accepted, greaterThan(0));
        await recorder.stop();
        expect(recorder.ready, false);
        expect(recorder.pendingBytes, 0);
        final files = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.wav'))
            .toList();
        expect(files, isNotEmpty);
        expect(
          files.fold<int>(0, (sum, f) => sum + f.lengthSync() - 44),
          accepted * chunk.length,
        );
      } finally {
        await recorder.stop();
      }
    },
  );
  test('rapid start stop start cancels stale workers', () async {
    final recorder = RollingVoiceRecorder(onState: (_) {});
    final a = recorder.start(dir.path, 24),
        b = recorder.stop(),
        c = recorder.start(dir.path, 1);
    await Future.wait([a, b, c]);
    expect(recorder.ready, true);
    recorder.append(2, 'Voice', Uint8List(20));
    await recorder.stop();
    expect(
      dir.listSync().whereType<File>().where((f) => f.path.endsWith('.wav')),
      hasLength(1),
    );
  });
  test('storage failure fails closed and can be restarted', () async {
    final occupied = File('${dir.path}/occupied')..writeAsStringSync('x');
    final recorder = RollingVoiceRecorder(onState: (_) {});
    await expectLater(recorder.start(occupied.path, 24), throwsStateError);
    expect(recorder.ready, false);
    await recorder.start('${dir.path}/valid', 24);
    expect(recorder.ready, true);
    await recorder.stop();
  });
}
