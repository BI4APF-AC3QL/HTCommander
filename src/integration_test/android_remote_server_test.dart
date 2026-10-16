import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/material.dart' show TabBarView;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show ErrorWidget, Scrollable, ValueKey;
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/main.dart' as app;
import 'package:htcommander/radio/gaia_protocol.dart';
import 'package:htcommander/radio/pcm_player.dart';
import 'package:htcommander/services/agwpe/agwpe_server.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';
import 'package:htcommander/services/db/app_database.dart';
import 'package:htcommander/services/recording/rolling_voice_clip_path.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _exerciseAndroidPcmPlaybackLifecycle() async {
  final PcmPlayer player = PcmPlayer();
  try {
    // Silent samples exercise AudioTrack setup, queued writes, release, and
    // immediate restart without connecting a radio or producing RF output.
    for (var cycle = 0; cycle < 4; cycle++) {
      await player.setup(sampleRate: 32000, channelCount: 1);
      await player.feed(Int16List(32000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await player.release();
    }
  } finally {
    await player.release();
  }
}

Future<void> _verifyAndroidAgwpeLanBinding() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.IPv4,
  );
  final lanAddress = interfaces
      .expand((interface) => interface.addresses)
      .firstWhere(
        (address) =>
            address.type == InternetAddressType.IPv4 && !address.isLoopback,
        orElse: () => throw StateError(
          'The Android emulator must expose a non-loopback IPv4 address',
        ),
      );

  final localServer = AgwpeServer(0);
  try {
    expect(await localServer.start(), isTrue);
    expect(localServer.boundAddress, '127.0.0.1');
    final localPort = localServer.boundPort!;
    var lanConnectionRejected = false;
    try {
      final socket = await Socket.connect(
        lanAddress,
        localPort,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
    } on SocketException {
      lanConnectionRejected = true;
    }
    expect(
      lanConnectionRejected,
      isTrue,
      reason: 'loopback-only AGWPE must reject connections via LAN IP',
    );
  } finally {
    localServer.dispose();
  }

  final lanServer = AgwpeServer(0, allowLanClients: true);
  try {
    expect(await lanServer.start(), isTrue);
    expect(lanServer.boundAddress, '0.0.0.0');
    final socket = await Socket.connect(
      lanAddress,
      lanServer.boundPort!,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
  } finally {
    lanServer.dispose();
  }
}

Future<String?> _verifyAndroidRemoteServerLanBinding(
  int port, {
  required InternetAddressType addressType,
  required bool requiredAddress,
}) async {
  final addresses =
      (await NetworkInterface.list(includeLoopback: false, type: addressType))
          .expand((interface) => interface.addresses)
          .where(
            (address) =>
                address.type == addressType &&
                !address.isLoopback &&
                !address.isLinkLocal,
          )
          .toList();
  if (addresses.isEmpty) {
    if (!requiredAddress) return null;
    throw StateError(
      'The Android emulator must expose a non-loopback '
      '$addressType address',
    );
  }

  final http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    Object? lastError;
    for (final address in addresses) {
      try {
        final request = await http.getUrl(
          Uri(
            scheme: 'http',
            host: address.address,
            port: port,
            path: '/login',
          ),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        final body = await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == HttpStatus.ok && body.contains('远程访问密码')) {
          return address.address;
        }
        lastError = StateError(
          'HTTP ${response.statusCode} from ${address.address}',
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError(
      'Android remote server was not reachable through a LAN interface '
      '(${addresses.map((address) => address.address).join(', ')}): '
      '$lastError',
    );
  } finally {
    http.close(force: true);
  }
}

Future<Map<String, Object?>> _waitForAndroidRollingVoiceState({
  required bool running,
  int minimumKeptFiles = 0,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final raw = DataBroker.getValueDynamic(0, 'RollingVoiceStatus');
    if (raw is Map) {
      final status = Map<String, Object?>.from(raw);
      final keptFiles = status['keptFiles'] is int
          ? status['keptFiles'] as int
          : 0;
      if (status['running'] == running && keptFiles >= minimumKeptFiles) {
        return status;
      }
      const fatalErrors = {
        'android_service_failed',
        'storage_open_failed',
        'worker_stopped',
        'storage_write_failed',
      };
      if (fatalErrors.contains(status['error'])) {
        throw StateError(
          'Android rolling voice recorder failed: ${status['error']}',
        );
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(
    'Timed out waiting for Android rolling voice recorder: '
    'running=$running, keptFiles>=$minimumKeptFiles, '
    'lastStatus=${DataBroker.getValueDynamic(0, 'RollingVoiceStatus')}',
  );
}

Future<void> _exerciseAndroidRollingVoiceBackgroundRecording() async {
  const radioId = 192;
  const pcmLength = 3200;
  final savedClips = <File>[];
  DataBroker.dispatch(
    deviceId: 1,
    name: 'SelectedRadioDeviceId',
    data: radioId,
    store: true,
  );
  DataBroker.dispatch(
    deviceId: 0,
    name: 'RollingVoiceEnabled',
    data: true,
    store: true,
  );

  try {
    final ready = await _waitForAndroidRollingVoiceState(running: true);
    final folder = ready['folder'];
    expect(folder, isA<String>());

    Future<void> injectAndVerifyClip(int expectedKeptFiles) async {
      DataBroker.dispatch(
        deviceId: radioId,
        name: 'AudioDataAvailable',
        data: <String, Object?>{
          'data': Uint8List(pcmLength),
          'offset': 0,
          'length': pcmLength,
          'channelName': 'FM',
          'transmit': false,
          'muted': false,
        },
        store: false,
      );
      DataBroker.dispatch(
        deviceId: 0,
        name: 'RollingVoicePreserve',
        data: true,
        store: false,
      );

      final status = await _waitForAndroidRollingVoiceState(
        running: true,
        minimumKeptFiles: expectedKeptFiles,
      );
      final recent = status['recent'];
      expect(recent, isA<List>());
      final kept = (recent as List)
          .whereType<Map>()
          .where((clip) => clip['kept'] == true)
          .toList();
      expect(kept.length, greaterThanOrEqualTo(expectedKeptFiles));
      final name = kept.first['name'];
      expect(name, isA<String>());
      final file = File(
        rollingVoiceClipPath(folder as String, name as String, kept: true),
      );
      final bytes = await file.readAsBytes();
      expect(bytes.length, pcmLength + 44);
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
      savedClips.add(file);
    }

    await injectAndVerifyClip(1);
    // The shell runner sends HOME after this marker, then waits for the second
    // clip checkpoint while the app and recorder remain in the background.
    // ignore: avoid_print
    print('HTC_ANDROID_RECORDING_BG_ACCEPTANCE_READY');
    await Future<void>.delayed(const Duration(seconds: 6));
    await injectAndVerifyClip(2);
    // ignore: avoid_print
    print('HTC_ANDROID_RECORDING_BACKGROUND_CHECKPOINT');
    // The host acceptance script polls logcat before checking that Android's
    // foreground service is still active. Keep recording enabled long enough
    // for that external check to observe the post-write state.
    await Future<void>.delayed(const Duration(seconds: 10));

    DataBroker.dispatch(
      deviceId: 0,
      name: 'RollingVoiceEnabled',
      data: false,
      store: true,
    );
    await _waitForAndroidRollingVoiceState(running: false);
    // The runner checks that the recording-only foreground service is released.
    // ignore: avoid_print
    print('HTC_ANDROID_RECORDING_RELEASE_READY');
    // Keep the next keep-alive reason from restarting the service before the
    // host runner has observed this recording-only stop checkpoint.
    await Future<void>.delayed(const Duration(seconds: 15));
  } finally {
    DataBroker.dispatch(
      deviceId: 0,
      name: 'RollingVoiceEnabled',
      data: false,
      store: true,
    );
    try {
      await _waitForAndroidRollingVoiceState(running: false);
    } catch (_) {
      // Preserve the original acceptance failure while still attempting cleanup.
    }
    DataBroker.dispatch(
      deviceId: 1,
      name: 'SelectedRadioDeviceId',
      data: -1,
      store: true,
    );
    for (final clip in savedClips) {
      try {
        if (await clip.exists()) await clip.delete();
      } catch (_) {
        // The Android test app is uninstalled by the acceptance workflow.
      }
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android remote server starts, authenticates, serves the hosted UI, and stops',
    (tester) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      final originalFlutterErrorHandler = FlutterError.onError;
      Timer? syntheticSatelliteTimer;

      void publishSyntheticSatelliteState() {
        DataBroker.dispatch(
          deviceId: 0,
          name: 'SatelliteRemoteState',
          data: {
            'enabled': true,
            'observerKnown': true,
            'catalog': [
              {
                'id': 25544,
                'name': 'ISS test satellite',
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
                'elevationDeg': 35.0,
                'rangeRateKmS': 1.0,
              },
            ],
          },
          store: true,
        );
      }

      try {
        // Flutter's integration-test view can retain its default desktop-sized
        // metrics even on an Android emulator. Model a common phone viewport
        // explicitly so this assertion covers the compact Android layout.
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        app.main(<String>[]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        final handler = await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 120));
          while (DataBroker.getDataHandler<WebServerHandler>(
                    'WebServerHandler',
                  ) ==
                  null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return DataBroker.getDataHandler<WebServerHandler>(
            'WebServerHandler',
          );
        });
        expect(
          handler,
          isNotNull,
          reason: 'the Android app must finish startup',
        );
        expect(
          AppDatabase.instance,
          isNotNull,
          reason: 'Android SQLite initialization must succeed before startup',
        );
        await tester.runAsync(_exerciseAndroidPcmPlaybackLifecycle);
        await tester.runAsync(_verifyAndroidAgwpeLanBinding);
        // Android phones use the compact layout, where the radio controls and
        // feature pages are opened from the bottom navigation strip.
        // Wait for asynchronous app startup to replace its splash screen, then
        // exercise those entries so the server test also covers the phone UI.
        final mobileRadioTab = find.byKey(
          const ValueKey<String>('main_tab_Radio'),
        );
        for (
          var attempt = 0;
          attempt < 100 && mobileRadioTab.evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          mobileRadioTab,
          findsOneWidget,
          reason: 'the phone-sized viewport should enable compact navigation',
        );
        final mobileNavigation = find.byKey(
          const ValueKey<String>('main_tab_navigation'),
        );
        expect(mobileNavigation, findsOneWidget);
        final navigationRect = tester.getRect(mobileNavigation);
        expect(
          navigationRect.width,
          greaterThan(380),
          reason: 'phone navigation should span the screen width',
        );
        expect(
          navigationRect.height,
          lessThanOrEqualTo(72),
          reason: 'phone navigation should use a compact bottom strip',
        );
        expect(
          tester.getSize(find.byType(TabBarView).first).width,
          greaterThan(380),
          reason: 'radio and feature pages should retain the full phone width',
        );

        // Expose every tab available in the native desktop app so the phone
        // acceptance check covers the same feature pages. These values are
        // broadcast only in memory; no radio is connected and no transmit
        // control is activated.
        DataBroker.dispatch(
          deviceId: 0,
          name: 'AllowTransmit',
          data: 1,
          store: false,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'WinlinkPassword',
          data: 'AndroidIntegrationTestPassword',
          store: false,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'SatelliteSupport',
          data: 1,
          store: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        Future<void> verifySelectedTab(String tab) async {
          // Wait for the tab-change notification instead of assuming a single
          // long pump completes the animation on a slower Android emulator.
          for (var frame = 0; frame < 20; frame++) {
            await tester.pump(const Duration(milliseconds: 50));
            if (DataBroker.getValue<String>(0, 'SelectedTabName', '') == tab) {
              break;
            }
          }
          expect(
            DataBroker.getValue<String>(0, 'SelectedTabName', ''),
            tab,
            reason: '$tab must become the active page on Android',
          );
          expect(
            find.byType(ErrorWidget),
            findsNothing,
            reason: '$tab must build without an Android page error',
          );
          // Let the TabBarView finish its page transition before opening the
          // next bottom-sheet menu on slower Android emulators.
          await tester.pump(const Duration(milliseconds: 350));
        }

        // The most common pages are directly available in the bottom bar.
        for (final tab in const <String>[
          'Radio',
          'Comms',
          'Audio',
          'APRS',
          'Map',
        ]) {
          final entry = find.byKey(ValueKey<String>('main_tab_$tab'));
          expect(
            entry,
            findsOneWidget,
            reason: '$tab should be visible in phone navigation',
          );
          expect(
            entry.hitTestable(),
            findsOneWidget,
            reason: '$tab should be tappable on a phone-sized screen',
          );
          await tester.tap(entry);
          await verifySelectedTab(tab);
        }

        // Less frequently used pages are collected in the More sheet. Open it
        // for each item because selecting a page closes the sheet.
        for (final tab in const <String>[
          'Satellite',
          'Mail',
          'Terminal',
          'Contacts',
          'BBS',
          'Torrent',
          'Packets',
          'Debug',
        ]) {
          await tester.tap(find.byKey(const ValueKey<String>('main_tab_more')));
          await tester.pump(const Duration(milliseconds: 400));
          final entry = find.byKey(ValueKey<String>('compact_more_$tab'));
          final moreMenu = find.byKey(
            const ValueKey<String>('compact_more_list'),
          );
          final moreMenuScrollable = find.descendant(
            of: moreMenu,
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            entry,
            160,
            scrollable: moreMenuScrollable,
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            entry,
            findsOneWidget,
            reason: '$tab should be available from the phone More menu',
          );
          expect(
            entry.hitTestable(),
            findsOneWidget,
            reason: '$tab should be visible and tappable in the More menu',
          );
          await tester.tap(entry);
          await verifySelectedTab(tab);
        }

        // Restore the receive-first profile before starting the server test.
        DataBroker.dispatch(
          deviceId: 0,
          name: 'AllowTransmit',
          data: 0,
          store: false,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'WinlinkPassword',
          data: '',
          store: false,
          allowEmpty: true,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'SatelliteSupport',
          data: 0,
          store: false,
        );
        // Make the APK-hosted browser pass exercise a connected, receive-only
        // radio through the real Android server. This remains a synthetic
        // broker device and never opens Bluetooth or performs RF transmission.
        const syntheticRadioId = 190;
        DataBroker.dispatch(
          deviceId: 0,
          name: 'webServerAllowTransmit',
          data: 0,
          store: true,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'webServerAllowAprs',
          data: 0,
          store: true,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'webServerAllowPosition',
          data: 0,
          store: true,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'webServerDefaultReadOnly',
          data: 0,
          store: true,
        );
        DataBroker.dispatch(
          deviceId: 0,
          name: 'webServerRequireControlApproval',
          data: 0,
          store: true,
        );
        DataBroker.dispatch(
          deviceId: 1,
          name: 'ConnectedRadios',
          data: const [
            {
              'DeviceId': syntheticRadioId,
              'FriendlyName': 'Android test radio',
            },
          ],
          store: true,
        );
        DataBroker.dispatch(
          deviceId: 1,
          name: 'SelectedRadioDeviceId',
          data: syntheticRadioId,
          store: true,
        );
        DataBroker.dispatch(
          deviceId: syntheticRadioId,
          name: 'State',
          data: 'Connected',
          store: true,
        );
        DataBroker.dispatch(
          deviceId: syntheticRadioId,
          name: 'AudioState',
          data: true,
          store: true,
        );
        DataBroker.dispatch(
          deviceId: syntheticRadioId,
          name: 'Settings',
          data: const {'channelA': 0, 'squelchLevel': 5, 'scan': false},
          store: true,
        );
        DataBroker.dispatch(
          deviceId: syntheticRadioId,
          name: 'HtStatus',
          data: const {'isPowerOn': true, 'isInTx': false, 'isScan': false},
          store: true,
        );
        DataBroker.dispatch(
          deviceId: syntheticRadioId,
          name: 'Channels',
          data: const [
            {
              'channelId': 0,
              'name': 'Android test channel',
              'rxFreq': 145600000,
              'txDisable': true,
            },
          ],
          store: true,
        );
        DataBroker.dispatch(
          deviceId: syntheticRadioId,
          name: 'Volume',
          data: 4,
          store: true,
        );
        publishSyntheticSatelliteState();
        syntheticSatelliteTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) => publishSyntheticSatelliteState(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final server = handler!;
        final browserSquelch = Completer<int>();
        final browserVolume = Completer<int>();
        final browserSatelliteStart = Completer<Map>();
        final browserSatelliteStop = Completer<void>();
        final browserCommandObserver = DataBrokerClient();
        browserCommandObserver.subscribe(
          deviceId: syntheticRadioId,
          name: 'SetSquelchLevel',
          callback: (_, _, value) {
            if (!browserSquelch.isCompleted && value is int) {
              browserSquelch.complete(value);
            }
          },
        );
        browserCommandObserver.subscribe(
          deviceId: syntheticRadioId,
          name: 'SetVolumeLevel',
          callback: (_, _, value) {
            if (!browserVolume.isCompleted && value is int) {
              browserVolume.complete(value);
            }
          },
        );
        browserCommandObserver.subscribe(
          deviceId: 0,
          name: 'SatelliteTrackTarget',
          callback: (_, _, value) {
            if (value is Map && !browserSatelliteStart.isCompleted) {
              browserSatelliteStart.complete(Map.from(value));
            } else if (value == null &&
                browserSatelliteStart.isCompleted &&
                !browserSatelliteStop.isCompleted) {
              browserSatelliteStop.complete();
            }
          },
        );
        HttpClient? http;
        try {
          // Use a fixed emulator-only port so the host acceptance script can
          // forward it with adb while the app is backgrounded. The app's
          // regular settings path starts the native foreground service before
          // opening the real Dart HTTP socket.
          DataBroker.dispatch(deviceId: 0, name: 'webServerEnabled', data: 0);
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (server.boundPort != null &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          });
          expect(
            server.boundPort,
            isNull,
            reason: 'the test must start from a stopped server',
          );
          const testPort = 18735;
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerPort',
            data: testPort,
          );
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerRemoteEnabled',
            data: 1,
          );
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerPassword',
            data: 'AndroidIntegrationTestPassword',
          );
          DataBroker.dispatch(deviceId: 0, name: 'webServerEnabled', data: 1);

          final port = await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 30));
            while (server.boundPort == null &&
                DateTime.now().isBefore(deadline)) {
              final status =
                  DataBroker.getValue<String>(0, 'webServerStatus', '') ?? '';
              if (status.startsWith('Failed') ||
                  status.startsWith('Android foreground service failed')) {
                throw StateError(
                  'Android remote server did not start: $status',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            return server.boundPort;
          });
          expect(port, isNotNull, reason: 'the real HTTP listener must bind');

          final lanAddress = await tester.runAsync(
            () => _verifyAndroidRemoteServerLanBinding(
              port!,
              addressType: InternetAddressType.IPv4,
              requiredAddress: true,
            ),
          );
          expect(
            lanAddress,
            isNotEmpty,
            reason:
                'the Android server must serve its login page on a LAN address',
          );
          final ipv6Address = await tester.runAsync(
            () => _verifyAndroidRemoteServerLanBinding(
              port!,
              addressType: InternetAddressType.IPv6,
              requiredAddress: false,
            ),
          );

          // The shell acceptance script waits for this marker, presses HOME,
          // and probes the forwarded server from the host while this test
          // remains alive. This exercises the foreground-service path rather
          // than merely checking the listener while MainActivity is visible.
          // ignore: avoid_print
          print(
            'HTC_ANDROID_BG_ACCEPTANCE_READY:$port:$lanAddress:'
            '${ipv6Address ?? "no-non-link-local-ipv6"}',
          );
          await tester.runAsync(() async {
            // The host-side script runs Chromium against the authenticated
            // mobile page, then loads Flutter's compiled bundle. That bundle
            // has up to 180 seconds of its own startup/render timeout, so keep
            // the app service alive for the full browser checkpoint.
            await Future<void>.delayed(const Duration(minutes: 4));
            expect(
              await browserSquelch.future.timeout(const Duration(seconds: 1)),
              6,
              reason: 'the Android mobile page must send the selected squelch',
            );
            expect(
              await browserVolume.future.timeout(const Duration(seconds: 1)),
              8,
              reason: 'the Android mobile page must send the selected volume',
            );
            final satelliteTarget = await browserSatelliteStart.future.timeout(
              const Duration(seconds: 1),
            );
            expect(satelliteTarget['noradId'], 25544);
            expect(satelliteTarget['usageIndex'], 0);
            expect(satelliteTarget['receiveOnly'], isTrue);
            expect(satelliteTarget.containsKey('uplinkHz'), isFalse);
            await browserSatelliteStop.future.timeout(
              const Duration(seconds: 1),
            );
          });

          http = HttpClient();
          await tester.runAsync(() async {
            final base = Uri(scheme: 'http', host: '::1', port: port!);

            final unauthenticatedRequest = await http!.getUrl(
              base.resolve('/index.html'),
            );
            unauthenticatedRequest.followRedirects = false;
            final unauthenticatedResponse = await unauthenticatedRequest
                .close();
            expect(unauthenticatedResponse.statusCode, HttpStatus.seeOther);
            expect(
              unauthenticatedResponse.headers.value(HttpHeaders.locationHeader),
              '/login',
            );
            await unauthenticatedResponse.drain<void>();

            final formRequest = await http!.getUrl(base.resolve('/login'));
            final formResponse = await formRequest.close();
            expect(formResponse.statusCode, HttpStatus.ok);
            final csrf = formResponse.cookies.singleWhere(
              (cookie) => cookie.name == 'htc_login',
            );
            expect(
              await utf8.decoder.bind(formResponse).join(),
              contains('远程访问密码'),
            );

            final loginRequest = await http!.postUrl(base.resolve('/login'));
            loginRequest.followRedirects = false;
            loginRequest.cookies.add(csrf);
            loginRequest.headers.set('origin', base.origin);
            loginRequest.headers.contentType = ContentType(
              'application',
              'x-www-form-urlencoded',
            );
            loginRequest.write(
              Uri(
                queryParameters: {
                  'csrf': csrf.value,
                  'password': 'AndroidIntegrationTestPassword',
                },
              ).query,
            );
            final loginResponse = await loginRequest.close();
            expect(loginResponse.statusCode, HttpStatus.seeOther);
            expect(
              loginResponse.headers.value(HttpHeaders.locationHeader),
              '/remote.html',
            );
            final session = loginResponse.cookies.singleWhere(
              (cookie) => cookie.name == 'htc_bridge',
            );
            await loginResponse.drain<void>();

            final remoteRequest = await http!.getUrl(
              base.resolve('/remote.html'),
            );
            remoteRequest.cookies.add(session);
            final remoteResponse = await remoteRequest.close();
            expect(remoteResponse.statusCode, HttpStatus.ok);
            expect(
              await utf8.decoder.bind(remoteResponse).join(),
              contains('操作权'),
            );

            // Exercise the same radio bridge used by Windows-hosted clients,
            // but with a synthetic broker radio so this Android emulator test
            // never touches Bluetooth hardware or transmits RF.
            final rawCommandSeen = Completer<Uint8List>();
            final brokerObserver = DataBrokerClient();
            brokerObserver.subscribe(
              deviceId: syntheticRadioId,
              name: 'SendRawCommand',
              callback: (_, _, value) {
                if (!rawCommandSeen.isCompleted && value is Uint8List) {
                  rawCommandSeen.complete(value);
                }
              },
            );
            WebSocket? radioSocket;
            StreamController<Object?>? socketEvents;
            StreamSubscription<Object?>? socketSubscription;
            try {
              radioSocket = await WebSocket.connect(
                Uri(
                  scheme: 'ws',
                  host: '::1',
                  port: port,
                  path: '/websocket.aspx',
                ).toString(),
                headers: {
                  'Origin': base.origin,
                  'Cookie': 'htc_bridge=${session.value}',
                },
              );
              socketEvents = StreamController<Object?>.broadcast();
              socketSubscription = radioSocket.listen(socketEvents.add);

              final radioList = socketEvents.stream
                  .where((message) => message is String)
                  .cast<String>()
                  .firstWhere(
                    (message) =>
                        message.startsWith('radiolist:') &&
                        message.contains('Android test radio'),
                  )
                  .timeout(const Duration(seconds: 5));
              // The initial snapshot can arrive during the WebSocket upgrade;
              // rebroadcast after subscribing so the test observes live data.
              DataBroker.dispatch(
                deviceId: 1,
                name: 'ConnectedRadios',
                data: const [
                  {
                    'DeviceId': syntheticRadioId,
                    'FriendlyName': 'Android test radio',
                  },
                ],
              );
              await radioList;

              final safeQuery = Uint8List.fromList([
                0,
                RadioCommandGroup.basic.value,
                0,
                RadioBasicCommand.getDevId.value,
              ]);
              radioSocket.add(safeQuery);
              final forwardedQuery = await rawCommandSeen.future.timeout(
                const Duration(seconds: 5),
              );
              expect(forwardedQuery, orderedEquals(safeQuery));

              final responseBytes = Uint8List.fromList([
                0x31,
                0x32,
                0x33,
                0x34,
              ]);
              final relayedResponse = socketEvents.stream
                  .where(
                    (event) =>
                        event is List<int> &&
                        event.length == responseBytes.length &&
                        List<int>.generate(
                              responseBytes.length,
                              (index) => event[index],
                            ).toString() ==
                            responseBytes.toString(),
                  )
                  .first
                  .timeout(const Duration(seconds: 5));
              DataBroker.dispatch(
                deviceId: syntheticRadioId,
                name: 'RawCommandRx',
                data: responseBytes,
                store: false,
              );
              final receivedResponse = await relayedResponse;
              expect(receivedResponse, orderedEquals(responseBytes));
            } finally {
              await radioSocket?.close();
              await socketSubscription?.cancel();
              await socketEvents?.close();
              brokerObserver.dispose();
              DataBroker.dispatch(
                deviceId: 1,
                name: 'ConnectedRadios',
                data: const <Object?>[],
              );
              DataBroker.dispatch(
                deviceId: 1,
                name: 'SelectedRadioDeviceId',
                data: -1,
              );
              DataBroker.dispatch(
                deviceId: syntheticRadioId,
                name: 'State',
                data: 'Disconnected',
              );
            }

            final appRequest = await http!.getUrl(base.resolve('/index.html'));
            appRequest.cookies.add(session);
            final appResponse = await appRequest.close();
            expect(appResponse.statusCode, HttpStatus.ok);
            expect(
              await utf8.decoder.bind(appResponse).join(),
              contains('flutter_bootstrap.js'),
            );

            final scriptRequest = await http!.getUrl(
              base.resolve('/main.dart.js'),
            );
            scriptRequest.cookies.add(session);
            final scriptResponse = await scriptRequest.close();
            expect(scriptResponse.statusCode, HttpStatus.ok);
            expect(
              scriptResponse.headers.contentType?.mimeType,
              'application/javascript',
            );
            final scriptBytes = await scriptResponse.fold<int>(
              0,
              (total, chunk) => total + chunk.length,
            );
            expect(scriptBytes, greaterThan(100000));
            expect(
              scriptResponse.contentLength,
              scriptBytes,
              reason:
                  'the Android server must declare the exact hosted JavaScript byte length',
            );
            expect(
              scriptResponse.headers.value(HttpHeaders.contentEncodingHeader),
              isNull,
              reason:
                  'the Android server must not transform bytes after setting Content-Length',
            );

            final wasmRequest = await http!.getUrl(
              base.resolve('/canvaskit/canvaskit.wasm'),
            );
            wasmRequest.cookies.add(session);
            final wasmResponse = await wasmRequest.close();
            expect(wasmResponse.statusCode, HttpStatus.ok);
            expect(
              wasmResponse.headers.contentType?.mimeType,
              'application/wasm',
            );
            await wasmResponse.drain<void>();

            // Isolate the radio-connection lifecycle from the web server and
            // network integrations. This synthetic radio exercises the real
            // Android foreground-service bridge without Bluetooth or RF.
            const radioOnlyId = 191;
            DataBroker.dispatch(
              deviceId: 1,
              name: 'ConnectedRadios',
              data: const <Object?>[
                {'DeviceId': radioOnlyId, 'FriendlyName': 'Simulated radio'},
              ],
              store: true,
            );
            DataBroker.dispatch(
              deviceId: 1,
              name: 'SelectedRadioDeviceId',
              data: radioOnlyId,
              store: true,
            );
            DataBroker.dispatch(
              deviceId: radioOnlyId,
              name: 'State',
              data: 'Connected',
              store: true,
            );
            DataBroker.dispatch(
              deviceId: 0,
              name: 'webServerEnabled',
              data: 0,
              store: false,
            );
            final radioOnlyDeadline = DateTime.now().add(
              const Duration(seconds: 10),
            );
            while (server.boundPort != null &&
                DateTime.now().isBefore(radioOnlyDeadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            expect(
              server.boundPort,
              isNull,
              reason: 'the radio-only checkpoint must not have an HTTP server',
            );

            // The shell backgrounds the app and checks the Android service
            // while this synthetic radio is the only active keep-alive reason.
            // ignore: avoid_print
            print('HTC_ANDROID_RADIO_ONLY_BG_ACCEPTANCE_READY');
            await Future<void>.delayed(const Duration(seconds: 15));
            DataBroker.dispatch(
              deviceId: 1,
              name: 'ConnectedRadios',
              data: const <Object?>[],
              store: true,
              allowEmpty: true,
            );
            DataBroker.dispatch(
              deviceId: 1,
              name: 'SelectedRadioDeviceId',
              data: -1,
              store: true,
            );
            DataBroker.dispatch(
              deviceId: radioOnlyId,
              name: 'State',
              data: 'Disconnected',
              store: true,
            );
            // The runner verifies that the service stops before the next
            // keep-alive reason (MQTT) is enabled.
            // ignore: avoid_print
            print('HTC_ANDROID_RADIO_ONLY_RELEASE_READY');
            await Future<void>.delayed(const Duration(seconds: 15));

            // Exercise the Android local receive recorder with synthetic silent
            // PCM. The host backgrounds the app between these checkpoints and
            // verifies that the recording foreground service remains active.
            await _exerciseAndroidRollingVoiceBackgroundRecording();

            // Exercise the Android-only foreground-service reason used by
            // Home Assistant after the web server is stopped. The broker is
            // loopback-only so the emulator does not contact an external host.
            DataBroker.dispatch(
              deviceId: 0,
              name: 'homeAssistantMqttUrl',
              data: 'mqtt://127.0.0.1:65534',
              store: true,
            );
            DataBroker.dispatch(
              deviceId: 0,
              name: 'homeAssistantEnabled',
              data: 1,
              store: true,
            );
            DataBroker.dispatch(
              deviceId: 0,
              name: 'webServerEnabled',
              data: 0,
              store: false,
            );
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (server.boundPort != null &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            final serverStopped = server.boundPort == null;
            expect(
              serverStopped,
              isTrue,
              reason:
                  'Home Assistant must keep the service without HTTP server',
            );

            // The shell runner sends HOME, verifies the foreground service,
            // then returns to this test. A connected MQTT broker is not needed
            // to verify that the opted-in background session stays alive.
            // ignore: avoid_print
            print('HTC_ANDROID_MQTT_BG_ACCEPTANCE_READY');
            await Future<void>.delayed(const Duration(seconds: 15));
            DataBroker.dispatch(
              deviceId: 0,
              name: 'homeAssistantEnabled',
              data: 0,
              store: true,
            );
            DataBroker.dispatch(
              deviceId: 0,
              name: 'homeAssistantMqttUrl',
              data: '',
              store: true,
              allowEmpty: true,
            );
          });
        } finally {
          browserCommandObserver.dispose();
          http?.close(force: true);
          DataBroker.dispatch(deviceId: 0, name: 'webServerEnabled', data: 0);
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerRemoteEnabled',
            data: 0,
          );
          DataBroker.dispatch(
            deviceId: 0,
            name: 'webServerPassword',
            data: '',
            allowEmpty: true,
          );
          DataBroker.dispatch(deviceId: 0, name: 'webServerPort', data: 8080);
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (server.boundPort != null &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
          });
        }
      } finally {
        syntheticSatelliteTimer?.cancel();
        ErrorWidget.builder = originalErrorWidgetBuilder;
        FlutterError.onError = originalFlutterErrorHandler;
      }
    },
    // This test keeps the Android server alive during a four-minute host-side
    // browser pass, then verifies radio-only, rolling-recording, and MQTT
    // foreground-service checkpoints. Keep the test timeout below the
    // acceptance script's 16-minute process limit but long enough for them all.
    timeout: const Timeout(Duration(minutes: 13)),
  );
}
