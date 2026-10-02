/// Bounded APRS delivery state. The caller owns transmission and must recheck
/// permissions before dispatching each retry. A dispatch is not proof of RF TX.
enum DeliveryStatus { waiting, acknowledged, rejected, timedOut, cancelled }

class MessageDelivery {
  final String id;
  final String source;
  final String destination;
  final String sequence;
  final DateTime created;
  DateTime due;
  int attempts = 1;
  DeliveryStatus status = DeliveryStatus.waiting;

  MessageDelivery(
    this.id,
    this.source,
    this.destination,
    this.sequence,
    this.created,
    this.due,
  );

  bool get pending => status == DeliveryStatus.waiting;

  Map<String, Object> toJson() => {
    'id': id,
    'source': source,
    'destination': destination,
    'sequence': sequence,
    'created': created.toIso8601String(),
    'attempts': attempts,
    'status': status.name,
  };
}

class MessageDeliveryTracker {
  final DateTime Function() clock;
  final Duration retryInterval;
  final int maxAttempts;
  final int capacity;
  final List<MessageDelivery> _entries = [];

  MessageDeliveryTracker({
    required this.clock,
    this.retryInterval = const Duration(seconds: 30),
    this.maxAttempts = 3,
    this.capacity = 100,
  }) {
    if (maxAttempts < 1 || capacity < 1 || retryInterval <= Duration.zero) {
      throw ArgumentError('Invalid delivery limits');
    }
  }

  List<MessageDelivery> get entries => List.unmodifiable(_entries);

  MessageDelivery start(
    String id,
    String source,
    String destination,
    String sequence,
  ) {
    if (id.isEmpty ||
        sequence.isEmpty ||
        source.isEmpty ||
        destination.isEmpty) {
      throw ArgumentError('Missing message identity');
    }
    if (_entries.any(
      (e) =>
          e.id == id ||
          (e.pending &&
              e.source == source.toUpperCase() &&
              e.destination == destination.toUpperCase() &&
              e.sequence == sequence),
    )) {
      throw StateError('Message identity already in use');
    }
    if (_entries.length >= capacity) {
      final index = _entries.indexWhere((e) => !e.pending);
      if (index < 0) throw StateError('Outbox full');
      _entries.removeAt(index);
    }
    final now = clock();
    final entry = MessageDelivery(
      id,
      source.toUpperCase(),
      destination.toUpperCase(),
      sequence,
      now,
      now.add(retryInterval),
    );
    _entries.add(entry);
    return entry;
  }

  bool acknowledge(
    String sender,
    String addressee,
    String sequence, {
    bool rejected = false,
  }) {
    String normalize(String value) =>
        value.trim().toUpperCase().replaceFirst(RegExp(r'-0$'), '');
    for (final entry in _entries) {
      if (entry.pending &&
          normalize(entry.destination) == normalize(sender) &&
          normalize(entry.source) == normalize(addressee) &&
          entry.sequence == sequence) {
        entry.status = rejected
            ? DeliveryStatus.rejected
            : DeliveryStatus.acknowledged;
        return true;
      }
    }
    return false;
  }

  /// Returns retry candidates once per interval; caller must dispatch the
  /// original frame/sequence, never allocate a fresh APRS message ID.
  List<MessageDelivery> tick({
    required bool Function(MessageDelivery) allowed,
  }) {
    final now = clock();
    final retries = <MessageDelivery>[];
    for (final entry in _entries) {
      if (!entry.pending) continue;
      if (!allowed(entry)) {
        entry.status = DeliveryStatus.cancelled;
      } else if (!now.isBefore(entry.due)) {
        if (entry.attempts >= maxAttempts) {
          entry.status = DeliveryStatus.timedOut;
        } else {
          entry.attempts++;
          entry.due = now.add(retryInterval);
          retries.add(entry);
        }
      }
    }
    return retries;
  }

  void cancelAll() {
    for (final entry in _entries) {
      if (entry.pending) entry.status = DeliveryStatus.cancelled;
    }
  }
}
