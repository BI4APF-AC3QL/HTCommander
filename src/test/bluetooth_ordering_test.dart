import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/radio/bluetooth_classic_transport.dart';
import 'package:htcommander/radio/radio_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const classicMethod = MethodChannel('com.htcommander/bluetooth_classic');
  const classicData = MethodChannel('com.htcommander/bluetooth_classic_data');
  const classicAudio = MethodChannel('com.htcommander/bluetooth_classic_audio');
  const codec = StandardMethodCodec();

  void mockClassicEventChannels() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(classicData, (_) async => null);
    messenger.setMockMethodCallHandler(classicAudio, (_) async => null);
  }

  test(
    'captures RX during connect, keeps writes FIFO and cancels stale commands',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      mockClassicEventChannels();
      final writes = <int>[];
      final gates = <Completer<bool>>[];
      messenger.setMockMethodCallHandler(classicMethod, (call) async {
        if (call.method == 'connect') {
          await messenger.handlePlatformMessage(
            'com.htcommander/bluetooth_classic_data',
            codec.encodeSuccessEnvelope({
              'event': 'data',
              'address': 'AA:BB:CC:DD:EE:FF',
              'data': Uint8List.fromList([7, 8]),
            }),
            (_) {},
          );
          await Future<void>.delayed(Duration.zero);
          return true;
        }
        if (call.method == 'send') {
          writes.add((call.arguments['data'] as Uint8List).first);
          final gate = Completer<bool>();
          gates.add(gate);
          return gate.future;
        }
        return true;
      });
      final transport = BluetoothClassicTransport();
      final received = <int>[];
      final sub = transport.dataStream.listen(received.addAll);
      expect(
        await transport.connect(
          DiscoveredDevice(
            id: 'AA:BB:CC:DD:EE:FF',
            name: 'VR-N7500',
            type: BluetoothType.classic,
          ),
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, [7, 8]);
      final a = transport.send(Uint8List.fromList([1]));
      final b = transport.send(Uint8List.fromList([2]));
      final c = transport.send(Uint8List.fromList([3]));
      await Future<void>.delayed(Duration.zero);
      expect(writes, [1]);
      gates[0].complete(true);
      expect(await a, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(writes, [1, 2]);
      await transport.disconnect();
      gates[1].complete(true);
      expect(await b, isTrue);
      expect(await c, isFalse);
      expect(writes, [1, 2]);
      await sub.cancel();
      await transport.dispose();
      messenger.setMockMethodCallHandler(classicMethod, null);
    },
  );

  test('disconnect before native connect prevents opening RFCOMM', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    mockClassicEventChannels();
    var connectCalls = 0;
    messenger.setMockMethodCallHandler(classicMethod, (call) async {
      if (call.method == 'connect') connectCalls++;
      return true;
    });

    final transport = BluetoothClassicTransport();
    final connecting = transport.connect(
      DiscoveredDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'VR-N7500',
        type: BluetoothType.classic,
      ),
    );
    final disconnecting = transport.disconnect();

    await disconnecting;
    expect(await connecting, isFalse);
    expect(connectCalls, 0);
    expect(transport.state, TransportState.disconnected);

    await transport.dispose();
    messenger.setMockMethodCallHandler(classicMethod, null);
  });

  test(
    'late native connect success is disconnected after cancellation',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      mockClassicEventChannels();
      final nativeConnect = Completer<bool>();
      var connectCalls = 0;
      var disconnectCalls = 0;
      messenger.setMockMethodCallHandler(classicMethod, (call) async {
        if (call.method == 'connect') {
          connectCalls++;
          return nativeConnect.future;
        }
        if (call.method == 'disconnect') {
          disconnectCalls++;
          return true;
        }
        return true;
      });

      final transport = BluetoothClassicTransport();
      final connecting = transport.connect(
        DiscoveredDevice(
          id: 'AA:BB:CC:DD:EE:FF',
          name: 'VR-N7500',
          type: BluetoothType.classic,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(connectCalls, 1);

      await transport.disconnect();
      expect(transport.state, TransportState.disconnected);
      nativeConnect.complete(true);

      expect(await connecting, isFalse);
      expect(disconnectCalls, 2);
      expect(transport.state, TransportState.disconnected);

      await transport.dispose();
      messenger.setMockMethodCallHandler(classicMethod, null);
    },
  );
}
