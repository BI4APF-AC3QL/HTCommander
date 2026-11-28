/*
Copyright 2026 Ylian Saint-Hilaire
Licensed under the Apache License, Version 2.0 (the "License");
http://www.apache.org/licenses/LICENSE-2.0
*/

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/radio_connection_dialog.dart';
import 'package:htcommander/l10n/app_localizations.dart';
import 'package:htcommander/radio/radio_transport.dart';

void main() {
  test('discovered BLE device retains its connection transport type', () {
    final devices = RadioConnectionDialog.fromDiscoveredDevices([
      DiscoveredDevice(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'UV-PRO',
        type: BluetoothType.ble,
        serviceUuids: const ['00001100-d102-11e1-9b23-00025b00a5a5'],
      ),
    ]);

    expect(devices, hasLength(1));
    expect(devices.single.bluetoothType, BluetoothType.ble);
  });

  testWidgets('cannot-connect dialog shows troubleshooting guidance', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => RadioConnectionDialog.showCannotConnect(context),
            child: const Text('Connect'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Cannot Connect to Radio'), findsOneWidget);
    expect(find.textContaining('Move the radio closer'), findsOneWidget);
    expect(
      find.image(const AssetImage('assets/images/CantConnect.png')),
      findsOneWidget,
    );
  });
}
