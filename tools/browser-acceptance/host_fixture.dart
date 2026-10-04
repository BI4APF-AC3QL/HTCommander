import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/handlers/aprs_handler.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

class RealHttp extends HttpOverrides {}

void set(int id, String key, Object? value) =>
    DataBroker.dispatch(deviceId: id, name: key, data: value);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = RealHttp();
  test('isolated production phone fixture, zero physical transports', () async {
    const secure = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (_) async => null);
    final events = <String>[];
    final squelchRequests = <int>[];
    final satelliteRequests = <Object?>[];
    final observer = DataBrokerClient();
    for (final key in [
      'TransmitDataFrame',
      'SetPtt',
      'SendRawCommand',
      'SetVoice',
    ])
      observer.subscribe(
        deviceId: DataBroker.allDevices,
        name: key,
        callback: (_, name, __) => events.add(name),
      );
    set(0, 'webAppPath', Directory('web').absolute.path);
    for (final item in <String, Object>{
      'webServerEnabled': 1,
      'webServerPort': 0,
      'webServerRemoteEnabled': 1,
      'webServerPassword': 'synthetic-test-password',
      'webServerDefaultReadOnly': 1,
      'webServerRequireControlApproval': 1,
      'webServerAllowTransmit': 0,
      'webServerAllowAprs': 0,
      'webServerAllowPosition': 1,
      'AllowTransmit': 1,
      'CallSign': 'DEMO-1',
    }.entries)
      set(0, item.key, item.value);
    set(1, 'ConnectedRadios', [
      {
        'DeviceId': 2,
        'FriendlyName': 'Disconnected from all physical hardware - mock only',
      },
    ]);
    set(2, 'State', 'Connected');
    set(2, 'HtStatus', {'isPowerOn': true, 'isInRx': false, 'isInTx': false});
    set(2, 'Channels', [
      {'channelId': 1, 'name': 'APRS', 'rxFreq': 144390000, 'txDisable': false},
    ]);
    set(2, 'Settings', {'channelA': 1, 'doubleChannel': 0, 'squelchLevel': 5});
    void orbitFresh() {
      set(0, 'SatelliteRemoteState', {
        'enabled': true,
        'observerKnown': true,
        'catalog': [
          {
            'id': 25544,
            'name': 'ISS',
            'usages': [
              {'index': 0, 'name': 'Voice', 'downlinkHz': 145800000},
            ],
          },
        ],
        'positions': [
          {
            'id': 25544,
            'utc': DateTime.now().toUtc().toIso8601String(),
            'azimuthDeg': 90.0,
            'elevationDeg': 30.0,
            'rangeRateKmS': 1.0,
          },
        ],
      });
    }

    orbitFresh();
    observer.subscribe(
      deviceId: 2,
      name: 'SetSquelchLevel',
      callback: (_, _, v) {
        if (v is int) {
          squelchRequests.add(v);
          set(2, 'Settings', {
            'channelA': 1,
            'doubleChannel': 0,
            'squelchLevel': v,
          });
        }
      },
    );
    observer.subscribe(
      deviceId: 0,
      name: 'SatelliteTrackTarget',
      callback: (_, _, v) => satelliteRequests.add(v),
    );
    set(2, 'AudioState', true);
    final aprs = AprsHandler()..init();
    final host = WebServerHandler()..init();
    for (var i = 0; i < 100 && host.boundPort == null; i++)
      await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(host.boundPort, isNotNull);
    final status = File(Platform.environment['HTC_BROWSER_STATUS']!),
        command = File(Platform.environment['HTC_BROWSER_COMMAND']!);
    final done = Completer<void>();
    var busy = false;
    Future<void> report() async {
      final temp = File('${status.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'url': 'http://127.0.0.1:${host.boundPort}',
          'events': events,
          'squelchRequests': squelchRequests,
          'satelliteRequests': satelliteRequests,
          'clients': DataBroker.getValueDynamic(0, 'RemoteClients', []),
          'position': DataBroker.getValueDynamic(1, 'RemotePositionStatus'),
        }),
      );
      await temp.rename(status.path);
    }

    await report();
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (busy) return;
      busy = true;
      try {
        if (await command.exists()) {
          final data = jsonDecode(await command.readAsString()) as Map;
          await command.delete();
          if (data['op'] == 'stop' && !done.isCompleted) done.complete();
          if (data['op'] == 'role')
            set(0, 'RemoteClientRole', {
              'id': data['id'],
              'readOnly': data['readOnly'],
            });
          if (data['op'] == 'grant') set(0, 'RemoteControlGrant', data['id']);
          if (data['op'] == 'emergency') set(0, 'webServerEmergencyStopped', 1);
          if (data['op'] == 'resume') set(0, 'webServerEmergencyStopped', 0);
          if (data['op'] == 'orbitFresh') orbitFresh();
          if (data['op'] == 'positionOff') set(0, 'webServerAllowPosition', 0);
        }
        await report();
      } finally {
        busy = false;
      }
    });
    try {
      await done.future.timeout(const Duration(minutes: 12));
    } finally {
      timer.cancel();
      await host.close();
      aprs.dispose();
      observer.dispose();
      DataBroker.reset();
    }
  }, timeout: const Timeout(Duration(minutes: 13)));
}
