import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

void main() {
  test(
    'cached dispatch preserves order, wildcard matching and invalidation',
    () {
      DataBroker.reset();
      final first = DataBrokerClient();
      final second = DataBrokerClient();
      final values = <String>[];
      first.subscribe(
        deviceId: DataBroker.allDevices,
        name: 'Audio',
        callback: (_, _, _) => values.add('wild'),
      );
      second.subscribe(
        deviceId: 2,
        name: 'Audio',
        callback: (_, _, _) => values.add('exact'),
      );
      DataBroker.dispatch(deviceId: 2, name: 'Audio', data: 1, store: false);
      DataBroker.dispatch(deviceId: 2, name: 'Audio', data: 2, store: false);
      expect(values, ['wild', 'exact', 'wild', 'exact']);
      second.dispose();
      values.clear();
      DataBroker.dispatch(deviceId: 2, name: 'Audio', data: 3, store: false);
      expect(values, ['wild']);
      final third = DataBrokerClient();
      third.subscribe(
        deviceId: 2,
        name: DataBroker.allNames,
        callback: (_, _, _) => values.add('new'),
      );
      values.clear();
      DataBroker.dispatch(deviceId: 2, name: 'Audio', data: 4, store: false);
      expect(values, ['wild', 'new']);
      first.dispose();
      third.dispose();
      DataBroker.reset();
    },
  );
  test(
    'subscriptions created by callbacks apply to the next dispatch only',
    () {
      DataBroker.reset();
      final c = DataBrokerClient();
      final d = DataBrokerClient();
      final seen = <String>[];
      var registered = false;
      c.subscribe(
        deviceId: 1,
        name: 'Frame',
        callback: (_, _, _) {
          seen.add('first');
          if (!registered) {
            registered = true;
            d.subscribe(
              deviceId: 1,
              name: 'Frame',
              callback: (_, _, _) => seen.add('second'),
            );
          }
        },
      );
      DataBroker.dispatch(deviceId: 1, name: 'Frame', data: null, store: false);
      expect(seen, ['first']);
      seen.clear();
      DataBroker.dispatch(deviceId: 1, name: 'Frame', data: null, store: false);
      expect(seen, ['first', 'second']);
      c.dispose();
      d.dispose();
      DataBroker.reset();
    },
  );
}
