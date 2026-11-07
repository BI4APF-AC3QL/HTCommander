/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

//
// aprsis_network_io.dart - dart:io TCP transport for the APRS-IS client.
//
// Opens a plain TCP connection to an APRS-IS server with Nagle's algorithm
// disabled (TCP_NODELAY), as recommended for bidirectional APRS-IS clients so
// small message packets are not delayed. Not exercised by unit tests (real
// sockets); the client's logic is tested against a fake network.
//

import 'dart:async';
import 'dart:io';

import 'aprsis_client.dart';

class DartIoAprsIsNetwork implements AprsIsNetwork {
  DartIoAprsIsNetwork({this.connectTimeout = const Duration(seconds: 15)});

  final Duration connectTimeout;

  Socket? _socket;
  bool _closed = false;
  StreamSubscription<List<int>>? _sub;
  final StreamController<String> _incoming = StreamController<String>();
  final Completer<void> _done = Completer<void>();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> connect(String host, int port) async {
    if (_closed) return;
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    if (_closed) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _sub = socket.listen(
      _onData,
      onError: _onDone,
      onDone: () => _onDone(null),
      cancelOnError: true,
    );
  }

  void _onData(List<int> data) {
    // APRS-IS is Latin-1/ASCII on the wire but may carry non-UTF-8 bytes; decode
    // permissively so a stray byte never tears down the stream.
    final text = String.fromCharCodes(data);
    if (!_incoming.isClosed) _incoming.add(text);
  }

  void _onDone(Object? error) {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void sendLine(String line) {
    final socket = _socket;
    if (socket == null) return;
    socket.write('$line\r\n');
  }

  @override
  Future<void> close() async {
    _closed = true;
    // Destroy immediately: graceful socket flush can wait on an unreachable
    // peer. This also makes a connection completing after close harmless.
    _socket?.destroy();
    _socket = null;
    await _sub?.cancel();
    _sub = null;
    // StreamController.close waits for a listener; failed connects have none.
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }
}
