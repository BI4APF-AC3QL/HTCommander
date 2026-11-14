import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import '../aprsis/gateway_policy.dart';
import '../services/data_broker_client.dart';

class GatewayPolicyDialog extends StatefulWidget {
  const GatewayPolicyDialog({super.key});
  @override
  State<GatewayPolicyDialog> createState() => _GatewayPolicyDialogState();
}

class _GatewayPolicyDialogState extends State<GatewayPolicyDialog> {
  final _broker = DataBrokerClient();
  @override
  void initState() {
    super.initState();
    _broker.subscribeMultiple(
      deviceId: 201,
      names: const ['GateMetrics', 'GateHealth'],
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

  final _initial = GatewayPolicy.current;
  late bool _up = _initial.toInternet;
  late String _path = _initial.rfPath;
  late int _limit = _initial.rfPerMinute;
  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String text(String cn, String en) => zh ? cn : en;
    final limits = {1, 3, 6, 10, 20, 30, _limit}.toList()..sort();
    return AlertDialog(
      title: Text(text('APRS 网关转发规则', 'APRS gateway forwarding rules')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(text('电台接收 → APRS-IS', 'Received RF → APRS-IS')),
                value: _up,
                onChanged: (value) => setState(() => _up = value),
              ),
              Text(
                text(
                  '互联网 → 电台仍由父设置中的 IGate 开关控制，并要求“允许发射”。只转发最近一小时在射频收到过的电台的文本消息；忙时不排队重放。',
                  'Internet → RF also requires the parent IGate switch and Allow transmit. Only text messages for stations heard on RF within one hour are forwarded; busy requests are dropped.',
                ),
              ),
              const SizedBox(height: 16),
              Builder(
                builder: (_) {
                  final g =
                      _broker.getValueDynamic(201, 'GateMetrics', {}) as Map;
                  return Text(
                    text(
                      '本次运行：上行 ${g['forwarded'] ?? 0}，下行请求 ${g['rfForwarded'] ?? 0}，重连 ${g['reconnectAttempts'] ?? 0}，队列 ${g['queueDepth'] ?? 0}。',
                      'This run: forwarded ${g['forwarded'] ?? 0}, RF requests ${g['rfForwarded'] ?? 0}, retries ${g['reconnectAttempts'] ?? 0}, queued ${g['queueDepth'] ?? 0}.',
                    ),
                  );
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(
                  text('复制最近 24 小时统计（UTC）', 'Copy last 24 hours (UTC)'),
                ),
                onPressed: () async {
                  final report = _broker.getValueDynamic(201, 'GateHealth', []);
                  await Clipboard.setData(
                    ClipboardData(text: jsonEncode(report)),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          text(
                            '已复制统计，不包含呼号、消息或位置。',
                            'Statistics copied; no callsigns, messages or locations.',
                          ),
                        ),
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _path,
                decoration: InputDecoration(
                  labelText: text('射频转发路径', 'RF forwarding path'),
                ),
                items: GatewayPolicy.paths
                    .map(
                      (p) => DropdownMenuItem(
                        value: p,
                        child: Text(
                          p.isEmpty ? text('直接发送（默认）', 'Direct (default)') : p,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _path = value ?? ''),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: _limit,
                decoration: InputDecoration(
                  labelText: text('每分钟射频消息上限', 'RF messages per minute'),
                ),
                items: limits
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (value) => setState(() => _limit = value ?? 6),
              ),
              const SizedBox(height: 16),
              Text(
                text(
                  '自动阻止 NOGATE、RFONLY、TCPXX、未验证路径和循环包。下行使用第三方封装，排队帧 15 秒过期；关闭网关或发射权限会撤销尚未发送的网关帧。',
                  'NOGATE, RFONLY, TCPXX, unverified paths and loops are blocked. Downlink uses third-party encapsulation and a 15-second queue deadline. Disabling the gateway or TX cancels pending gateway frames.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(text('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: () {
            GatewayPolicy(
              toInternet: _up,
              rfPath: _path,
              rfPerMinute: _limit,
            ).save();
            Navigator.pop(context);
          },
          child: Text(text('保存规则', 'Save rules')),
        ),
      ],
    );
  }
}
