/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0

A minimal HTTP + WebSocket server that serves the Flutter web build (see
[_resolveWebAppDir]) and bridges the radio to connected browsers over a
WebSocket at `/websocket.aspx`. LAN listening requires explicit remote opt-in.

The served Flutter UI connects back over that WebSocket to share the host's
radio instead of using the browser's Web Bluetooth (see
radio/websocket_transport.dart).

This class is only responsible for transport (HTTP static files + WebSocket
framing). The bridge logic that connects WebSocket clients to the radio lives in
[WebServerHandler].
*/

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../data_broker_client.dart';
import '../data_broker.dart';
import 'remote_access_config.dart';
import 'remote_web_auth.dart';
import 'remote_mobile_page.dart';
import 'remote_tile_proxy.dart';
import '../../utils/map_source.dart';

/// Callback raised when a WebSocket [client] connects or disconnects.
typedef WebSocketClientCallback = void Function(WebSocketClient client);

/// Callback raised when a text message is received from a WebSocket [client].
typedef WebSocketTextCallback =
    void Function(WebSocketClient client, String message);

/// Callback raised when a binary message is received from a WebSocket [client].
typedef WebSocketBinaryCallback =
    void Function(WebSocketClient client, Uint8List data);

/// A single connected WebSocket client.
class WebSocketClient {
  WebSocketClient(
    this.id,
    this._socket, {
    this.readOnly = false,
    this.address = '',
  });
  bool readOnly;
  final String address;
  final DateTime connectedAt = DateTime.now();

  /// Monotonically increasing client identifier.
  final int id;
  final WebSocket _socket;

  /// Sends a text frame to this client.
  void sendText(String message) {
    try {
      _socket.add(message);
    } catch (_) {
      // Client likely disconnected; ignore.
    }
  }

  /// Sends a binary frame to this client.
  void sendBinary(List<int> data) {
    try {
      _socket.add(data);
    } catch (_) {
      // Client likely disconnected; ignore.
    }
  }

  void _close() {
    try {
      _socket.close();
    } catch (_) {
      // Already closed.
    }
  }
}

/// Serves the Flutter web build over HTTP and bridges the radio over a
/// WebSocket on desktop platforms.
class WebServer {
  WebServer(this.port, {RemoteAccessConfig? remoteConfig})
    : remoteConfig = remoteConfig ?? const RemoteAccessConfig(),
      _broker = DataBrokerClient() {
    _auth = RemoteWebAuth(this.remoteConfig.password);
  }

  final RemoteAccessConfig remoteConfig;
  late final RemoteWebAuth _auth;
  final Set<String> _allowedHosts = {'localhost', '127.0.0.1', '::1'};
  final Map<int, Timer> _sessionChecks = {};
  final Map<int, String?> _clientSessions = {};

  /// The WebSocket endpoint the browser connects to.
  static const String _webSocketPath = '/websocket.aspx';

  final int port;
  final DataBrokerClient _broker;

