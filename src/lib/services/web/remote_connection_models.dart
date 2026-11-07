import 'dart:async';
import 'remote_access_config.dart';

class RemoteConnectionSpec {
  RemoteConnectionSpec({required this.port, String publicOrigin = ''}) {
    if (port < 1 ||
        port > 65535 ||
        RemoteAccessConfig.validateOrigin(publicOrigin) != null) {
      throw const FormatException('Invalid saved connection address');
    }
    external = publicOrigin.trim().isEmpty
        ? null
        : Uri.parse(publicOrigin.trim());
  }
  final int port;
  late final Uri? external;
  Uri get backend =>
      Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/login');
  List<Uri> loginAddresses(Iterable<String> hosts) => {
    if (external != null) external!.replace(path: '/login'),
    backend,
    for (final host in hosts)
      if (_numericHost(host))
        Uri(scheme: 'http', host: host, port: port, path: '/login'),
  }.toList(growable: false);
  static bool _numericHost(String host) {
    try {
      if (host.contains(':')) {
        Uri.parseIPv6Address(host);
      } else {
        Uri.parseIPv4Address(host);
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

class ConnectionCheck {
  const ConnectionCheck(
    this.name,
    this.result, {
    this.ipv4,
    this.ipv6,
    this.httpStatus,
    this.expires,
  });
  final String name, result;
  final int? ipv4, ipv6, httpStatus;
  final DateTime? expires;
  static const names = {'backend', 'dns', 'certificate', 'public'};
  static const results = {
    'loginReady',
    'resolved',
    'ipv6Only',
    'certificateValid',
    'certificateRejected',
    'certificateMissing',
    'dnsFailed',
    'badGateway',
    'unexpectedService',
    'httpError',
    'notConfigured',
    'timeout',
    'unreachable',
    'tlsFailed',
    'unavailable',
    'cancelled',
  };
  Map<String, Object?> toJson() => {
    'check': names.contains(name) ? name : 'unknown',
    'result': results.contains(result) ? result : 'unavailable',
    if (ipv4 != null) 'ipv4Count': ipv4,
    if (ipv6 != null) 'ipv6Count': ipv6,
    if (httpStatus != null) 'httpStatus': httpStatus,
    if (expires != null)
      'certificateExpiresAt': expires!.toUtc().toIso8601String(),
  };
}

abstract class ConnectionProbes {
  Future<ConnectionCheck> dns(Uri uri);
  Future<ConnectionCheck> certificate(Uri uri);
  Future<ConnectionCheck> http(Uri uri, {required bool backend});
  void cancel();
}

/// Read-only probes. Results contain fixed reasons/counts, no addresses, cookies,
/// certificate subject or exception text. A disposed run never publishes.
class ConnectionDiagnosticRunner {
  ConnectionDiagnosticRunner(
    this.probes, {
    this.timeout = const Duration(seconds: 5),
  });
  final ConnectionProbes probes;
  final Duration timeout;
  bool _disposed = false, _running = false;
  Future<List<ConnectionCheck>> run(RemoteConnectionSpec spec) async {
    if (_disposed || _running) return [];
    _running = true;
    Future<ConnectionCheck> bounded(
      String name,
      Future<ConnectionCheck> Function() action,
    ) async {
      try {
        return await action().timeout(timeout);
      } on TimeoutException {
        return ConnectionCheck(name, 'timeout');
      } catch (_) {
        return ConnectionCheck(name, 'unavailable');
      }
    }

    try {
      final result = await Future.wait([
        bounded('backend', () => probes.http(spec.backend, backend: true)),
        if (spec.external != null) ...[
          bounded('dns', () => probes.dns(spec.external!)),
          bounded('certificate', () => probes.certificate(spec.external!)),
          bounded(
            'public',
            () => probes.http(
              spec.external!.replace(path: '/login'),
              backend: false,
            ),
          ),
        ] else ...[
          for (final name in ['dns', 'certificate', 'public'])
            ConnectionCheck(name, 'notConfigured').asFuture(),
        ],
      ]);
      return _disposed ? [] : result;
    } finally {
      probes.cancel();
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    probes.cancel();
  }
}

extension on ConnectionCheck {
  Future<ConnectionCheck> asFuture() async => this;
}
