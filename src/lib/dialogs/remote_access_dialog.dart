import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/data_broker.dart';
import '../services/data_broker_client.dart';
import '../services/secret_store.dart';
import '../services/web/remote_access_config.dart';
import '../services/web/remote_audit.dart';
import 'aprs_shortcuts_dialog.dart';
import 'remote_profile_dialog.dart';

class RemoteAccessDialog extends StatefulWidget {
  const RemoteAccessDialog({super.key});
  @override
  State<RemoteAccessDialog> createState() => _RemoteAccessDialogState();
}

class _RemoteAccessDialogState extends State<RemoteAccessDialog> {
  final _broker = DataBrokerClient();
  late final TextEditingController _password;
  late final TextEditingController _origin;
  late final TextEditingController _port;
  late bool _enabled;
  late bool _remote;
  late bool _tx;
  late bool _aprs;
  late bool _position;
  late bool _readOnly;
  late bool _approval;
  bool _stopped = false;
  List<Map> _clients = [];
  bool _showPassword = false;
  bool _saving = false;
  String? _error;
  String _status = '';
  List<String> _addresses = [];
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    final config = RemoteAccessConfig.current;
    _enabled = DataBroker.getValue<int>(0, 'webServerEnabled', 0) == 1;
    _remote = config.enabled;
    _tx = config.allowTransmit;
    _aprs = config.allowAprs;
    _position = config.allowPosition;
    _readOnly = config.defaultReadOnly;
    _approval = config.requireControlApproval;
    _stopped = DataBroker.getValue<int>(0, 'webServerEmergencyStopped', 0) == 1;
    _clients = (DataBroker.getValueDynamic(0, 'RemoteClients', []) as List)
        .whereType<Map>()
        .toList();
    _broker.subscribeMultiple(
      deviceId: 0,
      names: const ['RemoteClients', 'webServerEmergencyStopped'],
      callback: (_, _, _) {
        if (!mounted) return;
        setState(() {
          _clients =
              (DataBroker.getValueDynamic(0, 'RemoteClients', []) as List)
                  .whereType<Map>()
                  .toList();
          _stopped =
              DataBroker.getValue<int>(0, 'webServerEmergencyStopped', 0) == 1;
        });
      },
    );
    _password = TextEditingController(text: config.password);
    _origin = TextEditingController(text: config.publicOrigin);
    _port = TextEditingController(
      text: (DataBroker.getValue<int>(0, 'webServerPort', 8080) ?? 8080)
          .toString(),
    );
    _broker.subscribe(
      deviceId: 0,
      name: 'webServerStatus',
      callback: (_, _, value) {
        if (mounted) setState(() => _status = value?.toString() ?? '');
      },
    );
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    if (kIsWeb) return;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      final addresses = interfaces
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .toSet()
          .toList();
      if (mounted) setState(() => _addresses = addresses);
    } catch (_) {}
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text);
    final config = RemoteAccessConfig(
      enabled: _remote,
      password: _password.text,
      publicOrigin: _origin.text.trim(),
      allowTransmit: _tx,
    );
    if (port == null || port < 1024 || port > 65535) {
      setState(
        () => _error = _text('端口须为 1024–65535。', 'Port must be 1024–65535.'),
      );
      return;
    }
    final error =
        config.validationError ??
        RemoteAccessConfig.validateOrigin(_origin.text);
    if (error != null) {
      setState(
        () => _error = _text('远程访问密码至少 12 个字符；外网地址须为 HTTPS 域名/端口，不含路径。', error),
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Do not enable remote listening if the credential cannot be saved.
      await SecretStore.instance.write('webServerPassword', _password.text);
      final values = <String, Object?>{
        'webServerPassword': _password.text,
        'webServerPublicOrigin': config.externalOrigin ?? '',
        'webServerAllowTransmit': _tx ? 1 : 0,
        'webServerAllowAprs': _aprs ? 1 : 0,
        'webServerAllowPosition': _position ? 1 : 0,
        'webServerDefaultReadOnly': _readOnly ? 1 : 0,
        'webServerRequireControlApproval': _approval ? 1 : 0,
        'webServerRemoteEnabled': _remote ? 1 : 0,
        'webServerPort': port,
        'webServerEnabled': _enabled ? 1 : 0,
      };
      for (final entry in values.entries) {
        DataBroker.dispatch(deviceId: 0, name: entry.key, data: entry.value);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _text(
            '密码保存失败，远程服务未启用。',
            'Password could not be saved; remote access was not enabled.',
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _broker.dispose();
    _password.dispose();
    _origin.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_text('手机远程操控', 'Phone remote control')),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_text('启用网页服务', 'Enable web server')),
              value: _enabled,
              onChanged: _saving ? null : (v) => setState(() => _enabled = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _text('允许局域网 / VPN 远程访问', 'Allow LAN / VPN remote access'),
              ),
              subtitle: Text(
                _text(
                  '关闭时仅本机可访问。开启后所有访问都需要登录。',
                  'When off, listen on loopback only. When on, every client must sign in.',
                ),
              ),
              value: _remote,
              onChanged: _saving ? null : (v) => setState(() => _remote = v),
            ),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _text('网页端口', 'Web port')),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                labelText: _text(
                  '访问密码（至少 12 个字符）',
                  'Password (at least 12 characters)',
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.password),
              label: Text(_text('生成随机密码', 'Generate password')),
              onPressed: _saving
                  ? null
                  : () {
                      const alphabet =
                          'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
                      final random = Random.secure();
                      _password.text = List.generate(
                        24,
                        (_) => alphabet[random.nextInt(alphabet.length)],
                      ).join();
                      setState(() => _showPassword = true);
                    },
            ),
            TextField(
              controller: _origin,
              decoration: InputDecoration(
                labelText: _text(
                  '外网 HTTPS 地址（可选）',
                  'Public HTTPS origin (optional)',
                ),
                hintText: 'https://radio.example.com',
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_text('允许手机 PTT 发射', 'Allow phone PTT transmission')),
              subtitle: Text(
                _text(
                  '默认关闭。还须在电脑开启总“允许发射”及电台音频。',
                  'Off by default. Also requires Allow transmit and radio audio on the host.',
                ),
              ),
              value: _tx,
              onChanged: _saving ? null : (v) => setState(() => _tx = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _text('允许远程 APRS 消息发送', 'Allow remote APRS messages'),
              ),
              subtitle: Text(
                _text(
                  '仍须电脑总允许发射；与语音权限独立。',
                  'Requires host transmit permission, independent of voice.',
                ),
              ),
              value: _aprs,
              onChanged: _saving ? null : (v) => setState(() => _aprs = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_text('允许远程位置发送', 'Allow remote position packets')),
              value: _position,
              onChanged: _saving ? null : (v) => setState(() => _position = v),
            ),
            const Divider(),
            FilledButton.icon(
              icon: Icon(_stopped ? Icons.play_arrow : Icons.stop_circle),
              onPressed: () => DataBroker.dispatch(
                deviceId: 0,
                name: 'webServerEmergencyStopped',
                data: _stopped ? 0 : 1,
              ),
              label: Text(
                _stopped
                    ? _text('明确恢复远程控制', 'Resume remote control')
                    : _text('紧急停止远程控制与发送', 'Emergency stop remote control/TX'),
              ),
            ),
            Text(
              _text(
                '停止后不自动恢复；会取消待确认消息。恢复后仍须满足各项发射权限。',
                'Stopped control stays stopped until explicitly resumed; pending messages are cancelled. TX permissions still apply.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_text('新客户端默认只读', 'New clients start read-only')),
              subtitle: Text(
                _text(
                  '只读客户端可收听与查看；在此授予控制权。重新连接使用默认权限。',
                  'Read-only clients may listen and inspect. Grant control below; reconnect uses the default role.',
                ),
              ),
              value: _readOnly,
              onChanged: _saving ? null : (v) => setState(() => _readOnly = v),
            ),
            Text(_text('在线客户端', 'Connected clients')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _text(
                  '控制权申请必须由 Windows 批准',
                  'Host approval required for control',
                ),
              ),
              subtitle: Text(
                _text(
                  '关闭时空闲控制权自动授予首个有操作权限的申请者。只读客户端仍需由主机授权。',
                  'When off, an eligible requester receives idle control automatically. Read-only clients still need host authorization.',
                ),
              ),
              value: _approval,
              onChanged: _saving ? null : (v) => setState(() => _approval = v),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.back_hand),
              label: Text(_text('收回所有远程控制权', 'Recall all remote control')),
              onPressed: () => DataBroker.dispatch(
                deviceId: 0,
                name: 'RemoteControlRecall',
                data: true,
                store: false,
              ),
            ),
            ..._clients.map(
              (client) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('#${client['id']} · ${client['address']}'),
                subtitle: Text(
                  (client['ownsControl'] == true
                          ? _text('正在操作 · ', 'Operating · ')
                          : '') +
                      (client['controlRequested'] == true
                          ? _text(
                              '申请中 #${client['queuePosition']} · ',
                              'Waiting #${client['queuePosition']} · ',
                            )
                          : '') +
                      (client['readOnly'] == true
                          ? _text('只读', 'Read-only')
                          : _text('可申请控制', 'May request control')),
                ),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: _text('授予独占控制权', 'Grant exclusive control'),
                      icon: Icon(
                        client['ownsControl'] == true
                            ? Icons.verified_user
                            : Icons.gamepad,
                      ),
                      onPressed: _stopped
                          ? null
                          : () => DataBroker.dispatch(
                              deviceId: 0,
                              name: 'RemoteControlGrant',
                              data: client['id'],
                              store: false,
                            ),
                    ),
                    IconButton(
                      tooltip: _text('切换只读 / 控制', 'Toggle read-only / control'),
                      icon: Icon(
                        client['readOnly'] == true
                            ? Icons.lock
                            : Icons.lock_open,
                      ),
                      onPressed: () => DataBroker.dispatch(
                        deviceId: 0,
                        name: 'RemoteClientRole',
                        data: {
                          'id': client['id'],
                          'readOnly': client['readOnly'] != true,
                        },
                        store: false,
                      ),
                    ),
                    IconButton(
                      tooltip: _text('撤销登录并断开', 'Revoke login and disconnect'),
                      icon: const Icon(Icons.person_remove),
                      onPressed: () => DataBroker.dispatch(
                        deviceId: 0,
                        name: 'RemoteClientRevoke',
                        data: client['id'],
                        store: false,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(),
            OutlinedButton.icon(
              icon: const Icon(Icons.star_outline),
              label: Text(
                _text('常用呼号与消息模板', 'Favorite callsigns and message templates'),
              ),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const AprsShortcutsDialog(),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.import_export),
              label: Text(
                _text('远控配置导入 / 导出', 'Remote profile import / export'),
              ),
              onPressed: () async {
                final applied = await showDialog<bool>(
                  context: context,
                  builder: (_) => const RemoteProfileDialog(),
                );
                if (applied == true && context.mounted) {
                  // Import is immediate: close this stale editor so Save cannot
                  // restore the pre-import activation or old endpoints.
                  Navigator.of(context).pop(true);
                }
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: Text(
                _text('复制脱敏操作审计 JSON', 'Copy redacted operation audit JSON'),
              ),
              onPressed: () => Clipboard.setData(
                ClipboardData(
                  text: RemoteAudit.export(
                    (DataBroker.getValueDynamic(0, 'RemoteAudit', []) as List)
                        .whereType<Map>()
                        .toList(),
                  ),
                ),
              ),
            ),
            Text(
              _text(
                '审计仅在本次运行的内存中保存最近 200 条，不含密码、地址、消息正文、定位或音频；“接受”表示软件接受请求，不代表射频发送成功。相同客户端的连续同类拒绝每秒记录一次。',
                'Audit keeps the latest 200 events in memory for this run. No passwords, addresses, message text, locations or audio. Accepted means software accepted a request, not RF success. Repeated identical denials are coalesced to one per second.',
              ),
            ),
            const Divider(),
            Text(
              _text('手机连接地址', 'Phone connection addresses'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            ..._addresses.map(
              (ip) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(child: SelectableText('http://$ip:${_port.text}')),
                    IconButton(
                      tooltip: _text('复制地址', 'Copy address'),
                      icon: const Icon(Icons.copy),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: 'http://$ip:${_port.text}'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _text(
                '同一 Wi-Fi：使用上方电脑 IP。外网：电脑和手机使用同一 VPN，或配置 HTTPS 反向代理并填写上方外网地址。手机麦克风必须使用 HTTPS。Windows 防火墙需要允许此应用的相应网络访问。',
                'Same Wi-Fi: use the PC IP above. Internet: join the same VPN or configure an HTTPS reverse proxy and enter its public origin. Browser microphone requires HTTPS. Allow the app through Windows Firewall on the intended network.',
              ),
            ),
            if (_status.isNotEmpty) Text(_status),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: Text(_text('取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_text('保存', 'Save')),
      ),
    ],
  );
}
