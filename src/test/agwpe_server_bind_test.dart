import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/dialogs/app_settings.dart';
import 'package:htcommander/services/agwpe/agwpe_server.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorage = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  setUp(() {
    DataBroker.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
    DataBroker.reset();
  });

  test('AGWPE LAN access defaults off and persists as a user setting', () {
    final settings = AppSettings.loadFromDataBroker();
    expect(settings.agwpeServerLanAccess, isFalse);

    settings.agwpeServerLanAccess = true;
    settings.saveToDataBroker();

    expect(AppSettings.loadFromDataBroker().agwpeServerLanAccess, isTrue);
  });

  test(
    'AGWPE stays on loopback unless LAN access is explicitly enabled',
    () async {
      final localServer = AgwpeServer(0);
      expect(await localServer.start(), isTrue);
      expect(localServer.boundAddress, '127.0.0.1');
      expect(localServer.boundPort, greaterThan(0));
      localServer.dispose();

      final lanServer = AgwpeServer(0, allowLanClients: true);
      expect(await lanServer.start(), isTrue);
      expect(lanServer.boundAddress, '0.0.0.0');
      expect(lanServer.boundPort, greaterThan(0));
      lanServer.dispose();
    },
  );
}