  HttpServer? _server;
  bool _running = false;
  int _generation = 0;
  int _nextClientId = 1;
  final String _sessionToken = base64UrlEncode(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final Map<int, WebSocketClient> _clients = <int, WebSocketClient>{};
  RemoteTileProxy? _tiles;

  /// Cached, resolved Flutter web build directory. Null until first resolved;
  /// only cached once a valid build is found so a build produced after startup
  /// is still picked up.
  Directory? _webAppDir;

  /// Raised when a new WebSocket client connects.
  WebSocketClientCallback? onClientConnected;

  /// Raised when a WebSocket client disconnects.
  WebSocketClientCallback? onClientDisconnected;
  WebSocketClientCallback? onClientRoleChanged;
  List<Map<String, Object>> get clientSummaries => _clients.values
      .map(
        (c) => {
          'id': c.id,
          'address': c.address,
          'readOnly': c.readOnly,
          'connectedAt': c.connectedAt.toIso8601String(),
        },
      )
      .toList();

  void setClientReadOnly(int id, bool readOnly) {
    final client = _clients[id];
    if (client == null) return;
    client.readOnly = readOnly;
    onClientRoleChanged?.call(client);
  }

  void revokeClient(int id) {
    final session = _clientSessions[id];
    _auth.logout(session);
    final victims = _clients.values
        .where(
          (c) =>
              c.id == id ||
              (session != null && _clientSessions[c.id] == session),
        )
        .toList();
    for (final client in victims) {
      client._close();
      _removeClient(client);
    }
  }

  static bool readOnlyMessageAllowed(String message) {
    if (const ['audioon', 'audiooff', 'connect'].contains(message)) return true;
    if (!message.startsWith('remote:')) return false;
    try {
      final value = jsonDecode(message.substring(7));
      return value is Map &&
          const [
            'state',
            'pttStop',
            'requestControl',
            'releaseControl',
          ].contains(value['op']);
    } catch (_) {
      return false;
    }
  }

  /// Raised when a text message is received from a WebSocket client.
  WebSocketTextCallback? onTextMessage;
  WebSocketClientCallback? onWriteDenied;

  /// Raised when a binary message is received from a WebSocket client.
  WebSocketBinaryCallback? onBinaryMessage;

  /// Whether the server is currently listening.
  bool get isRunning => _running;

  /// The actual port the server is bound to, or `null` if not running. Differs
  /// from [port] only when [port] is `0` (ephemeral port selection).
  int? get boundPort => _server?.port;

  /// Number of currently connected WebSocket clients.
  int get clientCount => _clients.length;
  WebSocketClient? clientById(int id) => _clients[id];

  /// Starts the web server. Returns `true` on success.
  Future<bool> start() async {
    if (_running) return true;
    final generation = ++_generation;
    try {
      if (remoteConfig.validationError != null) {
        throw StateError(remoteConfig.validationError!);
      }
      if (remoteConfig.enabled) {
        for (final interface in await NetworkInterface.list()) {
          _allowedHosts.addAll(interface.addresses.map((a) => a.address));
        }
        final external = remoteConfig.externalOrigin;
        if (external != null) _allowedHosts.add(Uri.parse(external).host);
      }
      final listener = await HttpServer.bind(
        remoteConfig.enabled
            ? InternetAddress.anyIPv4
            : InternetAddress.loopbackIPv4,
        port,
      );
      if (generation != _generation) {
        await listener.close(force: true);
        return false;
      }
      _server = listener;
      _running = true;
      _server!.listen(
        _handleRequest,
        onError: (Object _) {
          // Ignore individual request errors while running.
        },
      );
      _broker.logInfo('[WebServer] Started on port $port');
      return true;
    } catch (ex) {
      _broker.logError('[WebServer] Failed to start on port $port: $ex');
      _running = false;
      return false;
    }
  }

  /// Stops the web server and closes all WebSocket clients.
  Future<void> stop() async {
    _generation++;
    _tiles?.close();
    _tiles = null;
    if (!_running && _server == null) return;
    _running = false;
    for (final client in List<WebSocketClient>.from(_clients.values)) {
      client._close();
      _removeClient(client);
    }
    _clients.clear();
    for (final timer in _sessionChecks.values) {
      timer.cancel();
    }
    _sessionChecks.clear();
    _clientSessions.clear();
    final listener = _server;
    _server = null;
    await listener?.close(force: true);
    _broker.logInfo('[WebServer] Stopped');
  }

  void dispose() {
    unawaited(stop());
    _broker.dispose();
  }

  /// Sends a text message to every connected WebSocket client.
  void broadcastText(String message) {
    for (final client in _clients.values) {
      client.sendText(message);
    }
  }

  /// Sends a binary message to every connected WebSocket client.
  void broadcastBinary(List<int> data) {
    for (final client in _clients.values) {
      client.sendBinary(data);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final host = request.requestedUri.host.toLowerCase();
    final origin = request.headers.value('origin');
    final expectedOrigin = _effectiveOrigin(request);
    request.response.headers.set('X-Content-Type-Options', 'nosniff');
    request.response.headers.set('X-Frame-Options', 'DENY');
    // Chromium form POSTs may use Origin: null under no-referrer, which
    // conflicts with the same-origin check below. Keep same-site origins
    // available without disclosing referrers to other sites.
    request.response.headers.set('Referrer-Policy', 'same-origin');
    if (!_allowedHosts.contains(host) ||
        (origin != null && origin != expectedOrigin)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (remoteConfig.enabled) {
      if (request.uri.path == '/login') {
        await _handleLogin(request);
        return;
      }
      if (request.uri.path == '/logout' &&
          request.method == 'POST' &&
          origin == expectedOrigin) {
        final session = _cookie(request, 'htc_bridge');
        _auth.logout(session);
        // Logout also revokes the open radio/audio connection immediately.
        for (final entry in _clientSessions.entries.toList()) {
          if (entry.value == session) {
            _clients[entry.key]?._close();
          }
        }
        request.response.cookies.add(
          Cookie('htc_bridge', '')
            ..maxAge = 0
            ..path = '/',
        );
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      if (!_authorized(request)) {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          request.response.statusCode = HttpStatus.seeOther;
          request.response.headers.set('location', '/login');
        }
        await request.response.close();
        return;
      }
    }
    // WebSocket upgrade requests are bridged to the radio.
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      await _handleWebSocket(request);
      return;
    }
    await _handleHttpRequest(request);
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    if (request.uri.path != _webSocketPath) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('404 - Not Found');
      await request.response.close();
      return;
    }

    if (!_authorized(request) || request.headers.value('origin') == null) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (_clients.length >= 8) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      return;
    }

    final clientId = _nextClientId++;
    final client = WebSocketClient(
      clientId,
      socket,
      readOnly: remoteConfig.defaultReadOnly,
      address: request.connectionInfo?.remoteAddress.address ?? '',
    );
    socket.pingInterval = const Duration(seconds: 20);
    _clients[clientId] = client;
    _broker.logInfo('[WebServer] WebSocket client $clientId connected');
    if (remoteConfig.enabled) {
      final session = _cookie(request, 'htc_bridge');
      _clientSessions[clientId] = session;
      _sessionChecks[clientId] = Timer.periodic(const Duration(seconds: 30), (
        _,
      ) {
        if (!_auth.authenticated(session)) client._close();
      });
    }
    onClientConnected?.call(client);

    socket.listen(
      (dynamic message) {
        if (remoteConfig.enabled && !_authorized(request)) {
          client._close();
          return;
        }
        final size = message is String
            ? utf8.encode(message).length
            : (message is List<int> ? message.length : 0);
        if (size > 65536) {
          socket.close(WebSocketStatus.messageTooBig, 'Message exceeds 64 KiB');
          return;
        }
        if ((client.readOnly ||
                (remoteConfig.enabled &&
                    DataBroker.getValue<int>(
                          0,
                          'webServerEmergencyStopped',
                          0,
                        ) ==
                        1)) &&
            (message is! String || !readOnlyMessageAllowed(message))) {
          client.sendText('remote:{"error":"This client is read-only."}');
          onWriteDenied?.call(client);
          return;
        }
        if (message is String) {
          onTextMessage?.call(client, message);
        } else if (message is List<int>) {
          onBinaryMessage?.call(client, Uint8List.fromList(message));
        }
      },
      onError: (Object _) {
        _removeClient(client);
      },
      onDone: () {
        _removeClient(client);
      },
      cancelOnError: true,
    );
  }

