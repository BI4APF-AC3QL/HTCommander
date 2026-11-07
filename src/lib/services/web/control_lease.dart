/// Host-granted, connection-scoped ownership. Pending requests do not survive
/// reconnect, expire in two minutes, and never imply transmit permission.
class ControlLease {
  ControlLease({required this.clock});
  final DateTime Function() clock;
  int? owner;
  final _requests = <int, DateTime>{};
  List<int> get requests => _requests.keys.toList(growable: false);
  bool prune() {
    final before = _requests.length;
    final now = clock();
    _requests.removeWhere(
      (_, at) => now.difference(at) >= const Duration(minutes: 2),
    );
    return _requests.length != before;
  }

  bool request(int id) {
    prune();
    if (id <= 0) return false;
    if (owner == id || _requests.containsKey(id)) return true;
    if (_requests.length >= 8) return false;
    _requests[id] = clock();
    return true;
  }

  void grant(int id) {
    if (id <= 0) throw ArgumentError.value(id);
    owner = id;
    _requests.remove(id);
  }

  void remove(int id) {
    _requests.remove(id);
    if (owner == id) owner = null;
  }

  void recall() {
    owner = null;
    _requests.clear();
  }
}
