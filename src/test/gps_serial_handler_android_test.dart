import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_serial_communication/flutter_serial_communication.dart';
import 'package:flutter_serial_communication/models/device_info.dart';
import 'package:htcommander/gps/gps_data.dart';
import 'package:htcommander/gps/gps_serial_handler.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  tearDown(DataBroker.reset);

  test('Android USB GPS opens selected device and decodes NMEA bytes', () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final input = StreamController<Uint8List>.broadcast();
    final connectionStatus = StreamController<bool>.broadcast();
    final usb = _FakeAndroidUsbSerial();
    final handler = GpsSerialHandler(
      androidUsbSerial: usb,
      androidUsbData: () => input.stream,
      androidUsbConnectionStatus: () => connectionStatus.stream,
    );
    DataBroker.dispatch(deviceId: 0, name: 'GpsSerialPort', data: 'USB:42');
    DataBroker.dispatch(deviceId: 0, name: 'GpsBaudRate', data: 9600);

    try {
      handler.init();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(usb.connectedDeviceId, 42);
      expect(usb.connectedBaudRate, 9600);
      expect(usb.configuredBaudRate, 9600);

      input.add(
        Uint8List.fromList(
          utf8.encode(
            '\$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final gps = DataBroker.getValue<GpsData>(1, 'GpsData');
      expect(gps, isNotNull);
      expect(gps!.latitude, closeTo(48.1173, 0.0001));
      expect(gps.longitude, closeTo(11.5166667, 0.0001));
      expect(gps.isFixed, isTrue);
      expect(DataBroker.getValue<String>(1, 'GpsStatus'), 'Communicating');

      connectionStatus.add(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(usb.disconnectCount, 1);
      expect(DataBroker.getValue<String>(1, 'GpsStatus'), 'PortError');
    } finally {
      await handler.dispose();
      await input.close();
      await connectionStatus.close();
      debugDefaultTargetPlatformOverride = previousPlatform;
    }

    expect(usb.disconnectCount, 1);
  });
}

class _FakeAndroidUsbSerial extends FlutterSerialCommunication {
  final devices = [
    DeviceInfo(
      deviceId: 42,
      deviceName: 'USB GPS',
      manufacturerName: 'Test',
      productName: 'NMEA receiver',
    ),
  ];
  int? connectedDeviceId;
  int? connectedBaudRate;
  int? configuredBaudRate;
  int disconnectCount = 0;

  @override
  Future<List<DeviceInfo>> getAvailableDevices() async => devices;

  @override
  Future<bool> connect(DeviceInfo deviceInfo, int baudRate) async {
    connectedDeviceId = deviceInfo.deviceId;
    connectedBaudRate = baudRate;
    return true;
  }

  @override
  Future<void> setParameters(
    int baudRate,
    int dataBits,
    int stopBits,
    int parity,
  ) async {
    configuredBaudRate = baudRate;
  }

  @override
  Future<void> setDTR(bool set) async {}

  @override
  Future<void> setRTS(bool set) async {}

  @override
  Future<void> disconnect() async {
    disconnectCount++;
  }
}
