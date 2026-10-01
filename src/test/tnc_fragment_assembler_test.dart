import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/radio/tnc_data_fragment.dart';
import 'package:htcommander/radio/tnc_fragment_assembler.dart';
import 'package:htcommander/radio/read_timing.dart';

TncDataFragment f(
  int id,
  List<int> bytes, {
  bool last = false,
  int channel = 3,
}) => TncDataFragment(
  finalFragment: last,
  fragmentId: id,
  data: Uint8List.fromList(bytes),
  channelId: channel,
  regionId: 2,
);

void main() {
  test(
    'chunked and duplicate fragments preserve a complete packet exactly once',
    () {
      final a = TncFragmentAssembler();
      expect(a.add(f(0, [1, 2])), isNull);
      expect(a.add(f(0, [1, 2])), isNull);
      expect(a.add(f(1, [3, 4])), isNull);
      final packet = a.add(f(2, [5], last: true));
      expect(packet!.data, [1, 2, 3, 4, 5]);
      expect(packet.channelId, 3);
      expect(a.duplicateFragments, 1);
      expect(a.add(f(2, [5], last: true)), isNull);
    },
  );
  test('a missing middle fragment never delivers a truncated tail', () {
    final a = TncFragmentAssembler();
    a.add(f(0, [1]));
    expect(a.add(f(2, [3], last: true)), isNull);
    expect(a.add(f(3, [4], last: true)), isNull);
    expect(a.add(f(0, [8], last: true))!.data, [8]);
    expect(a.rejectedPackets, 2);
  });
  test(
    'channel changes, stale chains and size overflow recover on next start',
    () {
      var now = DateTime(2026);
      final a = TncFragmentAssembler(maxBytes: 3, clock: () => now);
      a.add(f(0, [1]));
      expect(a.add(f(1, [2], last: true, channel: 4)), isNull);
      a.add(f(0, [1]));
      now = now.add(const Duration(seconds: 11));
      expect(a.add(f(1, [2], last: true)), isNull);
      a.add(f(0, [1, 2]));
      expect(a.add(f(1, [3, 4], last: true)), isNull);
      expect(a.add(f(0, [7], last: true))!.data, [7]);
    },
  );
  test('adaptive read budgets expand for slow replies and remain bounded', () {
    final t = ReadTiming();
    expect(t.budget(0).inMilliseconds, greaterThanOrEqualTo(1000));
    final initial = t.budget(0);
    for (var i = 0; i < 10; i++) {
      t.observe(const Duration(seconds: 2));
    }
    expect(t.budget(0), greaterThan(initial));
    expect(t.budget(2).inMilliseconds, lessThanOrEqualTo(5000));
    expect(t.budget(2), greaterThanOrEqualTo(t.budget(0)));
  });
  test('truncated wire fragments fail before indexed byte access', () {
    expect(
      () => TncDataFragment.fromBytes(Uint8List(5)),
      throwsFormatException,
    );
    expect(
      () =>
          TncDataFragment.fromBytes(Uint8List.fromList([0, 0, 0, 0, 0, 0x40])),
      throwsFormatException,
    );
  });
}
