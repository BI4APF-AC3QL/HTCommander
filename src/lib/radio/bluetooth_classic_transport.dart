/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'dart:async';
import 'dart:typed_data';

import '../services/bluetooth_classic_macos.dart';
import '../services/data_broker_client.dart';
import 'radio_transport.dart';

/// RadioTransport implementation using Bluetooth Classic (RFCOMM)
/// Uses BluetoothClassicMacOS for native macOS Bluetooth connections
class BluetoothClassicTransport implements RadioTransport {
  final _stateController = StreamController<TransportState>.broadcast();
  late final StreamController<Uint8List> _dataController;
  final List<Uint8List> _startupData = [];
  int _startupBytes = 0;
  final _scanController = StreamController<DiscoveredDevice>.broadcast();
  final DataBrokerClient _broker = DataBrokerClient();

  Future<void> _sendTail = Future<void>.value();
  int _connectionGeneration = 0;
  int _queuedWrites = 0;
  TransportState _state = TransportState.disconnected;
  DiscoveredDevice? _connectedDevice;
  StreamSubscription<Uint8List>? _dataSubscription;
  StreamSubscription<BluetoothClassicEvent>? _connectionSubscription;

  @override
  TransportState get state => _state;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  Stream<Uint8List> get dataStream => _dataController.stream;

  @override
  Stream<DiscoveredDevice> get scanStream => _scanController.stream;

  @override
  DiscoveredDevice? get connectedDevice => _connectedDevice;

  void _logInfo(String msg) {
    _broker.logInfo('[BT-Classic] $msg');
  }

  void _logError(String msg) {
    _broker.logError('[BT-Classic] $msg');
  }

  BluetoothClassicTransport() {
    _dataController = StreamController<Uint8List>.broadcast(
      onListen: () {
        for (final data in _startupData) {
          _dataController.add(data);
        }
        _startupData.clear();
        _startupBytes = 0;
      },
    );
    // Listen for connection events from native layer
    _connectionSubscription = BluetoothClassicMacOS.instance.connectionEvents
        .listen((event) {
          final eventAddress = event.address.toUpperCase().replaceAll('-', ':');
          final connectedAddress = _connectedDevice?.id
              .toUpperCase()
              .replaceAll('-', ':');

          if (connectedAddress == eventAddress) {
            if (event.type == BluetoothClassicEventType.disconnected) {
              _logInfo(
                'Native disconnect matched active transport $eventAddress',
              );
              ++_connectionGeneration;
              _updateState(TransportState.disconnected);
              _connectedDevice = null;
              _dataSubscription?.cancel();
              _dataSubscription = null;
            }
          }
        });
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // For Bluetooth Classic, we return paired/bonded devices
    // No actual scanning is needed
    try {
      final devices = await BluetoothClassicMacOS.instance
          .findCompatibleDevices();
      for (final device in devices) {
        _scanController.add(
          DiscoveredDevice(
            id: device.address,
            name: device.name,
            type: BluetoothType.classic,
            rssi: 0,
          ),
        );
      }
    } catch (e) {
      // Ignore errors enumerating paired devices.
    }
  }

  @override
  Future<void> stopScan() async {
    // No-op for Bluetooth Classic - we don't do active scanning
  }

  @override
  Future<bool> connect(DiscoveredDevice device) async {
    if (_state == TransportState.connected ||
        _state == TransportState.connecting) {
      _logInfo('Connect ignored for ${device.id}; state=${_state.name}');
      return false;
    }

    _updateState(TransportState.connecting);

    try {
      _connectedDevice = device;
      final generation = ++_connectionGeneration;
      await _dataSubscription?.cancel();
      _dataSubscription = BluetoothClassicMacOS.instance
          .getDataStream(device.id)
          .listen((data) {
            if (generation == _connectionGeneration &&
                !_dataController.isClosed) {
              if (_dataController.hasListener) {
                _dataController.add(data);
              } else if (_startupBytes + data.length <= 65536) {
                _startupData.add(data);
                _startupBytes += data.length;
              } else {
                _logError(
                  'Startup receive buffer overflow; reconnect required',
                );
                unawaited(disconnect());
              }
            }
          }, onError: (Object error) => _logError('RX stream error: $error'));
      final success = await BluetoothClassicMacOS.instance.connect(device.id);

      if (success &&
          generation == _connectionGeneration &&
          _state == TransportState.connecting) {
        _connectedDevice = device;
        _updateState(TransportState.connected);

        return true;
      } else {
        await _dataSubscription?.cancel();
        _dataSubscription = null;
        _connectedDevice = null;
        _logError('Native Classic connect failed for ${device.id}');
        _updateState(TransportState.disconnected);
        return false;
      }
    } catch (e) {
      await _dataSubscription?.cancel();
      _dataSubscription = null;
      _logError('Classic connect threw for ${device.id}: $e');
      _updateState(TransportState.disconnected);
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    ++_connectionGeneration;
    _startupData.clear();
    _startupBytes = 0;
    if (_connectedDevice == null) return;

    _logInfo('Disconnecting ${_connectedDevice!.id}');

    _updateState(TransportState.disconnecting);

    try {
      await BluetoothClassicMacOS.instance.disconnect(_connectedDevice!.id);
    } catch (e) {
      _logError('Disconnect error for ${_connectedDevice!.id}: $e');
    }

    _dataSubscription?.cancel();
    _dataSubscription = null;
    _connectedDevice = null;
    _updateState(TransportState.disconnected);
  }

  @override
  Future<bool> send(Uint8List data) {
    final address = _connectedDevice?.id;
    final generation = _connectionGeneration;
    if (_state != TransportState.connected || address == null) {
      return Future<bool>.value(false);
    }
    // Never silently overwrite protocol commands when the link is congested.
    if (_queuedWrites >= 256) {
      _logError(
        'Control write queue full; command rejected (${data.length} bytes)',
      );
      return Future<bool>.value(false);
    }
    final bytes = Uint8List.fromList(data);
    final result = Completer<bool>();
    _queuedWrites++;
    _sendTail = _sendTail.then((_) async {
      try {
        if (generation != _connectionGeneration ||
            _state != TransportState.connected) {
          result.complete(false);
          return;
        }
        result.complete(
          await BluetoothClassicMacOS.instance.send(address, bytes),
        );
      } catch (e) {
        _logError('Control write failed for $address: $e');
        result.complete(false);
      } finally {
        _queuedWrites--;
      }
    });
    return result.future;
  }

  @override
  Future<int> requestMtu(int mtu) async {
    // Bluetooth Classic RFCOMM doesn't have MTU negotiation like BLE
    // Return a reasonable default for serial communication
    return 512;
  }

  void _updateState(TransportState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    _connectionSubscription?.cancel();
    _broker.dispose();
    await _stateController.close();
    await _dataController.close();
    await _scanController.close();
  }
}
