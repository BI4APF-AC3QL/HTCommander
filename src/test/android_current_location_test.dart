import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/services/android_current_location.dart';

void main() {
  group('AndroidCurrentLocation.parsePosition', () {
    final now = DateTime.utc(2026, 10, 13, 12);

    test('accepts a recent coordinate pair', () {
      final fix = AndroidCurrentLocation.parsePosition({
        'latitude': 31.23,
        'longitude': 121.47,
        'timestamp': now.millisecondsSinceEpoch,
      }, now: now);

      expect(fix.latitude, 31.23);
      expect(fix.longitude, 121.47);
    });

    test('rejects invalid coordinates and missing timestamps', () {
      expect(
        () => AndroidCurrentLocation.parsePosition({
          'latitude': 91,
          'longitude': 121,
          'timestamp': now.millisecondsSinceEpoch,
        }, now: now),
        throwsA(isA<AndroidLocationException>()),
      );
      expect(
        () => AndroidCurrentLocation.parsePosition({
          'latitude': 31,
          'longitude': 121,
        }, now: now),
        throwsA(isA<AndroidLocationException>()),
      );
      expect(
        () => AndroidCurrentLocation.parsePosition({
          'latitude': 0,
          'longitude': 0,
          'timestamp': now.millisecondsSinceEpoch,
        }, now: now),
        throwsA(isA<AndroidLocationException>()),
      );
    });

    test('rejects stale or future fixes', () {
      for (final timestamp in [
        now.subtract(const Duration(minutes: 3)).millisecondsSinceEpoch,
        now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      ]) {
        expect(
          () => AndroidCurrentLocation.parsePosition({
            'latitude': 31,
            'longitude': 121,
            'timestamp': timestamp,
          }, now: now),
          throwsA(isA<AndroidLocationException>()),
        );
      }
    });
  });
}
