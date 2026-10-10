import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/web/remote_profile.dart';

class RemoteProfileDialog extends StatefulWidget {
  const RemoteProfileDialog({super.key});
  @override
  State<RemoteProfileDialog> createState() => _RemoteProfileDialogState();
}

class _RemoteProfileDialogState extends State<RemoteProfileDialog> {
  final _input = TextEditingController();
  RemoteProfilePlan? _plan;
  String? _error;
  bool _confirmed = false;
  String text(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _preview() {
    try {
      final value = RemoteProfile.preview(_input.text);
      setState(() {
        _plan = value;
        _error = null;
        _confirmed = false;
      });
    } catch (_) {
      setState(() {
        _plan = null;
        _error = text(
          '配置格式、字段或取值无效，请检查。',
          'Invalid profile format, fields or values.',
        );
      });
    }
  }

  void _apply() {
    if (!_confirmed || _plan == null) return;
    try {
      _plan!.apply();
      Navigator.of(context).pop(true);
    } catch (_) {
      setState(() {
        _plan = null;
        _confirmed = false;
        _error = text('配置已变化，请重新预览。', 'Settings changed; preview again.');
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(text('远控配置导入 / 导出', 'Remote profile import / export')),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text(
                '导出已保存的端口、外网地址、操作权策略、公共地图源和 APRS-IS 服务器/转发规则。密码、密钥、证书、私有地图地址、消息模板、位置及登录会话不导出。HTTPS 入口程序仍须单独配置。',
                'Exports saved port, public origin, control policy, public map source and APRS-IS server/rules. Excludes credentials, certificates, custom map URLs, messages/templates, positions and sessions. Configure the HTTPS gateway separately.',
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: Text(text('复制已保存配置 JSON', 'Copy saved profile JSON')),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: RemoteProfile.export()),
                );
                if (mounted) {
                  setState(
                    () => _error = text(
                      '已复制。可保存为 .json 文件；未保存的修改不会导出。',
                      'Copied. Save as a .json file; unsaved edits are not exported.',
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('profileInput'),
              controller: _input,
              minLines: 4,
              maxLines: 8,
              maxLength: 32768,
              decoration: InputDecoration(
                labelText: text('粘贴配置 JSON', 'Paste profile JSON'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {
                _plan = null;
                _confirmed = false;
                _error = null;
              }),
            ),
            OutlinedButton(
              onPressed: _preview,
              child: Text(text('预览导入', 'Preview import')),
            ),
            if (_plan != null) ...[
              const Divider(),
              Text(
                text(
                  '变更预览（当前 → 导入后）',
                  'Change preview (current → after import)',
                ),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final entry in _plan!.after.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${entry.key}: ${_plan!.before[entry.key] ?? '—'} → ${entry.value}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                key: const Key('profileConfirm'),
                title: Text(
                  text(
                    '确认停止网页远控、APRS 网关和发射；取消待发请求。导入后需手动重新授权和开启。',
                    'Confirm stopping remote access, APRS gateway and transmit, and cancelling pending requests. Re-authorize and enable manually after import.',
                  ),
                ),
                value: _confirmed,
                onChanged: (v) => setState(() => _confirmed = v == true),
              ),
            ],
            if (_error != null) Text(_error!, key: const Key('profileStatus')),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(text('关闭', 'Close')),
      ),
      FilledButton(
        key: const Key('profileApply'),
        onPressed: _plan == null || !_confirmed ? null : _apply,
        child: Text(text('应用导入', 'Apply import')),
      ),
    ],
  );
}
