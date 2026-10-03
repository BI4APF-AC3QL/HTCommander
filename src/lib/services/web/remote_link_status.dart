import '../data_broker.dart';

/// Explicit allowlists keep transport observations safe for the phone/export.
class RemoteLinkStatus {
  static Map<String, Object?> snapshot(int radioId) => {
    'control': radioId <= 1 || radioId == 201
        ? null
        : control(
            DataBroker.getValueDynamic(radioId, 'RadioLinkDiagnostics', null),
          ),
    'audio': radioId <= 1 || radioId == 201
        ? null
        : audio(
            DataBroker.getValueDynamic(radioId, 'RadioAudioDiagnostics', null),
          ),
  };

  static Map<String, Object?>? control(Object? value) {
    if (value is! Map) return null;
    return {
      'connected': value['connected'] is bool ? value['connected'] : null,
      for (final key in ['sampleAt', 'lastRxAt']) key: _time(value[key]),
      for (final key in [
        'rxBytes',
        'commandsReceived',
        'framingSkippedBytes',
        'writes',
        'writeFailures',
        'pendingWrites',
        'queuedReads',
        'queuedTncFragments',
        'readReplies',
        'readTimeouts',
        'readRetries',
        'abandonedReads',
      ])
        key: _count(value[key]),
      'failureReason':
          const [
            'disconnected',
            'unableToConnect',
            'disposed',
            'writeFailed',
            'readTimeout',
          ].contains(value['failureReason'])
          ? value['failureReason']
          : null,
      for (final key in ['writeDelay', 'replyDelay']) key: _delay(value[key]),
    };
  }

  static Map<String, Object?>? audio(Object? value) {
    if (value is! Map) return null;
    return {
      'state':
          const ['stopped', 'connecting', 'running'].contains(value['state'])
          ? value['state']
          : null,
      for (final key in ['sampleAt', 'lastRxAt', 'lastPcmAt'])
        key: _time(value[key]),
      for (final key in [
        'bufferedMs',
        'peakBufferedMs',
        'droppedFrames',
        'droppedBlocks',
        'feedErrors',
        'invalidDrainReports',
        'receivedBytes',
      ])
        key: _count(value[key]),
      'failureReason':
          const [
            'playbackBacklog',
            'playbackFeedFailed',
            'audioStreamError',
            'audioConnectFailed',
            'audioStartFailed',
            'audioDisconnected',
          ].contains(value['failureReason'])
          ? value['failureReason']
          : null,
    };
  }

  static int? _count(Object? value) =>
      value is int && value >= 0 && value <= 9007199254740991 ? value : null;
  static String? _time(Object? value) {
    if (value is! String || value.length > 40) return null;
    return DateTime.tryParse(value)?.toUtc().toIso8601String();
  }

  static Map<String, Object?>? _delay(Object? value) => value is Map
      ? {
          'samples': _count(value['samples']),
          for (final key in ['lastMs', 'medianMs', 'maxMs'])
            key: _count(value[key]),
        }
      : null;

  static List<String> describe(Map<String, Object?> status) {
    final c = status['control'] as Map?, a = status['audio'] as Map?;
    String count(Object? value) => value is int ? '$value' : '未知 / unknown';
    String delay(Object? value) => value is Map
        ? '${count(value['lastMs'])} / ${count(value['medianMs'])} / ${count(value['maxMs'])} ms（${count(value['samples'])}）'
        : '未知 / unknown';
    const reasons = {
      'disconnected': '控制通道已断开',
      'unableToConnect': '控制通道连接失败',
      'disposed': '电台已释放',
      'writeFailed': '控制写入失败',
      'readTimeout': '读取响应超时',
      'playbackBacklog': '本机播放积压',
      'playbackFeedFailed': '本机播放写入失败',
      'audioStreamError': '音频接收流错误',
      'audioConnectFailed': '音频通道连接失败',
      'audioStartFailed': '音频初始化失败',
      'audioDisconnected': '音频通道已断开',
    };
    return [
      '控制通道 / Control: ${c?['connected'] == true
          ? '已连接 / connected'
          : c?['connected'] == false
          ? '已断开 / disconnected'
          : '未知 / unknown'}',
      '控制接收字节 / RX bytes: ${count(c?['rxBytes'])} · 命令 / commands: ${count(c?['commandsReceived'])}',
      '写入等待/完成延迟 / Write last/median/max: ${delay(c?['writeDelay'])}',
      '读取往返 / Read last/median/max: ${delay(c?['replyDelay'])}',
      '待写 / Pending: ${count(c?['pendingWrites'])} · 读取队列 / Read queue: ${count(c?['queuedReads'])} · TNC fragments: ${count(c?['queuedTncFragments'])}',
      '写入失败 / Write failures: ${count(c?['writeFailures'])} · 读取超时/重试/放弃: ${count(c?['readTimeouts'])}/${count(c?['readRetries'])}/${count(c?['abandonedReads'])}',
      '同步跳过字节 / Framing resync bytes: ${count(c?['framingSkippedBytes'])}',
      '最近控制接收 / Last control RX: ${c?['lastRxAt'] ?? '未知 / unknown'}',
      '本机音频 / Host audio: ${a?['state'] ?? '未知 / unknown'} · 积压/峰值 / Backlog/peak: ${count(a?['bufferedMs'])}/${count(a?['peakBufferedMs'])} ms',
      '播放丢弃块/帧 / Dropped playback blocks/frames: ${count(a?['droppedBlocks'])}/${count(a?['droppedFrames'])} · 播放错误 / Feed errors: ${count(a?['feedErrors'])}',
      '音频接收字节 / Audio RX bytes: ${count(a?['receivedBytes'])} · 最近接收 / Last RX: ${a?['lastRxAt'] ?? '未知 / unknown'}',
      '最近故障 / Last failure: ${reasons[a?['failureReason']] ?? reasons[c?['failureReason']] ?? '无已记录原因 / none recorded'}',
    ];
  }
}
