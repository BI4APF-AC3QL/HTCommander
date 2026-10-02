import 'dart:async';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/aprs/aprs_events.dart';
import 'package:htcommander/aprs/aprs_packet.dart';
import 'package:htcommander/aprsis/aprsis_client.dart';
import 'package:htcommander/aprsis/aprsis_manager.dart';
import 'package:htcommander/aprsis/aprsis_network_io.dart';
import 'package:htcommander/aprsis/tnc2_codec.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/models/radio_models.dart';
import 'package:htcommander/radio/radio.dart';

class FakeNetwork implements AprsIsNetwork {
  // A real async cancellation future belongs to the fake clock's zone,
  // unlike dart:async's shared already-completed no-op cancellation future.
  final input = StreamController<String>(
    sync: true,
    onCancel: () => Future<void>.value(),
  );
  final finished = Completer<void>();
  final connecting = Completer<void>();
  final sent = <String>[];
  String? host;
  int closes = 0;
  bool failSend = false;
  @override
  Future<void> connect(String host, int port) {
    this.host = host;
    return connecting.future;
  }

  void ready() => connecting.complete();
  void login() => input.add('# logresp W1AW verified, server TEST\n');
  @override
  Stream<String> get incoming => input.stream;
  @override
  Future<void> get done => finished.future;
  @override
  void sendLine(String line) {
    if (failSend) throw StateError('simulated write failure');
    sent.add(line);
  }

  @override
  Future<void> close() async {
    closes++;
    if (!finished.isCompleted) finished.complete();
    if (!input.isClosed) unawaited(input.close());
  }
}

void set(String name, Object data) =>
    DataBroker.dispatch(deviceId: 0, name: name, data: data);
void rf(int i) {
  final packet = Tnc2Codec.decode('K7VZT>APRS:>test$i')!;
  DataBroker.dispatch(
    deviceId: 1,
    name: 'AprsFrame',
    data: AprsFrameEventArgs(AprsPacket.parse(packet)!, packet, null),
    store: false,
  );
}

