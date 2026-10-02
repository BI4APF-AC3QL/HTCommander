import 'aprs_events.dart';

/// Bounded live station positions. Old history cannot replace a newer fix.
class StationIndex {
  StationIndex({
    required this.clock,
    this.capacity = 512,
    this.trackLimit = 16,
  }) {
    if (capacity < 1 || trackLimit < 1) {
      throw ArgumentError('Invalid map limits');
    }
  }
  final DateTime Function() clock;
  final int capacity, trackLimit;
  final Map<String, Map<String, Object>> _stations = {};
  final Map<String, List<(DateTime, double, double, bool)>> _fixes = {};
  void clear() {
    _stations.clear();
    _fixes.clear();
  }

  void prune() {
    final cutoff = clock().subtract(const Duration(hours: 24));
    for (final call in _fixes.keys.toList()) {
      final count = _fixes[call]!.length;
      _fixes[call]!.removeWhere((fix) => fix.$1.isBefore(cutoff));
      if (_fixes[call]!.isEmpty) {
        _fixes.remove(call);
        _stations.remove(call);
      } else if (_fixes[call]!.length != count) {
        _refresh(call);
      }
    }
  }

  /// Merge persisted positions without replacing a newer live fix. This only
  /// builds a view; it never publishes an AprsFrame or requests transmission.
  void restore(Iterable<AprsFrameEventArgs> events) {
    final ordered = events.toList()
      ..sort((a, b) => a.ax25Packet.time.compareTo(b.ax25Packet.time));
    for (final event in ordered) {
      add(event, historical: true);
    }
  }

  void _refresh(String call) {
    final fixes = _fixes[call]!;
    final last = fixes.last;
    final track = <List<double>>[];
    for (final fix in fixes) {
      if (track.isEmpty || track.last[0] != fix.$2 || track.last[1] != fix.$3) {
        track.add([fix.$2, fix.$3]);
      }
    }
    _stations[call] = {
      'call': call,
      'lat': last.$2,
      'lon': last.$3,
      'time': last.$1.toUtc().toIso8601String(),
      'track': track,
      'viaInternet': last.$4,
    };
  }

  bool add(AprsFrameEventArgs event, {bool historical = false}) {
    final packet = event.aprsPacket;
    final coordinates = packet.position.coordinateSet;
    final lat = coordinates.latitude.value, lon = coordinates.longitude.value;
    if (!packet.position.isValid() ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return false;
    }
    final call = packet.sourceCallsignWithId.toUpperCase();
    if (call.isEmpty) return false;
    prune();
    final time = event.ax25Packet.time;
    if (time.isAfter(clock().add(const Duration(minutes: 5))) ||
        clock().difference(time) > const Duration(hours: 24)) {
      return false;
    }
    final fixes = _fixes[call] ?? [];
    if (fixes.any((fix) => fix.$1.isAtSameMomentAs(time)) ||
        (!historical && fixes.isNotEmpty && !time.isAfter(fixes.last.$1)) ||
        (fixes.length >= trackLimit && !time.isAfter(fixes.first.$1))) {
      return false;
    }
    fixes.add((time, lat, lon, packet.fromAprsIs));
    fixes.sort((a, b) => a.$1.compareTo(b.$1));
    while (fixes.length > trackLimit) {
      fixes.removeAt(0);
    }
    _fixes[call] = fixes;
    _refresh(call);
    while (_stations.length > capacity) {
      final oldest = _fixes.keys.reduce(
        (a, b) => _fixes[a]!.last.$1.isBefore(_fixes[b]!.last.$1) ? a : b,
      );
      _stations.remove(oldest);
      _fixes.remove(oldest);
    }
    return _stations.containsKey(call);
  }

  List<Map<String, Object>> get stations {
    prune();
    return _stations.values
        .map(
          (e) => {
            ...e,
            'track': (e['track'] as List<List<double>>)
                .map((point) => List<double>.from(point))
                .toList(),
          },
        )
        .toList();
  }
}
