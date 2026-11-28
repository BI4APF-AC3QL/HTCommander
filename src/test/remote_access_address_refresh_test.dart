import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/remote_access_dialog.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(DataBroker.reset);

  testWidgets('refreshes copied server addresses when network changes', (
    tester,
  ) async {
    final networkChanges =
        StreamController<List<ConnectivityResult>>.broadcast();
    var addressRevision = 0;
    Future<List<String>> loadAddresses() async {
      addressRevision++;
      return ['192.0.2.$addressRevision'];
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RemoteAccessDialog(
                  addressLoader: loadAddresses,
                  networkChanges: networkChanges.stream,
                ),
              ),
              child: const Text('Open remote settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open remote settings'));
    await tester.pumpAndSettle();
    expect(find.text('http://192.0.2.1:8080'), findsOneWidget);

    networkChanges.add(const [ConnectivityResult.mobile]);
    await tester.pumpAndSettle();
    expect(find.text('http://192.0.2.2:8080'), findsOneWidget);
    expect(find.text('http://192.0.2.1:8080'), findsNothing);

    final refreshButton = find.text('Refresh local addresses');
    await tester.ensureVisible(refreshButton);
    await tester.pumpAndSettle();
    await tester.tap(refreshButton);
    await tester.pumpAndSettle();
    expect(find.text('http://192.0.2.3:8080'), findsOneWidget);

    await tester.ensureVisible(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(networkChanges.hasListener, isFalse);
    await networkChanges.close();
  });
}
