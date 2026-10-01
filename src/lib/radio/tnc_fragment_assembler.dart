import 'dart:typed_data';
import 'tnc_data_fragment.dart';

/// Reassembles complete, contiguous TNC packets. A missing fragment must never
/// turn the remaining tail into a supposedly valid packet.
class TncFragmentAssembler {
  TncFragmentAssembler({
    this.maxBytes = 65536,
    this.maxAge = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final int maxBytes;
  final Duration maxAge;
  final DateTime Function() _clock;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  TncDataFragment? _first;
  TncDataFragment? _last;
  DateTime? _started;
  int rejectedPackets = 0;
  int duplicateFragments = 0;

  void reset() {
    _bytes.clear();
    _first = null;
    _last = null;
    _started = null;
  }

  TncDataFragment? add(TncDataFragment fragment) {
    final now = _clock();
    if (_started != null && now.difference(_started!) > maxAge) {
      rejectedPackets++;
      reset();
    }
    if (_last != null &&
        fragment.fragmentId == _last!.fragmentId &&
        fragment.channelId == _last!.channelId &&
        _sameBytes(fragment.data, _last!.data)) {
      duplicateFragments++;
      return null;
    }
    if (fragment.fragmentId == 0) {
      if (_first != null) rejectedPackets++;
      reset();
      _first = fragment;
      _started = now;
    } else if (_last == null ||
        fragment.fragmentId != _last!.fragmentId + 1 ||
        (_first!.channelId >= 0 &&
            fragment.channelId >= 0 &&
            _first!.channelId != fragment.channelId)) {
      rejectedPackets++;
      reset();
      return null;
    }
    if (_bytes.length + fragment.data.length > maxBytes) {
      rejectedPackets++;
      reset();
      return null;
    }
    // Own the bytes: transports and callers can reuse their input buffers.
    _bytes.add(Uint8List.fromList(fragment.data));
    _last = fragment;
    if (!fragment.finalFragment) return null;
    final first = _first!;
    final result = TncDataFragment(
      finalFragment: true,
      fragmentId: fragment.fragmentId,
      data: _bytes.takeBytes(),
      channelId: first.channelId,
      regionId: first.regionId,
      channelName: first.channelName,
      incoming: first.incoming,
      time: first.time,
      encoding: first.encoding,
      frameType: first.frameType,
      corrections: first.corrections,
      radioMac: first.radioMac,
      radioDeviceId: first.radioDeviceId,
      usage: first.usage,
    );
    reset();
    return result;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
