import 'package:flutter/material.dart';
import '../services/offline_simulation.dart';

class OfflineSimulationDialog extends StatefulWidget {
  const OfflineSimulationDialog({super.key});
  @override
  State<OfflineSimulationDialog> createState() =>
      _OfflineSimulationDialogState();
}

class _OfflineSimulationDialogState extends State<OfflineSimulationDialog> {
  final _simulation = OfflineSimulation();
  @override
  void initState() {
    super.initState();
    _simulation.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _simulation.removeListener(_changed);
    _simulation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('离线模拟 / Offline simulation'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '独立沙盒：使用合成呼号和虚拟时间，不连接电台或网络，不发送 RF/PTT/信标，不写入真实消息记录。关闭后清空演练。',
            ),
            Text(
              _simulation.connected
                  ? '模拟连接 / Simulated connected'
                  : '模拟断开 / Simulated disconnected',
            ),
            Text('虚拟 UTC：${_simulation.time.toIso8601String()}'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _simulation.connected ? null : _simulation.connect,
                  child: const Text('模拟连接'),
                ),
                OutlinedButton(
                  onPressed: _simulation.connected
                      ? _simulation.disconnect
                      : null,
                  child: const Text('模拟断开'),
                ),
                OutlinedButton(
                  onPressed: _simulation.connected
                      ? () => _simulation.createMessage()
                      : null,
                  child: const Text('新建模拟 APRS'),
                ),
                OutlinedButton(
                  onPressed: _simulation.advance,
                  child: const Text('推进 30 秒'),
                ),
                OutlinedButton(
                  onPressed: _simulation.connected
                      ? _simulation.receiveTone
                      : null,
                  child: const Text('模拟接收音频'),
                ),
              ],
            ),
            Text(
              '接收合成 1 kHz 音频块：${_simulation.rxFrames}\n标准/低带宽编码字节：${_simulation.normalBytes} / ${_simulation.lowBytes}',
            ),
            const Text('仅编码和统计，不播放声音。推进三次 30 秒可观察有限重试和超时；断开取消等待，重连不补发。'),
            for (final entry in _simulation.deliveries.reversed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${entry['id']} · ${entry['status']} · attempts ${entry['attempts']}',
                    ),
                    if (entry['status'] == 'waiting')
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: _simulation.connected
                                ? () => _simulation.reply(
                                    entry['sequence'] as String,
                                  )
                                : null,
                            child: const Text('模拟 ACK'),
                          ),
                          TextButton(
                            onPressed: _simulation.connected
                                ? () => _simulation.reply(
                                    entry['sequence'] as String,
                                    rejected: true,
                                  )
                                : null,
                            child: const Text('模拟拒收'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭 / Close'),
      ),
    ],
  );
}
