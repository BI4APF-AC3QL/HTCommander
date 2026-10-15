import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/radio/gaia_protocol.dart';
import 'package:htcommander/radio/radio_transport.dart';
import 'package:htcommander/services/bluetooth_service.dart';
import 'package:htcommander/services/data_broker.dart';

/// Exercises the Android Classic Bluetooth path against mocked native
/// channels. No Bluetooth hardware, radio frames, or RF transmission is used.
Future<void> exerciseAndroidBluetoothClassicConnection({
  Future<void> Function(int radioId, List<Uint8List> writes)? onConnected,
}) async {
  const permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );
  const classicMethodChannel = MethodChannel(
    'com.htcommander/bluetooth_classic',
  );
  const classicDataChannel = MethodChannel(
    'com.htcommander/bluetooth_classic_data',
  );
  const classicAudioChannel = MethodChannel(
    'com.htcommander/bluetooth_classic_audio',
  );

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bluetooth = BluetoothService();
  const fakeAddress = '02:00:00:00:00:75';
  final originalRememberedRadios = bluetooth.previouslyConnectedRadioMacs();
  final priorConnectionIds = bluetooth.connectedRadioIds.toSet();
  final writes = <Uint8List>[];
  var nativeConnectCalls = 0;
  var nativeSendCalls = 0;
  var nativeDisconnectCalls = 0;

  messenger.setMockMethodCallHandler(permissionChannel, (call) async {
    if (call.method == 'checkPermissionStatus') return 1; // granted
    if (call.method == 'requestPermissions') {
      final permissions = (call.arguments as List).cast<int>();
      return <int, int>{for (final permission in permissions) permission: 1};
    }
    return null;
  });
  // EventChannel listen/cancel calls are accepted, but no radio frames are
  // synthesized. This exercises the platform bridge without hardware or RF.
  messenger.setMockMethodCallHandler(classicDataChannel, (_) async => null);
  messenger.setMockMethodCallHandler(classicAudioChannel, (_) async => null);
  messenger.setMockMethodCallHandler(classicMethodChannel, (call) async {
    final arguments = call.arguments is Map
        ? Map<Object?, Object?>.from(call.arguments as Map)
        : const <Object?, Object?>{};
    if (call.method == 'connect') {
      expect(arguments['address'], fakeAddress);
      nativeConnectCalls++;
      return true;
    }
    if (call.method == 'send') {
      expect(arguments['address'], fakeAddress);
      nativeSendCalls++;
      final data = arguments['data'];
      if (data is List) {
        writes.add(Uint8List.fromList(data.whereType<int>().toList()));
      }
      return true;
    }
    if (call.method == 'disconnect') {
      expect(arguments['address'], fakeAddress);
      nativeDisconnectCalls++;
      return true;
    }
    return true;
  });

  try {
    final radioId = await bluetooth.connectToRadio(
      fakeAddress,
      'VR-N7500 Android integration fixture',
      bluetoothType: BluetoothType.classic,
    );
    expect(
      radioId,
      isNotNull,
      reason: 'the fake RFCOMM connect should succeed',
    );
    expect(nativeConnectCalls, 1);
    expect(bluetooth.connectedRadioIds, contains(radioId));
    expect(
      DataBroker.getValue<String>(radioId!, 'State'),
      'Connected',
      reason: 'the Bluetooth service should publish a live Classic radio',
    );
    expect(
      bluetooth.previouslyConnectedRadioMacs(),
      contains(fakeAddress),
      reason:
          'a successful Classic connection must be remembered for reconnect',
    );

    // Radio startup is deliberately receive/query-only. Give it time to queue
    // its safe initialization reads through the Android method-channel bridge.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(
      nativeSendCalls,
      greaterThan(0),
      reason: 'initial read commands should reach the native Classic bridge',
    );
    expect(
      writes,
      isNotEmpty,
      reason: 'initial read command bytes should be captured',
    );
    expect(
      writes.every(
        (frame) =>
            frame.length >= 8 &&
            frame[0] == 0xFF &&
            frame[1] == 0x01 &&
            frame[4] == 0 &&
            frame[5] == RadioCommandGroup.basic.value &&
            frame[6] == 0,
      ),
      isTrue,
      reason: 'Classic commands should use GAIA serial framing',
    );
    final commandIds = writes.map((frame) => frame[7]).toSet();
    expect(
      commandIds.difference({
        RadioBasicCommand.getDevInfo.value,
        RadioBasicCommand.readStatus.value,
        RadioBasicCommand.readSettings.value,
        RadioBasicCommand.readBssSettings.value,
        RadioBasicCommand.getAprsPath.value,
      }),
      isEmpty,
      reason: 'startup traffic must stay limited to receive/query commands',
    );

    await onConnected?.call(radioId, writes);

    await bluetooth.disconnectRadio(radioId);
    expect(bluetooth.connectedRadioIds, isNot(contains(radioId)));
    expect(DataBroker.getValue<String>(radioId, 'State'), 'Disconnected');
    expect(
      bluetooth.previouslyConnectedRadioMacs(),
      isNot(contains(fakeAddress)),
      reason: 'an explicit disconnect must cancel future automatic reconnects',
    );
    expect(nativeDisconnectCalls, greaterThanOrEqualTo(1));
  } finally {
    for (final radioId in bluetooth.connectedRadioIds.toList()) {
      if (!priorConnectionIds.contains(radioId)) {
        await bluetooth.disconnectRadio(radioId);
      }
    }
    DataBroker.dispatch(
      deviceId: 0,
      name: BluetoothService.previouslyConnectedRadiosKey,
      data: originalRememberedRadios,
      store: true,
    );
    messenger.setMockMethodCallHandler(classicMethodChannel, null);
    messenger.setMockMethodCallHandler(classicDataChannel, null);
    messenger.setMockMethodCallHandler(classicAudioChannel, null);
    messenger.setMockMethodCallHandler(permissionChannel, null);
  }
}
