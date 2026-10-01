import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed secure migration preserves legacy credentials for a safe retry',
    () async {
      SharedPreferences.setMockInitialValues({
        'databroker_WinlinkPassword': 'old-test-secret',
      });
      final values = <String, String>{};
      var fail = true;
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'read') return values[args['key']];
        if (call.method == 'write') {
          if (fail) throw PlatformException(code: 'locked');
          values[args['key'] as String] = args['value'] as String;
        }
        return null;
      });
      try {
        await DataBroker.initialize();
        await DataBroker.loadSecrets();
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('databroker_WinlinkPassword'),
          'old-test-secret',
        );
        fail = false;
        await DataBroker.loadSecrets();
        expect(values['htc_secret_WinlinkPassword'], 'old-test-secret');
        expect(prefs.getString('databroker_WinlinkPassword'), isNull);
        expect(
          DataBroker.getValue<String>(0, 'WinlinkPassword', ''),
          'old-test-secret',
        );
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        DataBroker.reset();
      }
    },
  );
}
