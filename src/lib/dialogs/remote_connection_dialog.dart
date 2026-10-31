import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/web/remote_connection_service.dart';

class RemoteConnectionDialog extends StatefulWidget {
  const RemoteConnectionDialog({
    super.key,
    required this.spec,
    this.hosts = const [],
    this.runner,
  });
  final RemoteConnectionSpec spec;
  final List<String> hosts;
  final ConnectionDiagnosticRunner? runner;
  @override
  State<RemoteConnectionDialog> createState() => _RemoteConnectionDialogState();
}

class _RemoteConnectionDialogState extends State<RemoteConnectionDialog> {
  late final ConnectionDiagnosticRunner _runner;
  late final List<Uri> _addresses;
  late Uri _selected;
  bool _running = false;
  List<ConnectionCheck> _checks = [];
  DateTime? _checkedAt;
  String _t(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  @override
  void initState() {
    super.initState();
    _runner =
        widget.runner ?? ConnectionDiagnosticRunner(createConnectionProbes());
    _addresses = widget.spec.loginAddresses(widget.hosts);
    _selected = _addresses.first;
  }

  @override
  void dispose() {
    _runner.dispose();
    super.dispose();
  }

  Future<void> _diagnose() async {
    if (_running) return;
    setState(() {
      _running = true;
      _checks = [];
    });
    final checks = await _runner.run(widget.spec);
    if (!mounted) return;
    setState(() {
      _running = false;
      _checks = checks;
      _checkedAt = DateTime.now().toUtc();
    });
  }

  String _label(String name) => switch (name) {
    'backend' => _t('本机网页后端', 'Local web backend'),
    'dns' => 'DNS A / AAAA',
    'certificate' => _t('HTTPS 证书验证', 'HTTPS certificate validation'),
    'public' => _t('公网入口登录页', 'Public login page'),
    _ => _t('未知检查', 'Unknown check'),
  };
  String _reason(String code) => switch (code) {
    'loginReady' => _t(
      '已识别 HTCommander 登录页',
      'HTCommander login page recognized',
    ),
    'resolved' => _t('地址已解析', 'Addresses resolved'),
    'ipv6Only' => _t(
      '只有 IPv6；手机网络也需 IPv6',
      'IPv6 only; phone network needs IPv6',
    ),
    'certificateValid' => _t(
      '证书链、主机名和有效期通过验证',
      'Certificate chain, hostname and validity verified',
    ),
    'certificateRejected' => _t(
      '证书未通过验证；检查证书和系统时间',
      'Certificate rejected; check certificate and system time',
    ),
    'dnsFailed' => _t(
      'DNS 未解析；检查域名及 A/AAAA 记录',
      'DNS failed; check hostname and A/AAAA records',
    ),
    'badGateway' => _t(
      '502：检查入口后端端口与本机服务',
      '502: check gateway backend port and local service',
    ),
    'unexpectedService' => _t(
      '响应不是 HTCommander 登录页；检查端口占用/代理',
      'Response is not the HTCommander login page; check port/proxy',
    ),
    'httpError' => _t('网页返回错误状态', 'HTTP error status'),
    'notConfigured' => _t('尚未保存外网 HTTPS 地址', 'No saved public HTTPS origin'),
    'timeout' => _t(
      '检查超时；确认服务及网络连通性',
      'Timed out; check service and connectivity',
    ),
    'unreachable' => _t(
      '无法连接；检查服务/防火墙/端口',
      'Unreachable; check service/firewall/port',
    ),
    'tlsFailed' => _t(
      'TLS 握手失败；检查 HTTPS 入口',
      'TLS handshake failed; check HTTPS gateway',
    ),
    _ => _t('暂时无法检查', 'Check unavailable'),
  };
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_t('连接地址与诊断', 'Connection addresses and diagnostics')),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _t(
                '使用已保存的地址和端口；改配置后请先保存。二维码仅包含登录地址，不含密码。127.0.0.1 仅用于本机。',
                'Uses saved addresses and port; save changes first. QR contains only the login URL, no password. 127.0.0.1 is local to this PC.',
              ),
            ),
            DropdownButtonFormField<Uri>(
              initialValue: _selected,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _t('登录地址', 'Login address'),
              ),
              items: _addresses
                  .map(
                    (u) => DropdownMenuItem(
                      value: u,
                      child: Text(
                        u.toString(),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (u) {
                if (u != null) setState(() => _selected = u);
              },
            ),
            const SizedBox(height: 12),
            Center(
              child: RepaintBoundary(
                key: const ValueKey('connection-login-qr'),
                child: QrImageView(
                  data: _selected.toString(),
                  size: 236,
                  padding: const EdgeInsets.all(32),
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                  semanticsLabel: _t('登录地址二维码', 'Login address QR code'),
                ),
              ),
            ),
            SelectableText(_selected.toString()),
            OutlinedButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: _selected.toString())),
              icon: const Icon(Icons.copy),
              label: Text(_t('复制登录地址', 'Copy login address')),
            ),
            const Divider(),
            FilledButton.icon(
              onPressed: _running ? null : _diagnose,
              icon: const Icon(Icons.network_check),
              label: Text(
                _running
                    ? _t('正在检查…', 'Checking…')
                    : _t('检查已保存的连接配置', 'Check saved connection settings'),
              ),
            ),
            for (final check in _checks)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '${_label(check.name)}: ${_reason(check.result)}'
                  '${check.ipv4 == null ? '' : ' · A ${check.ipv4} / AAAA ${check.ipv6 ?? 0}'}'
                  '${check.httpStatus == null ? '' : ' · HTTP ${check.httpStatus}'}'
                  '${check.expires == null ? '' : ' · UTC ${check.expires!.toUtc().toIso8601String()}'}',
                ),
              ),
            if (_checks.isNotEmpty)
              OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(
                  _t(
                    '复制脱敏连接诊断 JSON',
                    'Copy redacted connection diagnostics JSON',
                  ),
                ),
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: const JsonEncoder.withIndent('  ').convert({
                      'checkedAt': _checkedAt?.toIso8601String(),
                      'checks': _checks.map((c) => c.toJson()).toList(),
                    }),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              _t(
                '检查只发起无密码的 DNS、TLS 和登录页请求，不改防火墙、证书或电台。结果反映电脑侧；仍需手机验证外网与 IPv6。公网回流受路由器限制时，电脑可能失败而手机可以访问。',
                'Checks make unauthenticated DNS, TLS and login-page requests without changing firewall, certificates or radio. Results are from this PC; verify phone Internet/IPv6 separately. Router loopback limits can make the PC fail while a phone succeeds.',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_t('关闭', 'Close')),
      ),
    ],
  );
}
