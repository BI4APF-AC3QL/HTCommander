import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/data_broker.dart';
import '../services/data_broker_client.dart';
import '../services/web/remote_link_status.dart';

class LinkDiagnosticsDialog extends StatefulWidget {
  const LinkDiagnosticsDialog({super.key});
  @override
  State<LinkDiagnosticsDialog> createState() => _LinkDiagnosticsDialogState();
}

class _LinkDiagnosticsDialogState extends State<LinkDiagnosticsDialog> {
  final _broker = DataBrokerClient();
  @override
  void initState() {
    super.initState();
    _broker.subscribeMultiple(
      deviceId: DataBroker.allDevices,
      names: [
        'RadioLinkDiagnostics',
        'RadioAudioDiagnostics',
        'ConnectedRadios',
        'SelectedRadioDeviceId',
      ],
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

  int get _radioId {
    final radios =
        (DataBroker.getValueDynamic(1, 'ConnectedRadios', []) as List)
            .whereType<Map>()
            .map((r) => r['DeviceId'])
            .whereType<int>()
            .where((id) => id > 1 && id != 201)
            .toList();
    final selected = DataBroker.getValue<int>(1, 'SelectedRadioDeviceId', -1);
    return radios.contains(selected) ? selected! : radios.firstOrNull ?? -1;
  }

  @override
  Widget build(BuildContext context) {
    final data = RemoteLinkStatus.snapshot(_radioId);
    return AlertDialog(
      title: const Text('链路诊断 / Link diagnostics'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in RemoteLinkStatus.describe(data))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SelectableText(line),
                ),
              const Text(
                '每秒汇总一次，只统计本次连接。延迟包括主机排队和运输完成；读取时间包括排队到匹配响应，仅未重试样本参与。播放积压是本机缓冲估计。同步字节、超时与丢弃不能换算为射频丢包率；网页刷新时间不是电台报告时间。未知显示 unknown。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(
            ClipboardData(
              text: const JsonEncoder.withIndent('  ').convert(data),
            ),
          ),
          child: const Text('复制脱敏诊断 JSON / Copy JSON'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭 / Close'),
        ),
      ],
    );
  }
}
