import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/recording/wav_clip_writer.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('htc-wav-writer-');
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  test('writes ordered PCM and patches a valid WAV header asynchronously', () async {
    final path = '${directory.path}${Platform.pathSeparator}clip.wav';
    final writer = WavClipWriter.open(path, 32000)!;
    final first = Uint8List.fromList([1, 2, 3, 4]);
    final second = Uint8List.fromList([5, 6, 7, 8]);

    expect(writer.write(first, 0, first.length), isTrue);
    expect(writer.write(second, 0, second.length), isTrue);
    first.fillRange(0, first.length, 0);

    final result = await writer.close();
    final file = File(path).readAsBytesSync();
    final header = ByteData.sublistView(file);

    expect(result.dataBytes, 8);
    expect(result.droppedBytes, 0);
    expect(result.failed, isFalse);
    expect(file.length, 52);
    expect(String.fromCharCodes(file.sublist(0, 4)), 'RIFF');
    expect(header.getUint32(4, Endian.little), 44);
    expect(String.fromCharCodes(file.sublist(8, 12)), 'WAVE');
    expect(header.getUint32(24, Endian.little), 32000);
    expect(header.getUint32(40, Endian.little), 8);
    expect(file.sublist(44), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  test('bounds pending audio instead of growing an unbounded write queue', () async {
    final path = '${directory.path}${Platform.pathSeparator}bounded.wav';
    final writer = WavClipWriter.open(path, 32000)!;
    final half = WavClipWriter.maxPendingBytes ~/ 2;
    final first = Uint8List(half)..fillRange(0, half, 0x11);
    final second = Uint8List(half)..fillRange(0, half, 0x22);
    final overflow = Uint8List(half)..fillRange(0, half, 0x33);

    expect(writer.write(first, 0, first.length), isTrue);
    expect(writer.write(second, 0, second.length), isTrue);
    expect(writer.write(overflow, 0, overflow.length), isFalse);
    expect(writer.pendingBytes, WavClipWriter.maxPendingBytes);
    expect(writer.droppedBytes, half);

    final result = await writer.close();
    final file = File(path).readAsBytesSync();
    expect(result.dataBytes, WavClipWriter.maxPendingBytes);
    expect(result.droppedBytes, half);
    expect(result.failed, isFalse);
    expect(file.length, 44 + WavClipWriter.maxPendingBytes);
    expect(file[44], 0x11);
    expect(file[44 + half], 0x22);
    expect(file.last, 0x22);
  });
}
