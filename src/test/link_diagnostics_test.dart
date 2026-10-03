import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/link_diagnostics_dialog.dart';
import 'package:htcommander/radio/link_diagnostics.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/web/remote_link_status.dart';

void main() {
  tearDown(DataBroker.reset);
  test(
    'control observations bounded, no ambiguous retry latency or stale completion',
    () {
      var now = DateTime.utc(2026, 10, 3);
      final d = RadioLinkDiagnostics(clock: () => now)..start();
      expect(d.snapshot(queuedReads: 0, queuedTncFragments: 0)['replyDelay'], {
        'samples': 0,
        'lastMs': null,
        'medianMs': null,
        'maxMs': null,
      });
      d.received(20);
      d.commandsReceived++;
      d.framingSkippedBytes += 3;
      for (var i = 0; i < 100; i++) {
        final ticket = d.beginWrite();
        d.endWrite(ticket, Duration(milliseconds: i), i != 99);
        d.readReply(Duration(milliseconds: i));
      }
      d.readReply(null);
      d.timeout(retry: true);
      d.timeout(retry: false);
      var s = d.snapshot(queuedReads: 2, queuedTncFragments: 3);
      expect((s['writeDelay'] as Map)['samples'], 32);
      expect((s['replyDelay'] as Map)['samples'], 32);
      expect(s['rxBytes'], 20);
      expect(s['writeFailures'], 1);
      expect(s['readReplies'], 101);
      expect(s['readRetries'], 1);
      expect(s['abandonedReads'], 1);
      final late = d.beginWrite();
      d.stop('private error');
      d.start();
      d.endWrite(late, const Duration(milliseconds: 20), false);
      s = d.snapshot(queuedReads: 0, queuedTncFragments: 0);
      expect(s['writeFailures'], 0);
      expect(s['pendingWrites'], 0);
      expect(s['lastRxAt'], isNull);
      now = now.subtract(const Duration(seconds: 1));
      d.readReply(const Duration(milliseconds: -1));
      expect(
        (d.snapshot(queuedReads: 0, queuedTncFragments: 0)['replyDelay']
            as Map)['samples'],
        0,
      );
    },
  );
  test(
    'playback budget drops at bound, drain races and late failures cannot corrupt new session',
    () {
      final d = RadioAudioDiagnostics()..start();
      final first = d.reserve(16000)!;
      expect(d.snapshot['bufferedMs'], 500);
      expect(d.reserve(16000), isNull);
      expect(d.snapshot['droppedFrames'], 16000);
      d.drained(320);
      d.failed(first, 16000);
      expect(d.bufferedFrames, 320);
      expect(d.feedErrors, 1);
      final fresh = d.reserve(640)!;
      d.failed(fresh, 640);
      expect(d.bufferedFrames, 320);
      d.drained(-1);
      d.drained(32000 * 9);
      expect(d.invalidDrainReports, 2);
      expect(d.bufferedFrames, 320);
      final late = d.reserve(640)!;
      d.stop();
      d.start();
      d.failed(late, 640);
      expect(d.feedErrors, 0);
      expect(d.bufferedFrames, 0);
      d.stop();
      expect(d.reserve(640), isNull);
    },
  );
  test(
    'phone/export allowlists discard secrets, corrupt values and unknown diagnostics',
    () {
      final control = RemoteLinkStatus.control({
        'connected': true,
        'rxBytes': -1,
        'writes': 'secret',
        'lastRxAt': 'password',
        'failureReason': 'private error',
        'address': 'secret-mac',
        'writeDelay': {'lastMs': 20, 'text': 'secret'},
      })!;
      final audio = RemoteLinkStatus.audio({
        'bufferedMs': 500,
        'password': 'secret',
        'state': 'running',
        'failureReason': 'private error',
      })!;
      expect(control['rxBytes'], isNull);
      expect(control['writes'], isNull);
      expect(control['lastRxAt'], isNull);
      expect(
        jsonEncode({'control': control, 'audio': audio}),
        isNot(contains('secret')),
      );
      expect(RemoteLinkStatus.snapshot(-1), {'control': null, 'audio': null});
    },
  );
  testWidgets(
    '390px host diagnostics reads live selected radio and copies sanitized JSON',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'];
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      void set(int id, String name, Object value) =>
          DataBroker.dispatch(deviceId: id, name: name, data: value);
      set(1, 'ConnectedRadios', [
        {'DeviceId': 2},
      ]);
      set(1, 'SelectedRadioDeviceId', 2);
      set(2, 'RadioLinkDiagnostics', {
        'connected': true,
        'rxBytes': 1234,
        'address': 'secret-mac',
      });
      set(2, 'RadioAudioDiagnostics', {
        'state': 'running',
        'bufferedMs': 500,
        'password': 'secret',
      });
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LinkDiagnosticsDialog())),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('RX bytes: 1234'), findsOneWidget);
      set(2, 'RadioLinkDiagnostics', {'connected': true, 'rxBytes': 5678});
      await tester.pump();
      expect(find.textContaining('RX bytes: 5678'), findsOneWidget);
      await tester.tap(find.text('复制脱敏诊断 JSON / Copy JSON'));
      await tester.pump();
      expect(copied, contains('5678'));
      expect(copied, isNot(contains('secret')));
      set(1, 'ConnectedRadios', []);
      await tester.pump();
      expect(find.textContaining('控制接收字节 / RX bytes: 未知'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
