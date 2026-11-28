import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/web/remote_media.dart';
import 'package:htcommander/services/web/web_server_io.dart';

Int16List tone(int rate, int frames, double hz, {int channels = 1}) =>
    Int16List.fromList(
      List.generate(
        frames * channels,
        (i) => (12000 * math.sin(2 * math.pi * hz * (i ~/ channels) / rate))
            .round(),
      ),
    );

List<int> samples(Uint8List packet) {
  final data = ByteData.sublistView(packet);
  return [
    for (var i = 4; i < packet.length; i += 2) data.getInt16(i, Endian.little),
  ];
}

double rms(List<int> values) => math.sqrt(
  values.fold<double>(0, (sum, value) => sum + value * value) / values.length,
);

void main() {
  test('32 kHz mono and stereo measured receive payload savings', () {
    for (final channels in [1, 2]) {
      final pcm = tone(32000, 32000, 1000, channels: channels);
      final normal = RemoteReceiveEncoder.normal(pcm, 32000, channels)!;
      final low = RemoteReceiveEncoder().low(pcm, 32000, channels)!;
      expect(normal.length, 4 + 64000 * channels);
      expect(low.length, 16004);
      expect(low.sublist(0, 4), [241, 1, 64, 31]);
      expect(low.length / normal.length, lessThan(channels == 1 ? .251 : .126));
      expect(
        rms(samples(low).skip(50).toList()),
        closeTo(12000 / math.sqrt(2), 80),
      );
    }
  });

  test('voice tone is preserved and high tones do not alias into voice', () {
    for (final rate in [16000, 32000, 44100, 48000]) {
      final voice = samples(
        RemoteReceiveEncoder().low(tone(rate, rate, 1000), rate, 1)!,
      );
      final high = samples(
        RemoteReceiveEncoder().low(tone(rate, rate, 6000), rate, 1)!,
      );
      final v = rms(voice.skip(100).toList()), h = rms(high.skip(100).toList());
      expect(v, closeTo(12000 / math.sqrt(2), 100), reason: '$rate voice');
      expect(h / v, lessThan(.01), reason: '$rate stopband');
    }
  });

  test(
    'arbitrary block boundaries including tiny 44.1 kHz blocks preserve time',
    () {
      for (final rate in [8000, 16000, 32000, 44100, 48000]) {
        final pcm = tone(rate, rate, 1000);
        final expected = samples(RemoteReceiveEncoder().low(pcm, rate, 1)!);
        final encoder = RemoteReceiveEncoder();
        final actual = <int>[];
        var offset = 0, block = 1;
        while (offset < pcm.length) {
          final end = math.min(offset + block, pcm.length);
          final packet = encoder.low(
            Int16List.sublistView(pcm, offset, end),
            rate,
            1,
          );
          if (packet != null) actual.addAll(samples(packet));
          offset = end;
          block = block == 137 ? 1 : block + 1;
        }
        expect(actual, expected, reason: '$rate chunks');
        expect(actual, hasLength(8000));
      }
    },
  );

  test(
    'subviews, stereo mixing, invalid blocks and changed format are bounded',
    () {
      final input = Int16List.fromList([999, -32768, 32767, 1, -1, 999]);
      final view = Int16List.sublistView(input, 1, 5);
      expect(samples(RemoteReceiveEncoder.normal(view, 8000, 2)!), [
        -32768,
        32767,
        1,
        -1,
      ]);
      expect(samples(RemoteReceiveEncoder().low(view, 8000, 2)!), [-1, 0]);
      final encoder = RemoteReceiveEncoder();
      encoder.low(tone(32000, 800, 1000), 32000, 1);
      final silence = Int16List(44100);
      expect(samples(encoder.low(silence, 44100, 1)!), everyElement(0));
      for (final args in [
        (Int16List(1), 7999, 1),
        (Int16List(1), 48001, 1),
        (Int16List(1), 32000, 3),
        (Int16List(3), 32000, 2),
        (Int16List(0), 32000, 1),
        (Int16List(32001), 32000, 1),
      ]) {
        expect(encoder.low(args.$1, args.$2, args.$3), isNull);
        expect(RemoteReceiveEncoder.normal(args.$1, args.$2, args.$3), isNull);
      }
      encoder.reset();
      expect(
        samples(encoder.low(Int16List(32000), 32000, 1)!),
        everyElement(0),
      );
    },
  );

  test(
    'read-only preference accepts only a boolean and cannot change permissions',
    () {
      for (final value in [true, false]) {
        expect(
          WebServer.readOnlyMessageAllowed(
            'remote:{"op":"media","lowBandwidth":$value}',
          ),
          true,
        );
      }
      for (final command in [
        '{"op":"media"}',
        '{"op":"media","lowBandwidth":1}',
        '{"op":"media","lowBandwidth":true,"AllowTransmit":1}',
        '{"op":"media","lowBandwidth":null}',
      ]) {
        expect(WebServer.readOnlyMessageAllowed('remote:$command'), false);
      }
    },
  );
}
