/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/winlink/winlink_client.dart';
import 'package:htcommander/winlink/winlink_mail.dart';

int _commandCount(String transcript, String command) =>
    RegExp('(?:^|\\r)$command\\r').allMatches(transcript).length;

String _checksumHex(String value) {
  final sum = ascii.encode(value).fold<int>(0, (total, byte) => total + byte);
  return ((-sum) & 0xff).toRadixString(16).padLeft(2, '0').toUpperCase();
}

Future<void> _waitFor(
  bool Function() predicate,
  String Function() failureMessage,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: failureMessage());
}

void main() {
  test('waits for more proposals or FQ after receiving mail', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final acceptedSocket = Completer<Socket>();
    server.listen(acceptedSocket.complete);

    final states = <String>[];
    final broker = DataBrokerClient();
    broker.subscribe(
      deviceId: 1,
      name: 'WinlinkConnectionState',
      callback: (_, _, data) => states.add(data! as String),
    );

    final client = WinlinkClient();
    Socket? peer;
    try {
      expect(
        await client.connectTcp(
          InternetAddress.loopbackIPv4.address,
          server.port,
        ),
        isTrue,
      );
      peer = await acceptedSocket.future;

      var transcript = '';
      peer.listen((data) => transcript += utf8.decode(data));
      peer.add(utf8.encode('CMS >\r'));
      await peer.flush();
      await _waitFor(
        () => _commandCount(transcript, 'FF') == 1,
        () => 'Initial FF not received: $transcript',
      );

      final mail = WinLinkMail()
        ..mid = 'ABCDEF123456'
        ..from = 'SENDER'
        ..to = 'RECIPIENT'
        ..subject = 'Protocol close test'
        ..body = 'Test message';
      final encoded = WinLinkMail.encodeMailToBlocks(mail);
      final proposal =
          'FC EM ${mail.mid} ${encoded.uncompressedSize} ${encoded.compressedSize} 0\r';
      peer.add(
        utf8.encode(
          '$proposal'
          'F> ${_checksumHex(proposal)}\r',
        ),
      );
      await peer.flush();
      await _waitFor(
        () => transcript.contains('FS Y\r'),
        () => 'Proposal was not accepted: $transcript',
      );

      for (final block in encoded.blocks!) {
        peer.add(block);
      }
      await peer.flush();
      await _waitFor(
        () => _commandCount(transcript, 'FF') == 2,
        () => 'Completion FF not received: $transcript',
      );

      expect(states, isNot(contains('DISCONNECTED')));

      final nextMail = WinLinkMail()
        ..mid = '654321FEDCBA'
        ..from = 'SENDER'
        ..to = 'RECIPIENT'
        ..subject = 'Second batch'
        ..body = 'Another test message';
      final nextEncoded = WinLinkMail.encodeMailToBlocks(nextMail);
      final nextProposal =
          'FC EM ${nextMail.mid} ${nextEncoded.uncompressedSize} ${nextEncoded.compressedSize} 0\r';
      peer.add(
        utf8.encode(
          '$nextProposal'
          'F> ${_checksumHex(nextProposal)}\r',
        ),
      );
      await peer.flush();
      await _waitFor(
        () => _commandCount(transcript, 'FS Y') == 2,
        () => 'Additional proposal was not accepted: $transcript',
      );
      expect(states, isNot(contains('DISCONNECTED')));

      for (final block in nextEncoded.blocks!) {
        peer.add(block);
      }
      await peer.flush();
      await _waitFor(
        () => _commandCount(transcript, 'FF') == 3,
        () => 'Second completion FF not received: $transcript',
      );

      peer.add(utf8.encode('FQ\r'));
      await peer.flush();
      await _waitFor(
        () => states.contains('DISCONNECTED'),
        () => 'FQ did not close the session; states: $states',
      );
    } finally {
      client.dispose();
      broker.dispose();
      peer?.destroy();
      await server.close();
    }
  });

  test('keeps Winlink busy across the TCP retry gap and reconnect', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var acceptedCount = 0;
    final peers = <Socket>[];
    final serverSubscription = server.listen((socket) {
      acceptedCount++;
      peers.add(socket);
      if (acceptedCount == 1) socket.destroy();
    });

    final busyStates = <bool>[];
    final connectionStates = <String>[];
    final stateBroker = DataBrokerClient();
    stateBroker.subscribe(
      deviceId: 1,
      name: 'WinlinkConnectionState',
      callback: (_, _, data) => connectionStates.add(data! as String),
    );
    stateBroker.subscribe(
      deviceId: 1,
      name: 'WinlinkBusy',
      callback: (_, _, data) => busyStates.add(data! as bool),
    );
    final client = WinlinkClient(
      tcpRetryDelay: const Duration(milliseconds: 250),
      maxTcpRetries: 1,
    );
    try {
      await client.connectTcp(InternetAddress.loopbackIPv4.address, server.port);
      await _waitFor(
        () => acceptedCount == 1 && busyStates.isNotEmpty,
        () => 'First TCP connection was not observed; accepted=$acceptedCount, busy=$busyStates',
      );
      await _waitFor(
        () => connectionStates.contains('DISCONNECTED') && busyStates.last,
        () => 'TCP connection did not enter a busy retry gap; states=$connectionStates, busy=$busyStates',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(acceptedCount, 1, reason: 'retry should wait for its backoff');
      expect(
        busyStates,
        [true],
        reason: 'no idle state may be published in the retry gap',
      );

      await _waitFor(
        () =>
            acceptedCount == 2 &&
            connectionStates.isNotEmpty &&
            connectionStates.last == 'CONNECTED',
        () =>
            'TCP retry did not reconnect; accepted=$acceptedCount, busy=$busyStates',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        busyStates,
        [true],
        reason: 'reconnect must not publish an idle pulse',
      );

      client.disconnectTcp();
      await _waitFor(
        () => busyStates.isNotEmpty && !busyStates.last,
        () => 'explicit disconnect did not clear Winlink busy state: $busyStates',
      );
    } finally {
      client.dispose();
      stateBroker.dispose();
      for (final peer in peers) {
        peer.destroy();
      }
      await serverSubscription.cancel();
      await server.close();
    }
  });

  test('cancelling a pending Winlink retry stops further TCP attempts', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var acceptedCount = 0;
    final peers = <Socket>[];
    final serverSubscription = server.listen((socket) {
      acceptedCount++;
      peers.add(socket);
      socket.destroy();
    });

    final busyStates = <bool>[];
    final connectionStates = <String>[];
    final stateBroker = DataBrokerClient();
    stateBroker.subscribe(
      deviceId: 1,
      name: 'WinlinkConnectionState',
      callback: (_, _, data) => connectionStates.add(data! as String),
    );
    stateBroker.subscribe(
      deviceId: 1,
      name: 'WinlinkBusy',
      callback: (_, _, data) => busyStates.add(data! as bool),
    );
    final client = WinlinkClient(
      tcpRetryDelay: const Duration(milliseconds: 250),
      maxTcpRetries: 1,
    );
    try {
      await client.connectTcp(InternetAddress.loopbackIPv4.address, server.port);
      await _waitFor(
        () => acceptedCount == 1 && busyStates.isNotEmpty,
        () => 'Initial connection was not observed; accepted=$acceptedCount, busy=$busyStates',
      );
      await _waitFor(
        () => connectionStates.contains('DISCONNECTED') && busyStates.last,
        () => 'TCP connection did not enter a busy retry gap; states=$connectionStates, busy=$busyStates',
      );
      DataBroker.dispatch(
        deviceId: 1,
        name: 'WinlinkDisconnect',
        data: true,
        store: false,
      );
      await _waitFor(
        () => busyStates.isNotEmpty && !busyStates.last,
        () => 'cancel did not clear Winlink busy state: $busyStates',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(acceptedCount, 1, reason: 'cancelled retry must not reconnect');
      expect(busyStates.last, isFalse);
    } finally {
      client.dispose();
      stateBroker.dispose();
      for (final peer in peers) {
        peer.destroy();
      }
      await serverSubscription.cancel();
      await server.close();
    }
  });

  test('clears Winlink busy state after TCP retries are exhausted', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var acceptedCount = 0;
    final peers = <Socket>[];
    final serverSubscription = server.listen((socket) {
      acceptedCount++;
      peers.add(socket);
      socket.destroy();
    });

    final busyStates = <bool>[];
    final stateBroker = DataBrokerClient();
    stateBroker.subscribe(
      deviceId: 1,
      name: 'WinlinkBusy',
      callback: (_, _, data) => busyStates.add(data! as bool),
    );
    final client = WinlinkClient(
      tcpRetryDelay: const Duration(milliseconds: 25),
      maxTcpRetries: 1,
    );
    try {
      await client.connectTcp(InternetAddress.loopbackIPv4.address, server.port);
      await _waitFor(
        () => acceptedCount == 2 &&
            busyStates.isNotEmpty &&
            !busyStates.last,
        () => 'Retry exhaustion did not finish cleanly; accepted=$acceptedCount, busy=$busyStates',
      );
      expect(busyStates.first, isTrue);
      expect(busyStates.last, isFalse);
      expect(busyStates.where((state) => !state).length, 1);
    } finally {
      client.dispose();
      stateBroker.dispose();
      for (final peer in peers) {
        peer.destroy();
      }
      await serverSubscription.cancel();
      await server.close();
    }
  });
}
