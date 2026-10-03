/// Bounded software observations of the control transport. Neither framing
/// skips nor read timeouts measure RF packet loss or Bluetooth signal quality.
class RadioLinkDiagnostics {
  RadioLinkDiagnostics({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  int generation = 0;
  bool connected = false;
  int rxBytes = 0, commandsReceived = 0, framingSkippedBytes = 0;
  int writes = 0, writeFailures = 0, pendingWrites = 0;
  int readReplies = 0, readTimeouts = 0, readRetries = 0, abandonedReads = 0;
  DateTime? lastRxAt;
  String? failureReason;
  final _writeMs = <int>[], _replyMs = <int>[];

  void start() {
    generation++;
    connected = true;
    rxBytes = commandsReceived = framingSkippedBytes = writes = writeFailures =
        pendingWrites = 0;
    readReplies = readTimeouts = readRetries = abandonedReads = 0;
    lastRxAt = null;
    failureReason = null;
    _writeMs.clear();
    _replyMs.clear();
  }

  void stop(String reason) {
    generation++;
    connected = false;
    pendingWrites = 0;
    failureReason =
        const ['disconnected', 'unableToConnect', 'disposed'].contains(reason)
        ? reason
        : 'disconnected';
  }

  void received(int count) {
    if (!connected || count <= 0) return;
    rxBytes += count;
    lastRxAt = _clock().toUtc();
  }

  int beginWrite() {
    if (!connected) return generation;
    writes++;
    pendingWrites++;
    return generation;
  }

  void endWrite(int ticket, Duration elapsed, bool ok) {
    if (ticket != generation || !connected) return;
    if (pendingWrites > 0) pendingWrites--;
    _observe(_writeMs, elapsed);
    if (!ok) {
      writeFailures++;
      failureReason = 'writeFailed';
    }
  }

  void readReply(Duration? elapsed) {
    readReplies++;
    if (elapsed != null) _observe(_replyMs, elapsed);
  }

  void timeout({required bool retry}) {
    readTimeouts++;
    if (retry) {
      readRetries++;
    } else {
      abandonedReads++;
    }
    failureReason = 'readTimeout';
  }

  static void _observe(List<int> values, Duration elapsed) {
    final ms = elapsed.inMilliseconds;
    if (ms < 0 || ms > 60000) return;
    values.add(ms);
    if (values.length > 32) values.removeAt(0);
  }

  static Map<String, Object?> _latency(List<int> values) {
    if (values.isEmpty) {
      return {'samples': 0, 'lastMs': null, 'medianMs': null, 'maxMs': null};
    }
    final sorted = List<int>.of(values)..sort();
    return {
      'samples': values.length,
      'lastMs': values.last,
      'medianMs': sorted[sorted.length ~/ 2],
      'maxMs': sorted.last,
    };
  }

  Map<String, Object?> snapshot({
    required int queuedReads,
    required int queuedTncFragments,
  }) => {
    'sampleAt': _clock().toUtc().toIso8601String(),
    'connected': connected,
    'rxBytes': rxBytes,
    'commandsReceived': commandsReceived,
    'framingSkippedBytes': framingSkippedBytes,
    'writes': writes,
    'writeFailures': writeFailures,
    'pendingWrites': pendingWrites,
    'queuedReads': queuedReads,
    'queuedTncFragments': queuedTncFragments,
    'readReplies': readReplies,
    'readTimeouts': readTimeouts,
    'readRetries': readRetries,
    'abandonedReads': abandonedReads,
    'lastRxAt': lastRxAt?.toIso8601String(),
    'failureReason': failureReason,
    'writeDelay': _latency(_writeMs),
    'replyDelay': _latency(_replyMs),
  };
}

/// Accounting for the production 32 kHz mono playback sink. Drain epochs
/// prevent a failed asynchronous feed from subtracting from a newer native
/// buffer observation. No samples, addresses or exception messages are stored.
class RadioAudioDiagnostics {
  RadioAudioDiagnostics({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;
  static const sampleRate = 32000, maxBufferedFrames = 25600;
  int bufferedFrames = 0, peakBufferedFrames = 0;
  int droppedFrames = 0,
      droppedBlocks = 0,
      feedErrors = 0,
      invalidDrainReports = 0;
  int receivedBytes = 0, _drainEpoch = 0, _generation = 0;
  DateTime? lastRxAt, lastPcmAt;
  String state = 'stopped';
  String? failureReason;

  void start() {
    bufferedFrames = peakBufferedFrames = droppedFrames = droppedBlocks =
        feedErrors = invalidDrainReports = receivedBytes = 0;
    _drainEpoch++;
    _generation++;
    lastRxAt = lastPcmAt = null;
    failureReason = null;
    state = 'connecting';
  }

  void resetBuffer() {
    bufferedFrames = 0;
    _drainEpoch++;
    _generation++;
  }

  void stop() {
    state = 'stopped';
    resetBuffer();
  }

  void received(int bytes) {
    if (bytes > 0) {
      receivedBytes += bytes;
      lastRxAt = _clock().toUtc();
    }
  }

  void drained(int frames) {
    if (state == 'stopped') return;
    if (frames < 0 || frames > sampleRate * 8) {
      invalidDrainReports++;
      return;
    }
    bufferedFrames = frames;
    _drainEpoch++;
    if (frames > peakBufferedFrames) peakBufferedFrames = frames;
  }

  /// Null means the source chunk was dropped. Otherwise returns a drain epoch
  /// used to reconcile a feed failure against the same native observation.
  ({int generation, int epoch})? reserve(int frames) {
    if (frames <= 0 || state == 'stopped') return null;
    if (frames > sampleRate || bufferedFrames + frames > maxBufferedFrames) {
      droppedFrames += frames;
      droppedBlocks++;
      failureReason = 'playbackBacklog';
      return null;
    }
    bufferedFrames += frames;
    lastPcmAt = _clock().toUtc();
    if (bufferedFrames > peakBufferedFrames) {
      peakBufferedFrames = bufferedFrames;
    }
    return (generation: _generation, epoch: _drainEpoch);
  }

  void failed(({int generation, int epoch}) ticket, int frames) {
    if (ticket.generation != _generation) return;
    feedErrors++;
    failureReason = 'playbackFeedFailed';
    if (ticket.epoch == _drainEpoch) {
      bufferedFrames = (bufferedFrames - frames).clamp(0, sampleRate * 8);
    }
  }

  Map<String, Object?> get snapshot => {
    'sampleAt': _clock().toUtc().toIso8601String(),
    'state': state,
    'failureReason': failureReason,
    'bufferedMs': bufferedFrames * 1000 ~/ sampleRate,
    'peakBufferedMs': peakBufferedFrames * 1000 ~/ sampleRate,
    'droppedFrames': droppedFrames,
    'droppedBlocks': droppedBlocks,
    'feedErrors': feedErrors,
    'invalidDrainReports': invalidDrainReports,
    'receivedBytes': receivedBytes,
    'lastRxAt': lastRxAt?.toIso8601String(),
    'lastPcmAt': lastPcmAt?.toIso8601String(),
  };
}