  void _removeClient(WebSocketClient client) {
    _sessionChecks.remove(client.id)?.cancel();
    _clientSessions.remove(client.id);
    if (_clients.remove(client.id) == null) return;
    _broker.logInfo('[WebServer] WebSocket client ${client.id} disconnected');
    onClientDisconnected?.call(client);
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (request.uri.path.startsWith('/remote-tiles/')) {
      await _handleTile(request);
      return;
    }
    final response = request.response;
    try {
      if (remoteConfig.enabled &&
          const [
            '/remote.webmanifest',
            '/remote-worker.js',
          ].contains(request.uri.path)) {
        final manifest = request.uri.path.endsWith('.webmanifest');
        response.headers.contentType = ContentType(
          'application',
          manifest ? 'manifest+json' : 'javascript',
          charset: 'utf-8',
        );
        response.headers.set('Cache-Control', 'no-store');
        response.write(manifest ? remotePwaManifest : remotePwaWorker);
        await response.close();
        return;
      }
      if (remoteConfig.enabled &&
          (request.uri.path == '/' || request.uri.path == '/remote.html')) {
        response.headers.contentType = ContentType.html;
        response.headers.set('Cache-Control', 'no-store');
        response.write(remoteMobilePage);
        await response.close();
        return;
      }
      final dir = _resolveWebAppDir();
      if (dir == null) {
        response.statusCode = HttpStatus.notFound;
        response.headers.contentType = ContentType.text;
        response.write(
          '404 - Flutter web build not found. Run tools/build_web_app.ps1 or '
          'place the build under a "web_app" folder next to the app.',
        );
        await response.close();
        return;
      }

      var urlPath = request.uri.path;
      if (urlPath == '/' || urlPath.isEmpty) urlPath = '/index.html';
      final rel = urlPath.startsWith('/') ? urlPath.substring(1) : urlPath;
      final relativePath = Uri.decodeComponent(rel);

      // Security check: prevent path traversal.
      if (relativePath.contains('..') ||
          relativePath.contains('\\') ||
          relativePath.startsWith('/')) {
        response.statusCode = HttpStatus.badRequest;
        response.headers.contentType = ContentType.text;
        response.write('400 - Bad Request');
        await response.close();
        return;
      }

      // De-duplication: the app's own pubspec assets (declared under `assets/`)
      // are bundled into the Flutter web build under `assets/assets/...`, which
      // is byte-identical to what the desktop app already carries in its asset
      // bundle. Serve those straight from `rootBundle` so the staged web build
      // need not ship a second copy (see tools/build_web_app.ps1). Engine files
      // (manifests, fonts, packages) live under a single `assets/` and are left
      // to the web build, which tree-shakes them per platform.
      if (relativePath.startsWith('assets/assets/')) {
        final bundleKey = relativePath.substring('assets/'.length);
        final bundled = await _tryLoadAsset(bundleKey);
        if (bundled != null) {
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = _contentTypeFor(relativePath);
          response.headers.contentLength = bundled.length;
          response.add(bundled);
          await response.close();
          return;
        }
      }

      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        '${relativePath.replaceAll('/', Platform.pathSeparator)}',
      );
      if (!file.existsSync()) {
        response.statusCode = HttpStatus.notFound;
        response.headers.contentType = ContentType.text;
        response.write('404 - File Not Found');
        await response.close();
        return;
      }

      if (relativePath == 'index.html' && !remoteConfig.enabled) {
        response.cookies.add(
          Cookie('htc_bridge', _sessionToken)
            ..httpOnly = true
            ..sameSite = SameSite.strict
            ..path = '/',
        );
      }
      final bytes = await file.readAsBytes();
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = _contentTypeFor(relativePath);
      response.headers.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
    } catch (ex) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.headers.contentType = ContentType.text;
        response.write('500 - Internal Server Error');
        await response.close();
      } catch (_) {
        // Response already (partly) sent; nothing more to do.
      }
    }
  }

  Future<void> _handleTile(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    if (!_authorized(request)) {
      response.statusCode = HttpStatus.unauthorized;
    } else if (request.method != 'GET') {
      response.statusCode = HttpStatus.methodNotAllowed;
    } else {
      final match = RegExp(
        r'^/remote-tiles/([a-z0-9-]+)/([0-9]{1,2})/([0-9]{1,6})/([0-9]{1,6})\.png$',
      ).firstMatch(request.uri.path);
      final sources = {
        for (final source in MapSource.builtIn) source.id: source,
        MapSource.current.id: MapSource.current,
      };
      final source = match == null ? null : sources[match[1]];
      final revision = request.uri.queryParameters['v'];
      final tile = source == null ||
              (revision != null && revision != source.cacheNamespace)
          ? null
          : await (_tiles ??= RemoteTileProxy()).tile(
              source,
              int.parse(match![2]!),
              int.parse(match[3]!),
              int.parse(match[4]!),
            );
      if (tile == null) {
        response.statusCode = HttpStatus.badGateway;
      } else {
        response.headers.contentType = tile.contentType;
        response.headers.contentLength = tile.bytes.length;
        response.add(tile.bytes);
      }
    }
    await response.close();
  }

  String _effectiveOrigin(HttpRequest request) {
    final external = remoteConfig.externalOrigin;
    if (external != null &&
        request.requestedUri.host == Uri.parse(external).host) {
      return external;
    }
    return request.requestedUri.origin;
  }

  String? _cookie(HttpRequest request, String name) {
    for (final cookie in request.cookies) {
      if (cookie.name == name) return cookie.value;
    }
    return null;
  }

  bool _authorized(HttpRequest request) {
    final token = _cookie(request, 'htc_bridge');
    return remoteConfig.enabled
        ? _auth.authenticated(token)
        : token == _sessionToken;
  }

  Future<void> _handleLogin(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    );
    final address = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    if (_auth.rateLimited(address)) {
      response.statusCode = HttpStatus.tooManyRequests;
      response.headers.set('Retry-After', '60');
      response.write('Too many login attempts. Retry in one minute.');
      await response.close();
      return;
    }
    if (request.method == 'POST') {
      try {
        final bytes = <int>[];
        await for (final chunk in request.timeout(
          const Duration(seconds: 10),
        )) {
          if (bytes.length + chunk.length > 4096) throw const FormatException();
          bytes.addAll(chunk);
        }
        final fields = Uri.splitQueryString(utf8.decode(bytes));
        if (!_auth.consumeForm(_cookie(request, 'htc_login'), fields['csrf'])) {
          response.statusCode = HttpStatus.forbidden;
          await response.close();
          return;
        }
        final token = _auth.login(address, fields['password'] ?? '');
        if (token != null) {
          response.cookies.add(
            Cookie('htc_bridge', token)
              ..httpOnly = true
              ..sameSite = SameSite.strict
              ..path = '/'
              ..secure = _effectiveOrigin(request).startsWith('https:')
              ..maxAge = 43200,
          );
          response.statusCode = HttpStatus.seeOther;
          response.headers.set('location', '/remote.html');
          await response.close();
          return;
        }
        response.statusCode = HttpStatus.unauthorized;
      } catch (_) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
        return;
      }
    } else if (request.method != 'GET') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final form = _auth.newForm();
    response.cookies.add(
      Cookie('htc_login', form)
        ..httpOnly = true
        ..sameSite = SameSite.strict
        ..path = '/login'
        ..secure = _effectiveOrigin(request).startsWith('https:')
        ..maxAge = 300,
    );
    response.headers.contentType = ContentType.html;
    response.write(loginPage(form, failed: response.statusCode == 401));
    await response.close();
  }

  /// Resolves the Flutter web build directory, or `null` if none is found.
  ///
  /// Search order: the `webAppPath` setting (device 0), a `web_app` folder next
  /// to the executable (Windows/Linux) or in the app bundle's `Resources`
  /// (macOS), and `build/web` under the working directory (dev convenience). A
  /// directory only qualifies if it contains `index.html`.
  Directory? _resolveWebAppDir() {
    final cached = _webAppDir;
    if (cached != null &&
        File(
          '${cached.path}${Platform.pathSeparator}'
          'index.html',
        ).existsSync()) {
      return cached;
    }

    final sep = Platform.pathSeparator;
    final candidates = <String>[];
    final configured = _broker.getValue<String>(0, 'webAppPath', '') ?? '';
    if (configured.isNotEmpty) candidates.add(configured);
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir${sep}web_app');
      // macOS .app bundle: the web build is staged under Contents/Resources
      // (Contents/MacOS holds the executable) so it is sealed by code signing.
      candidates.add('$exeDir$sep..${sep}Resources${sep}web_app');
    } catch (_) {
      // resolvedExecutable may be unavailable in some test hosts.
    }
    candidates.add('build${sep}web');

    for (final path in candidates) {
      final dir = Directory(path);
      if (dir.existsSync() &&
          File('${dir.path}${Platform.pathSeparator}index.html').existsSync()) {
        _webAppDir = dir;
        return dir;
      }
    }
    return null;
  }

  /// Loads a bundled asset (from the desktop app's own asset bundle),
  /// returning its bytes or `null` if it does not exist.
  Future<List<int>?> _tryLoadAsset(String assetKey) async {
    try {
      final data = await rootBundle.load(assetKey);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  /// Returns the MIME content type for [path] based on its file extension,
  /// mirroring the C# `GetMimeType` switch (with a few common additions).
  static ContentType _contentTypeFor(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'html':
      case 'htm':
        return ContentType.html;
      case 'css':
        return ContentType('text', 'css', charset: 'utf-8');
      case 'js':
      case 'mjs':
        return ContentType('application', 'javascript', charset: 'utf-8');
      case 'json':
        return ContentType('application', 'json', charset: 'utf-8');
      case 'webmanifest':
        return ContentType('application', 'manifest+json', charset: 'utf-8');
      case 'png':
        return ContentType('image', 'png');
      case 'jpg':
      case 'jpeg':
        return ContentType('image', 'jpeg');
      case 'gif':
        return ContentType('image', 'gif');
      case 'svg':
        return ContentType('image', 'svg+xml');
      case 'ico':
        return ContentType('image', 'x-icon');
      case 'txt':
        return ContentType.text;
      default:
        return ContentType('application', 'octet-stream');
    }
  }
}
