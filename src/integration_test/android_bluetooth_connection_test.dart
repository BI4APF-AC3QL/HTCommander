import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show ErrorWidget;
import 'package:htcommander/handlers/web_server_handler.dart';
import 'package:htcommander/main.dart' as app;
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/db/app_database.dart';
import 'package:integration_test/integration_test.dart';

import 'support/android_bluetooth_connection_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android Classic Bluetooth connects and releases a mocked N7500',
    (tester) async {
      final originalErrorWidgetBuilder = ErrorWidget.builder;
      final originalFlutterErrorHandler = FlutterError.onError;
      try {
        app.main(<String>[]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();

        final startup = await tester.runAsync(() async {
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
          startup,
          isNotNull,
          reason: 'the Android app must finish startup',
        );
        expect(AppDatabase.instance, isNotNull);

        await tester.runAsync(exerciseAndroidBluetoothClassicConnection);
      } finally {
        ErrorWidget.builder = originalErrorWidgetBuilder;
        FlutterError.onError = originalFlutterErrorHandler;
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
