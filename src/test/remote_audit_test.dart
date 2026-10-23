import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_audit.dart';
import 'package:htcommander/services/web/remote_radio_controller.dart';

void main() {
  tearDown(DataBroker.reset);
  test('audit is bounded, UTC, immutable and coalesces repeated denials', () {
    var now = DateTime.utc(2026, 10, 2);
    final audit = RemoteAudit(clock: () => now);
    for (var i = 0; i < 205; i++) {
      audit.record(
        clientId: 1,
        radioId: 2,
        action: 'volume',
        result: 'accepted',
      );
    }
    expect(audit.events.length, 200);
    expect(audit.events.first['id'], 6);
    expect(audit.events.last['time'], '2026-10-02T00:00:00.000Z');
    expect(() => audit.events.add({}), throwsUnsupportedError);
    expect(
      () => audit.events.first['password'] = 'secret',
      throwsUnsupportedError,
    );
    expect(
      audit.record(
        clientId: 2,
        radioId: 2,
        action: 'pttStart',
        result: 'denied',
      ),
      true,
    );
    expect(
      audit.record(
        clientId: 2,
        radioId: 2,
        action: 'pttStart',
        result: 'denied',
      ),
      false,
    );
    now = now.add(const Duration(seconds: 1));
    expect(
      audit.record(
        clientId: 2,
        radioId: 2,
        action: 'pttStart',
        result: 'denied',
      ),
      true,
    );
    expect(
      () => audit.record(
        clientId: 1,
        radioId: 2,
        action: 'secret password',
        result: 'denied',
      ),
      throwsArgumentError,
    );
  });
  test('controller attributes commands without echoing sensitive payloads', () {
    final controller = RemoteRadioController(
      target: () => 2,
      clock: () => DateTime.utc(2026),
    );
    controller.command(7, {'op': 'state'});
    expect(controller.auditEvents, isEmpty);
    controller.command(7, {
      'op': 'aprsMessage',
      'destination': 'W1AW',
      'text': 'private message',
    });
    expect(controller.auditEvents.single['clientId'], 7);
    expect(controller.auditEvents.single['result'], 'denied');
    controller.command(7, {
      'op': 'password private-secret',
      'password': 'private-secret',
    });
    expect(controller.auditEvents.last['action'], 'invalidCommand');
    controller.grantControl(7);
    DataBroker.dispatch(deviceId: 2, name: 'State', data: 'Connected');
    controller.command(7, {'op': 'volume', 'value': 3});
    expect(controller.auditEvents.last['result'], 'accepted');
    controller.recallControl();
    final text = RemoteAudit.export(controller.auditEvents);
    expect(text, isNot(contains('private')));
    expect(text, isNot(contains('W1AW')));
    expect(text, isNot(contains('password')));
    expect((jsonDecode(text) as Map)['events'].last['affectedClient'], 7);
    expect(text, contains('not RF delivery'));
  });
  test('export excludes unrecognized fields and has a fixed entry limit', () {
    final text = RemoteAudit.export(
      List.generate(
        205,
        (i) => {
          'id': i,
          'action': 'volume',
          'result': 'accepted',
          'clientId': 1,
          'password': 'private-password',
          'latitude': 31.2,
          'address': 'private-address',
          'text': 'private-message',
        },
      ),
    );
    final data = jsonDecode(text) as Map;
    expect(data['events'], hasLength(200));
    expect(text, isNot(contains('private')));
    expect(text, isNot(contains('latitude')));
    final malicious = RemoteAudit.export([
      {
        'id': 1,
        'clientId': 'private-user',
        'time': 'private-time',
        'action': 'volume',
        'result': 'accepted',
      },
      {'action': 'private-password', 'result': 'accepted'},
    ]);
    expect(malicious, isNot(contains('private')));
    expect((jsonDecode(malicious) as Map)['events'], hasLength(1));
  });
}
