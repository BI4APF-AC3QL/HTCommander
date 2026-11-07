import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'remote_connection_models.dart';

ConnectionProbes createConnectionProbes() => NativeConnectionProbes();

class NativeConnectionProbes implements ConnectionProbes {
  NativeConnectionProbes({this.timeout = const Duration(seconds: 4)});
  final Duration timeout;
  final Set<HttpClient> _clients = {};
  final Set<SecureSocket> _sockets = {};
  int _epoch = 0;

  @override
  Future<ConnectionCheck> dns(Uri uri) async {
    try {
      final addresses = await InternetAddress.lookup(uri.host).timeout(timeout);
      final v4 = addresses
          .where((a) => a.type == InternetAddressType.IPv4)
          .length;
      final v6 = addresses
          .where((a) => a.type == InternetAddressType.IPv6)
          .length;
      return ConnectionCheck(
        'dns',
        v4 + v6 == 0
            ? 'dnsFailed'
            : v4 == 0
            ? 'ipv6Only'
            : 'resolved',
        ipv4: v4,
        ipv6: v6,
      );
    } on TimeoutException {
      return const ConnectionCheck('dns', 'timeout');
    } catch (_) {
      return const ConnectionCheck('dns', 'dnsFailed');
    }
  }

  @override
  Future<ConnectionCheck> certificate(Uri uri) async {
    final epoch = _epoch;
    var rejected = false;
    var accepting = true;
    SecureSocket? socket;
    try {
      final connecting = SecureSocket.connect(
        uri.host,
        uri.port,
        timeout: timeout,
        onBadCertificate: (_) {
          rejected = true;
          return false;
        },
      );
      // A cancelled/expired connect may resolve later: destroy its socket.
      connecting.then((s) {
        if (!accepting || _epoch != epoch) s.destroy();
      }, onError: (Object _) {});
      socket = await connecting.timeout(timeout);
      if (epoch != _epoch) {
        socket.destroy();
        return const ConnectionCheck('certificate', 'cancelled');
      }
      _sockets.add(socket);
      final cert = socket.peerCertificate;
      return ConnectionCheck(
        'certificate',
        cert == null ? 'certificateMissing' : 'certificateValid',
        expires: cert?.endValidity,
      );
    } on TimeoutException {
      return const ConnectionCheck('certificate', 'timeout');
    } catch (_) {
      return ConnectionCheck(
        'certificate',
        rejected ? 'certificateRejected' : 'tlsFailed',
      );
    } finally {
      accepting = false;
      if (socket != null) {
        _sockets.remove(socket);
        socket.destroy();
      }
    }
  }

  @override
  Future<ConnectionCheck> http(Uri uri, {required bool backend}) async {
    final name = backend ? 'backend' : 'public';
    var certificateRejected = false;
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false
      ..badCertificateCallback = (_, _, _) {
        certificateRejected = true;
        return false;
      };
    _clients.add(client);
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        return ConnectionCheck(
          name,
          response.statusCode == 502 ? 'badGateway' : 'httpError',
          httpStatus: response.statusCode,
        );
      }
      // Limit both body memory and elapsed time; never collect cookies or logs.
      final builder = BytesBuilder(copy: false);
      var tooLarge = false;
      await (() async {
        await for (final block in response) {
          if (builder.length + block.length > 16384) {
            tooLarge = true;
            break;
          }
          builder.add(block);
        }
      })().timeout(timeout);
      if (tooLarge) {
        return ConnectionCheck(name, 'unexpectedService', httpStatus: 200);
      }
      final body = utf8.decode(builder.takeBytes(), allowMalformed: true);
      final login =
          body.contains('<title>HTCommander 登录</title>') &&
          body.contains('action="/login"') &&
          body.contains('name="csrf"');
      return ConnectionCheck(
        name,
        login ? 'loginReady' : 'unexpectedService',
        httpStatus: 200,
      );
    } on TimeoutException {
      return ConnectionCheck(name, 'timeout');
    } on HandshakeException {
      return ConnectionCheck(
        name,
        certificateRejected ? 'certificateRejected' : 'tlsFailed',
      );
    } catch (_) {
      return ConnectionCheck(name, 'unreachable');
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  @override
  void cancel() {
    _epoch++;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _clients.clear();
    _sockets.clear();
  }
}
