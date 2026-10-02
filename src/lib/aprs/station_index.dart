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
  void prune() => _stations.removeWhere(
    (_, e) =>
        clock().difference(DateTime.parse(e['time'] as String)) >
        const Duration(hours: 24),
  );
  bool add(AprsFrameEventArgs event) {
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
    final previous = _stations[call];
    if (previous != null &&
        !time.isAfter(DateTime.parse(previous['time'] as String))) {
      return false;
    }
    final track = previous == null
        ? <List<double>>[]
        : List<List<double>>.from(previous['track'] as List);
    if (track.isEmpty || track.last[0] != lat || track.last[1] != lon) {
      track.add([lat, lon]);
    }
    while (track.length > trackLimit) {
      track.removeAt(0);
    }
    _stations.remove(call);
    while (_stations.length >= capacity) {
      _stations.remove(_stations.keys.first);
    }
    _stations[call] = {
      'call': call,
      'lat': lat,
      'lon': lon,
      'time': time.toIso8601String(),
      'track': track,
      'viaInternet': packet.fromAprsIs,
    };
    return true;
  }

  List<Map<String, Object>> get stations {
    prune();
    return _stations.values.map((e) => Map<String, Object>.from(e)).toList();
  }
}