Map metrics() => DataBroker.getValueDynamic(201, 'GateMetrics') as Map;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    DataBroker.reset();
    set('CallSign', 'W1AW');
    set('AprsIsEnabled', 1);
  });
  tearDown(DataBroker.reset);

  test(
    'disable while TCP is pending closes late connection and never logs in',
    () {
      fakeAsync((time) {
        final network = FakeNetwork();
        final manager = AprsIsManager(networkFactory: () => network)..init();
        set('AprsIsEnabled', 0);
        time.flushMicrotasks();
        expect(network.closes, greaterThan(0));
        network.ready();
        time.flushMicrotasks();
        expect(network.sent, isEmpty);
        time.elapse(const Duration(minutes: 5));
        expect(metrics()['reconnectAttempts'], 0);
        unawaited(manager.dispose());
        time.flushMicrotasks();
        expect(time.periodicTimerCount, 0);
        expect(time.nonPeriodicTimerCount, 0);
      });
    },
  );

  test('setting change during connect reconciles newest server, once', () {
    fakeAsync((time) {
      final networks = <FakeNetwork>[];
      final manager = AprsIsManager(
        networkFactory: () {
          final network = FakeNetwork();
          networks.add(network);
          return network;
        },
      )..init();
      set('AprsIsServer', 'first.example');
      set('AprsIsServer', 'latest.example');
      networks.first.ready();
      time.flushMicrotasks();
      expect(networks.length, 2);
      expect(networks.first.sent, isEmpty);
      expect(networks.last.host, 'latest.example');
      networks.last.ready();
      time.flushMicrotasks();
      networks.last.login();
      set('AprsIsServer', 'latest.example');
      time.flushMicrotasks();
      expect(networks.length, 2);
      unawaited(manager.dispose());
      time.flushMicrotasks();
    });
  });

  test('dispose during connect cannot resurrect client or retry timers', () {
    fakeAsync((time) {
      final network = FakeNetwork();
      final manager = AprsIsManager(networkFactory: () => network)..init();
      unawaited(manager.dispose());
      time.flushMicrotasks();
      network.ready();
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 5));
      expect(network.sent, isEmpty);
      expect(time.nonPeriodicTimerCount, 0);
      expect(time.periodicTimerCount, 0);
    });
  });

  test(
    'connect failures clean transport; retries double, cap and reset on login',
    () {
      fakeAsync((time) {
        final networks = <FakeNetwork>[];
        final manager = AprsIsManager(
          retryRandom: () => 0.5,
          clock: () => time.getClock(DateTime.utc(2026)).now(),
          networkFactory: () {
            final network = FakeNetwork();
            networks.add(network);
            return network;
          },
        )..init();
        for (final seconds in [5, 10, 20, 40, 80, 120, 120]) {
          final oldCount = networks.length;
          networks.last.connecting.completeError(StateError('offline'));
          time.flushMicrotasks();
          expect(networks.last.closes, greaterThan(0));
          time.elapse(Duration(seconds: seconds - 1));
          expect(networks.length, oldCount);
          time.elapse(const Duration(seconds: 1));
          expect(networks.length, oldCount + 1);
        }
        networks.last.ready();
        time.flushMicrotasks();
        networks.last.login();
        networks.last.finished.completeError(StateError('lost session'));
        time.flushMicrotasks();
        final count = networks.length;
        time.elapse(const Duration(seconds: 5));
        expect(networks.length, count + 1);
        expect(metrics()['connectionFailures'], 7);
        expect(metrics()['disconnects'], 1);
        unawaited(manager.dispose());
        time.flushMicrotasks();
      });
    },
  );

  test('silent login times out and disabling cancels pending backoff', () {
    fakeAsync((time) {
      final networks = <FakeNetwork>[];
      final manager = AprsIsManager(
        networkFactory: () {
          final network = FakeNetwork();
          networks.add(network);
          return network;
        },
      )..init();
      networks.first.ready();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 20));
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 1));
      expect(metrics()['failureReason'], 'loginTimeout');
      expect(networks.first.closes, greaterThan(0));
      set('AprsIsEnabled', 0);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 5));
      expect(networks.length, 1);
      expect(metrics()['nextRetryAt'], isNull);
      unawaited(manager.dispose());
      time.flushMicrotasks();
    });
  });

  test(
    'manager bounds disconnected queue, drops duplicates and expires backlog',
    () {
      fakeAsync((time) {
        final network = FakeNetwork();
        final manager = AprsIsManager(
          networkFactory: () => network,
          clock: () => time.getClock(DateTime.utc(2026)).now(),
        )..init();
        for (var i = 0; i < 40; i++) {
          rf(i);
        }
        rf(0);
        time.elapse(const Duration(seconds: 1));
        expect(metrics()['queueDepth'], 32);
        expect(metrics()['queueOverflow'], 8);
        expect(metrics()['queueDuplicates'], 1);
        time.elapse(const Duration(seconds: 30));
        expect(metrics()['queueDepth'], 0);
        expect(metrics()['queueExpired'], 32);
        network.ready();
        time.flushMicrotasks();
        network.login();
        time.elapse(const Duration(seconds: 1));
        expect(
          network.sent.where((line) => !line.startsWith('user ')),
          isEmpty,
        );
        unawaited(manager.dispose());
        time.flushMicrotasks();
      });
    },
  );

  test(
    'verified manager paces forwarding, rejects duplicate replay and counts write failure',
    () {
      fakeAsync((time) {
        final network = FakeNetwork();
        final manager = AprsIsManager(
          networkFactory: () => network,
          clock: () => time.getClock(DateTime.utc(2026)).now(),
        )..init();
        network.ready();
        time.flushMicrotasks();
        network.login();
        rf(1);
        rf(2);
        time.elapse(const Duration(seconds: 1));
        expect(network.sent.length, 2);
        expect(network.sent.last, contains(',qAR,W1AW:>test1'));
        rf(1);
        time.elapse(const Duration(seconds: 2));
        expect(network.sent.length, 3);
        expect(metrics()['duplicateDrops'], 1);
        network.failSend = true;
        rf(3);
        time.elapse(const Duration(seconds: 1));
        expect(metrics()['sendErrors'], 1);
        unawaited(manager.dispose());
        time.flushMicrotasks();
      });
    },
  );

  test(
    'IO transport close finishes without listener after failed/aborted connect',
    () async {
      final network = DartIoAprsIsNetwork();
      await network.close().timeout(const Duration(seconds: 1));
      await network.connect('127.0.0.1', 1);
      await network.done;
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = listener.first;
      final connected = DartIoAprsIsNetwork();
      await connected.connect('127.0.0.1', listener.port);
      final peer = await accepted;
      await connected.close().timeout(const Duration(seconds: 1));
      peer.destroy();
      await listener.close();
    },
  );

  test(
    'forwarding matrix enforces host permission, heard stations, paths, rate and encapsulation',
    () {
      fakeAsync((time) {
        final network = FakeNetwork();
        final observer = DataBrokerClient();
        final sent = <TransmitDataFrameData>[];
        var cancels = 0;
        observer.subscribe(
          deviceId: 2,
          name: 'TransmitDataFrame',
          callback: (_, _, value) => sent.add(value as TransmitDataFrameData),
        );
        observer.subscribe(
          deviceId: DataBroker.allDevices,
          name: 'CancelGatewayFrames',
          callback: (_, _, _) => cancels++,
        );
        final manager = AprsIsManager(
          networkFactory: () => network,
          clock: () => time.getClock(DateTime.utc(2026)).now(),
        )..init();
        network.ready();
        time.flushMicrotasks();
        network.login();
        DataBroker.dispatch(
          deviceId: 1,
          name: 'ConnectedRadios',
          data: [
            {'DeviceId': 2},
          ],
        );
        void status({bool busy = false}) => DataBroker.dispatch(
          deviceId: 2,
          name: 'HtStatus',
          data: {'isPowerOn': true, 'isInTx': false, 'isInRx': busy},
        );
        void channels({bool disabled = false}) => DataBroker.dispatch(
          deviceId: 2,
          name: 'Channels',
          data: [
            RadioChannelInfo(
              channelId: 3,
              name: 'APRS',
              txDisable: disabled,
            ).toJson(),
          ],
        );
        status();
        channels();
        rf(0);
        void message(
          String text, {
          String source = 'N0CALL',
          String path = 'TCPIP*,qAC,TEST',
          String to = 'K7VZT',
        }) =>
            network.input.add('$source>APRS,$path::${to.padRight(9)}:$text\n');
        message('disabled');
        expect(sent, isEmpty);
        set('AprsIsGateToRf', 1);
        message('no-tx');
        expect(sent, isEmpty);
        set('AllowTransmit', 1);
        network.input.add('# logresp W1AW unverified, server TEST\n');
        message('unverified');
        expect(sent, isEmpty);
        network.login();
        message('unknown', to: 'N1TEST');
        message('local source', source: 'K7VZT');
        for (final path in ['TCPXX', 'NOGATE', 'RFONLY', 'qAX,TEST']) {
          message('blocked $path', path: path);
        }
        message('ack123');
        message('rej123');
        expect(sent, isEmpty);
        status(busy: true);
        message('busy');
        status();
        channels(disabled: true);
        message('rx channel');
        channels();
        expect(sent, isEmpty);
        set('AprsIsRfPath', 'WIDE1-1');
        set('AprsIsRfPerMinute', 1);
        message('hello{1');
        expect(sent.length, 1);
        final packet = sent.single.packet!;
        expect(packet.addresses.map((a) => a.toString()), [
          'APRS',
          'W1AW',
          'WIDE1-1',
        ]);
        expect(packet.dataStr, '}N0CALL>APRS,TCPIP,W1AW*::K7VZT    :hello{1');
        expect(packet.tag, AprsIsManager.gateFrameTag);
        expect(
          packet.deadline,
          time
              .getClock(DateTime.utc(2026))
              .now()
              .add(const Duration(seconds: 15)),
        );
        // Internet path changes do not bypass downlink deduplication.
        message('hello{1', path: 'TCPIP*,qAC,OTHER');
        message('limited');
        expect(sent.length, 1);
        time.elapse(const Duration(seconds: 1));
        expect(metrics()['rfDuplicateDrops'], 1);
        expect(metrics()['rfRateDrops'], 1);
        // Echoing the encapsulated outgoing packet onto RF must not up-gate it.
        packet.incoming = true;
        DataBroker.dispatch(
          deviceId: 1,
          name: 'AprsFrame',
          data: AprsFrameEventArgs(AprsPacket.parse(packet)!, packet, null),
          store: false,
        );
        time.elapse(const Duration(seconds: 1));
        expect(network.sent.where((line) => line.contains('hello')), isEmpty);
        final previousCancels = cancels;
        set('AprsIsGateToRf', 0);
        expect(cancels, greaterThan(previousCancels));
        message('after disable');
        expect(sent.length, 1);
        final health = DataBroker.getValueDynamic(201, 'GateHealth') as List;
        expect(health.single['toRfRequested'], 1);
        expect(health.single['receivedRf'], 2);
        expect(health.single['receivedIs'], greaterThan(10));
        expect(health.single.toString(), isNot(contains('N0CALL')));
        unawaited(manager.dispose());
        time.flushMicrotasks();
        observer.dispose();
      });
    },
  );

  test(
    'outbound RF never qualifies station; heard eligibility expires without downlink replay',
    () {
      fakeAsync((time) {
        final network = FakeNetwork();
        var sends = 0;
        final observer = DataBrokerClient()
          ..subscribe(
            deviceId: 2,
            name: 'TransmitDataFrame',
            callback: (_, _, _) => sends++,
          );
        final manager = AprsIsManager(
          networkFactory: () => network,
          clock: () => time.getClock(DateTime.utc(2026)).now(),
        )..init();
        network.ready();
        time.flushMicrotasks();
        network.login();
        set('AllowTransmit', 1);
        set('AprsIsGateToRf', 1);
        DataBroker.dispatch(
          deviceId: 1,
          name: 'ConnectedRadios',
          data: [
            {'DeviceId': 2},
          ],
        );
        DataBroker.dispatch(
          deviceId: 2,
          name: 'Channels',
          data: [RadioChannelInfo(channelId: 3, name: 'APRS').toJson()],
        );
        DataBroker.dispatch(
          deviceId: 2,
          name: 'HtStatus',
          data: {'isPowerOn': true},
        );
        final outbound = Tnc2Codec.decode('N1TEST>APRS:>local outgoing')!
          ..incoming = false;
        DataBroker.dispatch(
          deviceId: 1,
          name: 'AprsFrame',
          data: AprsFrameEventArgs(AprsPacket.parse(outbound)!, outbound, null),
          store: false,
        );
        network.input.add('N0CALL>APRS,TCPIP*::N1TEST   :not locally heard\n');
        expect(sends, 0);
        rf(1);
        time.elapse(const Duration(minutes: 61));
        network.input.add('N0CALL>APRS,TCPIP*::K7VZT    :heard too long ago\n');
        expect(sends, 0);
        unawaited(manager.dispose());
        time.flushMicrotasks();
        observer.dispose();
      });
    },
  );
}
