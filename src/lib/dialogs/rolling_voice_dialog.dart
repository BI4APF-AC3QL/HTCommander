import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/data_broker.dart';
import '../services/data_broker_client.dart';

class RollingVoiceDialog extends StatefulWidget {
  const RollingVoiceDialog({super.key});
  @override
  State<RollingVoiceDialog> createState() => _RollingVoiceDialogState();
}

class _RollingVoiceDialogState extends State<RollingVoiceDialog> {
  final _broker = DataBrokerClient();
  @override
  void initState() {
    super.initState();
    _broker.subscribeMultiple(
      deviceId: 0,
      names: ['RollingVoiceStatus', 'RollingVoiceEnabled', 'RollingVoiceHours'],
      callback: (_, _, _) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _broker.dispose();
    super.dispose();
  }

  Future<void> _exportClip(
    String folder,
    String name, {
    required bool kept,
  }) async {
    try {
      final keptPath = kept ? 'kept${Platform.pathSeparator}' : '';
      final file = File('$folder${Platform.pathSeparator}$keptPath$name');
      final bytes = await file.readAsBytes();
      await FilePicker.saveFile(
        dialogTitle: '保存接收录音',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: const ['wav'],
        bytes: bytes,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出录音失败，请稍后重试。')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        _broker.getValue<bool>(0, 'RollingVoiceEnabled', false) == true;
    final hours = (_broker.getValue<int>(0, 'RollingVoiceHours', 24) ?? 24)
        .clamp(1, 168);
    final raw = _broker.getValueDynamic(0, 'RollingVoiceStatus');
    final status = raw is Map ? raw : const {};
    final folder = status['folder'];
    final labels = {
      'android_service_failed': 'Android 前台服务未能启动，无法保证后台录音。',
      'storage_open_failed': '无法打开录音目录，请检查权限和磁盘。',
      'worker_stopped': '录音后台已退出，请关闭开关后重新开启。',
      'storage_write_failed': '录音写入失败，已停止后台录音。',
      'no_recording': '还没有可保留的接收片段。',
      'kept_storage_full': '保留片段已达到 1 GiB 上限，请先在目录整理旧文件。',
      'saved': '最新片段已移入 kept，不参与循环覆盖。',
    };
    return AlertDialog(
      title: const Text('接收语音循环录音'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用循环录音'),
                subtitle: Text(
                  '跟随当前选中的物理电台；需要先开启电台音频。',
                ),
                value: enabled,
                onChanged: (v) => DataBroker.dispatch(
                  deviceId: 0,
                  name: 'RollingVoiceEnabled',
                  data: v,
                  store: true,
                ),
              ),
              DropdownButtonFormField<int>(
                initialValue: hours,
                decoration: const InputDecoration(labelText: '保留最近时长'),
                items:
                    ({
                          ...const [1, 6, 24, 48, 168],
                          hours,
                        }.toList()..sort())
                        .map(
                          (h) =>
                              DropdownMenuItem(value: h, child: Text('$h 小时')),
                        )
                        .toList(),
                onChanged: (h) {
                  if (h != null) {
                    DataBroker.dispatch(
                      deviceId: 0,
                      name: 'RollingVoiceHours',
                      data: h,
                      store: true,
                    );
                  }
                },
              ),
              const SizedBox(height: 12),
              Text(
                status['running'] == true
                    ? '后台录音已就绪${status['active'] == true ? ' · 正在记录' : ''}'
                    : status['starting'] == true
                    ? '正在准备后台录音…'
                    : '后台录音已停止',
              ),
              Text(
                '循环片段 ${status['files'] ?? 0} · 已保留 ${status['keptFiles'] ?? 0} · 循环占用 ${((status['bytes'] as num? ?? 0) / 1024 / 1024).toStringAsFixed(1)} MiB',
              ),
              Text(
                '等待写盘 ${status['pendingBytes'] ?? 0} 字节 · 丢弃 ${status['droppedBytes'] ?? 0} 字节',
              ),
              if (labels[status['error']] != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(labels[status['error']]!),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: status['running'] == true
                        ? () => DataBroker.dispatch(
                            deviceId: 0,
                            name: 'RollingVoicePreserve',
                            data: true,
                            store: false,
                          )
                        : null,
                    child: const Text('保留最新片段'),
                  ),
                  if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android)
                    OutlinedButton(
                      onPressed: folder is String
                          ? () async {
                              final ok = await launchUrl(
                                Uri.directory(folder),
                                mode: LaunchMode.externalApplication,
                              );
                              if (!ok && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('无法打开目录，请复制下面的路径。'),
                                  ),
                                );
                              }
                            }
                          : null,
                      child: const Text('打开录音目录'),
                    ),
                ],
              ),
              if (folder is String)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SelectableText(folder),
                ),
              const Text(
                '32 kHz / 16 位 / 单声道 WAV；按分钟、信道和电台分段。只记录收到的非数据音频，静噪关闭时噪声也会记录；空闲时间不补静音，不录手机麦克风或本机发射。',
              ),
              if (!kIsWeb &&
                  defaultTargetPlatform == TargetPlatform.android) ...[
                const SizedBox(height: 8),
                const Text('录音开启时 Android 会显示常驻服务通知并保持后台处理，耗电会增加。关闭录音后服务通知会随其他服务状态一并结束。'),
              ],
              const SizedBox(height: 8),
              const Text(
                '默认最近 24 小时，循环目录最多 6 GiB，先达到的限制生效。旧片段自动删除；kept 中的保留片段最多 1 GiB，不自动覆盖。录音只保存在本机。',
              ),
              const Divider(),
              const Text('最近完成的片段'),
              for (final item
                  in (status['recent'] is List
                          ? status['recent'] as List
                          : const [])
                      .whereType<Map>())
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${item['kept'] == true ? '已保留 · ' : ''}${item['name']} · ${((item['bytes'] as num? ?? 0) / 1024).toStringAsFixed(0)} KiB',
                        ),
                      ),
                      if (!kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android &&
                          folder is String &&
                          item['name'] is String)
                        IconButton(
                          tooltip: '导出 WAV',
                          onPressed: () =>
                              _exportClip(
                                folder,
                                item['name'] as String,
                                kept: item['kept'] == true,
                              ),
                          icon: const Icon(Icons.save_alt),
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
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
