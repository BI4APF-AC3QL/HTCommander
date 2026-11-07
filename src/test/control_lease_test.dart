import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:htcommander/radio/pcm_player.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:htcommander/services/web/control_lease.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

void set(int id, String name, Object value) =>
    DataBroker.dispatch(deviceId: id, name: name, data: value);

class _Phone {
  _Phone(this.socket) {
    socket.listen((value) {
      if (value is List<int>) {
        audioPackets.add(List<int>.of(value));
      }
      if (value is String && value.startsWith('remote:')) {
        final message = jsonDecode(value.substring(7)) as Map;
        final wait = _reply;
        _reply = null;
        wait?.complete(message);
      }
    }, onDone: () => _reply?.completeError(StateError('closed')));
  }
  final WebSocket socket;
  final audioPackets = <List<int>>[];
  Completer<Map>? _reply;
  Future<Map> command(Map data) {
    _reply = Completer<Map>();
    final future = _reply!.future;
    socket.add('remote:${jsonEncode(data)}');
    return future.timeout(const Duration(seconds: 3));
  }
}

// TestWidgets binding overrides HTTP with a 400 stub. These integration tests
// deliberately use real loopback sockets, with no external network or radio.
class _RealHttp extends HttpOverrides {}

class _Host {
  final handler = WebServerHandler();
  final http = HttpClient();
  final phones = <_Phone>[];
  String base = '';
  Future<void> start({bool approval = false, bool readOnly = false}) async {
    for (final e in <String, Object>{
      'webServerEnabled': 1,
      'webServerPort': 0,
      'webServerRemoteEnabled': 1,
      'webServerPassword': 'only-a-simulated-password',
      'webServerRequireControlApproval': approval ? 1 : 0,
      'webServerDefaultReadOnly': readOnly ? 1 : 0,
      'webServerAllowTransmit': 1,
      'AllowTransmit': 1,
    }.entries) {
      set(0, e.key, e.value);
    }
    set(1, 'ConnectedRadios', [
      {'DeviceId': 2, 'FriendlyName': 'No hardware mock'},
    ]);
    set(2, 'State', 'Connected');
    set(2, 'HtStatus', {'isPowerOn': true, 'isInTx': false});
    set(2, 'Settings', {'channelA': 0, 'doubleChannel': 0});
    set(2, 'Channels', [
      {'channelId': 0, 'name': 'Test', 'txDisable': false},
    ]);
    set(2, 'AudioState', true);
    handler.init();
    for (var i = 0; i < 100 && handler.boundPort == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(handler.boundPort, isNotNull);
    base = 'http://127.0.0.1:${handler.boundPort}';
  }

  Future<_Phone> phone() async {
    final get = await http.getUrl(Uri.parse('$base/login'));
    final form = await get.close();
    final csrf = form.cookies.singleWhere((c) => c.name == 'htc_login');
    await form.drain<void>();
    final post = await http.postUrl(Uri.parse('$base/login'));
    post.followRedirects = false;
    post.cookies.add(csrf);
    post.headers.set('origin', base);
    post.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    post.write(
      Uri(
        queryParameters: {
          'csrf': csrf.value,
          'password': 'only-a-simulated-password',
        },
      ).query,
    );
    final signed = await post.close();
    final session = signed.cookies.singleWhere((c) => c.name == 'htc_bridge');
    await signed.drain<void>();
    final socket = await WebSocket.connect(
      '${base.replaceFirst('http:', 'ws:')}/websocket.aspx',
      headers: {'Origin': base, 'Cookie': 'htc_bridge=${session.value}'},
    );
    final phone = _Phone(socket);
    phones.add(phone);
    return phone;
  }

  Future<void> close() async {
    for (final p in phones) {
      await p.socket.close();
    }
    await handler.close();
    http.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttp = HttpOverrides.current;
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    HttpOverrides.global = _RealHttp();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (_) async => null);
  });
  tearDown(() {
    HttpOverrides.global = previousHttp;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
  });
  tearDown(DataBroker.reset);
  test(
    'receive profile isolates clients, bytes, audio stop and reconnect without RF',
    () async {
      final host = _Host(), observer = DataBrokerClient();
      final writes = <String>[];
      for (final event in [
        'TransmitDataFrame',
        'SetVolumeLevel',
        'ChannelChangeVfoA',
        'Scan',
        'Ptt',
        'SendRawCommand',
      ]) {
        observer.subscribe(
          deviceId: 2,
          name: event,
          callback: (_, name, _) => writes.add(name),
        );
      }
      observer.subscribe(
        deviceId: 1,
        name: 'SendAprsMessage',
        callback: (_, name, _) => writes.add(name),
      );
      try {
        await host.start(readOnly: true);
        final a = await host.phone(), b = await host.phone();
        final initial = await a.command({'op': 'media', 'lowBandwidth': true});
        expect(initial['error'], isNull);
        expect(initial['state']['readOnly'], true);
        expect(initial['state']['controlOwner'], isNull);
        expect(initial['state']['media']['lowBandwidth'], true);
        expect(
          (await b.command({'op': 'state'}))['state']['media']['lowBandwidth'],
          false,
        );
        a.socket.add('audioon');
        b.socket.add('audioon');
        await a.command({'op': 'state'});
        await b.command({'op': 'state'});
        final pcm = Int16List(16000);
        PcmPlayer.playbackTap!(pcm, 32000, 1);
        for (
          var i = 0;
          i < 100 && (a.audioPackets.isEmpty || b.audioPackets.isEmpty);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(a.audioPackets.single.length, 8004);
        expect(b.audioPackets.single.length, 32004);
        expect(a.audioPackets.single.take(4), [241, 1, 64, 31]);
        expect(
          (await a.command({
            'op': 'state',
          }))['state']['media']['audioPayloadBytes'],
          8004,
        );
        expect(
          (await b.command({
            'op': 'state',
          }))['state']['media']['audioPayloadBytes'],
          32004,
        );
        a.socket.add('audiooff');
        await a.command({'op': 'state'});
        PcmPlayer.playbackTap!(pcm, 32000, 1);
        for (var i = 0; i < 100 && b.audioPackets.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(b.audioPackets, hasLength(2));
        expect(a.audioPackets, hasLength(1));
        await a.command({'op': 'media', 'lowBandwidth': false});
        a.socket.add('audioon');
        await a.command({'op': 'state'});
        PcmPlayer.playbackTap!(pcm, 32000, 1);
        for (var i = 0; i < 100 && a.audioPackets.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(a.audioPackets.last.length, 32004);
        PcmPlayer.playbackTap!(Int16List(3), 32000, 2);
        expect(
          (await a.command({'op': 'state'}))['state']['media']['skippedBlocks'],
          1,
        );
        final reconnected = await host.phone();
        final fresh = (await reconnected.command({
          'op': 'state',
        }))['state']['media'];
        expect(fresh['lowBandwidth'], false);
        expect(fresh['audioPayloadBytes'], 0);
        expect(writes, isEmpty);
      } finally {
        await host.close();
        observer.dispose();
      }
    },
  );
  test('requests stay bounded and repeated requests cannot extend expiry', () {
    var now = DateTime(2026);
    final lease = ControlLease(clock: () => now);
    for (var id = 1; id <= 8; id++) {
      expect(lease.request(id), true);
    }
    expect(lease.request(9), false);
    expect(lease.request(-1), false);
    now = now.add(const Duration(minutes: 1));
    expect(lease.request(1), true);
    now = now.add(const Duration(minutes: 1));
    expect(lease.prune(), true);
    expect(lease.requests, isEmpty);
    lease.grant(2);
    lease.remove(1);
    expect(lease.owner, 2);
    lease.recall();
    expect(lease.owner, isNull);
  });
  test('no ownership bypass, handoff requires eligible pending requester', () {
    final controller = RemoteRadioController(
      target: () => 2,
      clientCanControl: (id) => id == 2,
    );
    expect(
      controller.command(1, {'op': 'volume', 'value': 3}),
      contains('exclusive'),
    );
    controller.grantControl(1);
    expect(
      controller.command(2, {'op': 'grantControl', 'clientId': 2}),
      isNotNull,
    );
    expect(
      controller.command(1, {'op': 'handoffControl', 'clientId': 2}),
      isNotNull,
    );
    controller.command(2, {'op': 'requestControl'});
    set(0, 'webServerRequireControlApproval', 1);
    expect(
      controller.command(1, {'op': 'handoffControl', 'clientId': 2}),
      contains('host'),
    );
    set(0, 'webServerRequireControlApproval', 0);
    expect(
      controller.command(1, {'op': 'handoffControl', 'clientId': 2}),
      isNull,
    );
    expect(controller.controlOwner, 2);
    controller.disconnected(1);
    expect(controller.controlOwner, 2);
    controller.disconnected(2);
    expect(controller.controlOwner, isNull);
    controller.command(2, {'op': 'state'});
    expect(controller.controlOwner, isNull);
  });
  test(
    'production HTTP/WebSocket lease enforces exclusivity and host recall',
    () async {
      final host = _Host();
      final observer = DataBrokerClient();
      final volumes = <int>[], cancelled = <int>[], voiceStops = <bool>[];
      observer.subscribe(
        deviceId: 2,
        name: 'SetVolumeLevel',
        callback: (_, _, v) => volumes.add(v as int),
      );
      observer.subscribe(
        deviceId: 0,
        name: 'CancelRemoteAprs',
        callback: (_, _, v) {
          if (v is int) cancelled.add(v);
        },
      );
      observer.subscribe(
        deviceId: 2,
        name: 'CancelVoiceTransmit',
        callback: (_, _, _) => voiceStops.add(true),
      );
      try {
        await host.start();
        final a = await host.phone(), b = await host.phone();
        var r = await a.command({'op': 'requestControl'});
        final aid = r['clientId'] as int;
        expect(r['state']['controlOwner'], aid);
        r = await b.command({'op': 'requestControl'});
        final bid = r['clientId'] as int;
        expect(r['state']['controlRequested'], true);
        expect(
          (await b.command({'op': 'volume', 'value': 5}))['error'],
          contains('exclusive'),
        );
        expect(volumes, isEmpty);
        expect(
          (await a.command({'op': 'volume', 'value': 3}))['error'],
          isNull,
        );
        expect(volumes, [3]);
        expect((await a.command({'op': 'pttStart'}))['state']['txOwner'], aid);
        r = await a.command({'op': 'handoffControl', 'clientId': bid});
        expect(r['error'], isNull);
        expect(r['state']['controlOwner'], bid);
        expect(r['state']['txOwner'], isNull);
        expect(cancelled, contains(aid));
        expect(voiceStops, hasLength(1));
        a.socket.add(Uint8List.fromList([0, 2, 0, 23, 8]));
        await a.command({'op': 'state'});
        expect(volumes, [3]);
        expect(
          (await a.command({
            'op': 'aprsMessage',
            'destination': 'W1AW',
            'text': 'No',
          }))['error'],
          contains('exclusive'),
        );
        expect(
          (await b.command({'op': 'volume', 'value': 4}))['error'],
          isNull,
        );
        expect(volumes, [3, 4]);
        final audit = r['state']['auditEvents'] as List;
        expect(
          audit.any(
            (e) =>
                e['clientId'] == aid &&
                e['action'] == 'volume' &&
                e['result'] == 'accepted',
          ),
          true,
        );
        expect(
          audit.any(
            (e) =>
                e['clientId'] == aid &&
                e['action'] == 'pttRelease' &&
                e['result'] == 'released',
          ),
          true,
        );
        set(0, 'RemoteControlRecall', true);
        r = await b.command({'op': 'state'});
        expect(r['state']['controlOwner'], isNull);
        expect(r['state']['controlRequests'], isEmpty);
        expect(
          (await b.command({'op': 'volume', 'value': 5}))['error'],
          isNotNull,
        );
        await b.command({'op': 'requestControl'});
        set(0, 'RemoteClientRole', {'id': bid, 'readOnly': true});
        r = await b.command({'op': 'state'});
        expect(r['state']['controlOwner'], isNull);
        r = await b.command({'op': 'requestControl'});
        expect(r['state']['controlRequested'], true);
        expect(r['state']['controlOwner'], isNull);
        set(0, 'RemoteControlGrant', bid);
        r = await b.command({'op': 'state'});
        expect(r['state']['controlOwner'], bid);
        expect(r['state']['readOnly'], false);
        await b.command({'op': 'pttStart'});
        set(0, 'webServerEmergencyStopped', 1);
        r = await b.command({'op': 'state'});
        expect(r['state']['controlOwner'], isNull);
        expect(r['state']['txOwner'], isNull);
        expect(
          (await b.command({'op': 'requestControl'}))['error'],
          contains('stopped'),
        );
        set(0, 'webServerEmergencyStopped', 0);
        r = await b.command({'op': 'state'});
        expect(r['state']['controlOwner'], isNull);
        await a.command({'op': 'requestControl'});
        set(0, 'RemoteClientRevoke', aid);
        r = await b.command({'op': 'state'});
        expect(r['state']['controlOwner'], isNull);
        final summaries =
            DataBroker.getValueDynamic(0, 'RemoteClients', []) as List;
        expect(summaries, hasLength(1));
        expect(summaries.single['id'], bid);
      } finally {
        await host.close();
        observer.dispose();
      }
    },
  );
  test('host approval and default read-only prevent automatic grant', () async {
    final host = _Host();
    try {
      await host.start(approval: true, readOnly: true);
      final phone = await host.phone();
      var r = await phone.command({'op': 'requestControl'});
      final id = r['clientId'] as int;
      expect(r['state']['controlOwner'], isNull);
      expect(r['state']['controlRequested'], true);
      expect(
        (await phone.command({'op': 'volume', 'value': 3}))['error'],
        contains('read-only'),
      );
      r = await phone.command({'op': 'state'});
      expect(
        (r['state']['auditEvents'] as List).any(
          (e) =>
              e['clientId'] == id &&
              e['action'] == 'writeDenied' &&
              e['result'] == 'denied',
        ),
        true,
      );
      set(0, 'RemoteControlGrant', id);
      r = await phone.command({'op': 'state'});
      expect(r['state']['controlOwner'], id);
      expect(r['state']['readOnly'], false);
      await phone.command({'op': 'releaseControl'});
      r = await phone.command({'op': 'requestControl'});
      expect(r['state']['controlOwner'], isNull);
    } finally {
      await host.close();
    }
  });
  test(
    'runtime clients never load from or write to preference settings',
    () async {
      SharedPreferences.setMockInitialValues({
        'databroker_RemoteClients': 'stale-client',
      });
      await DataBroker.initialize();
      expect(DataBroker.getValueDynamic(0, 'RemoteClients', []), isEmpty);
      set(0, 'RemoteClients', [
        {'id': 1},
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        DataBroker.getValueDynamic(0, 'RemoteClients', []) as List,
        hasLength(1),
      );
      expect(prefs.getString('databroker_RemoteClients'), 'stale-client');
    },
  );
  test(
    'authenticated dashboard carries observed radio telemetry and clears on disconnect',
    () async {
      final host = _Host();
      try {
        await host.start();
        final phone = await host.phone();
        final before =
            (await phone.command({'op': 'state'}))['state']['dashboard'] as Map;
        expect(before['radio']['reportAt'], isNull);
        expect(before['clientCount'], 1);
        set(2, 'Channels', [
          {'channelId': 0, 'name': 'A', 'rxFreq': 145000000},
          {'channelId': 1, 'name': 'Scanning', 'rxFreq': 144390000},
        ]);
        set(2, 'HtStatus', {
          'currChId': 1,
          'isInRx': true,
          'isInTx': false,
          'isScan': true,
          'rssi': 7,
        });
        final seen =
            (await phone.command({'op': 'state'}))['state']['dashboard'] as Map;
        expect(seen['radio']['reportAt'], isNotNull);
        expect(seen['radio']['reportAgeSeconds'], lessThan(3));
        expect(seen['radio']['channel'], 'Scanning');
        expect(seen['radio']['rxFrequency'], 144390000);
        expect(seen['radio']['receiving'], true);
        set(2, 'State', 'Disconnected');
        final down =
            (await phone.command({'op': 'state'}))['state']['dashboard'] as Map;
        expect(down['radio']['receiving'], isNull);
        expect(down['radio']['reportAt'], isNull);
        set(2, 'State', 'Connected');
        final reconnected =
            (await phone.command({'op': 'state'}))['state']['dashboard'] as Map;
        expect(reconnected['radio']['reportAt'], isNull);
      } finally {
        await host.close();
      }
    },
  );
}
