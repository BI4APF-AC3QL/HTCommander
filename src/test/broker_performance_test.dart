// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/data_broker.dart';
import 'package:htcommander/services/data_broker_client.dart';

void main() {
  test('report dispatch cost with 500 subscriptions and 50000 audio events', () {
    DataBroker.reset();
    final client = DataBrokerClient();
    var delivered = 0;
    final names = <String>[];
    for (var i = 0; i < 500; i++) {
      final name = i == 250 ? 'AudioDataAvailable' : 'Setting$i';
      names.add(name);
      client.subscribe(
        deviceId: 2,
        name: name,
        callback: (_, _, _) => delivered++,
      );
    }
    // Warm the subscription cache before measuring.
    DataBroker.dispatch(
      deviceId: 2,
      name: 'AudioDataAvailable',
      data: 0,
      store: false,
    );
    const events = 50000;
    final cached = Stopwatch()..start();
    for (var i = 0; i < events; i++) {
      DataBroker.dispatch(
        deviceId: 2,
        name: 'AudioDataAvailable',
        data: i,
        store: false,
      );
    }
    cached.stop();
    var scanned = 0;
    final oldScan = Stopwatch()..start();
    // Isolate the previous algorithm's subscription lookup cost; no UI or RF
    // traffic is simulated. This is not a whole-application performance claim.
    for (var i = 0; i < events; i++) {
      final matched = <String>[];
      for (final n in names) {
        if (n == 'AudioDataAvailable' || n == '*') matched.add(n);
      }
      scanned += matched.length;
    }
    oldScan.stop();
    expect(delivered, events + 1);
    expect(scanned, events);
    print(
      'BROKER_BENCH cached_dispatch_us=${cached.elapsedMicroseconds} old_lookup_only_us=${oldScan.elapsedMicroseconds} events=$events subscriptions=500',
    );
    client.dispose();
    DataBroker.reset();
  });
}
