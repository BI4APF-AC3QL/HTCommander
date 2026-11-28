import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/widgets/debug_tab.dart';

void main() {
  tearDown(DataBroker.reset);

  testWidgets('Android debug menu shows live radio link diagnostics on phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const radioId = 42;
    DataBroker.dispatch(
      deviceId: 1,
      name: 'ConnectedRadios',
      data: [
        {'DeviceId': radioId},
      ],
    );
    DataBroker.dispatch(
      deviceId: 1,
      name: 'SelectedRadioDeviceId',
      data: radioId,
    );
    DataBroker.dispatch(
      deviceId: radioId,
      name: 'RadioLinkDiagnostics',
      data: {
        'connected': true,
        'rxBytes': 1200,
        'commandsReceived': 24,
        'writeDelay': {'samples': 5, 'lastMs': 12, 'medianMs': 10, 'maxMs': 20},
        'replyDelay': {'samples': 4, 'lastMs': 18, 'medianMs': 15, 'maxMs': 28},
        'failureReason': null,
      },
    );
    DataBroker.dispatch(
      deviceId: radioId,
      name: 'RadioAudioDiagnostics',
      data: {
        'state': 'running',
        'bufferedMs': 120,
        'peakBufferedMs': 240,
        'droppedFrames': 320,
        'droppedBlocks': 2,
        'feedErrors': 0,
        'androidDroppedChunks': 3,
        'androidDroppedBytes': 420,
        'lastAndroidQueueDropAt': '2026-10-16T08:00:00Z',
        'receivedBytes': 64000,
        'failureReason': 'androidQueueOverrun',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(platform: TargetPlatform.android),
        home: const Scaffold(body: DebugTab()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('链路诊断 / Link'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.textContaining('Write last/median/max: 12 / 10 / 20 ms'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Android Bluetooth RX queue drops: 3/420'),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byType(AlertDialog)).width,
      lessThanOrEqualTo(360),
    );
    expect(tester.takeException(), isNull);
  });
}
