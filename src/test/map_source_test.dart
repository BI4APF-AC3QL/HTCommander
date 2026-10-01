import 'package:flutter_test/flutter_test.dart';
import 'package:htcommander/utils/map_source.dart';
import 'package:htcommander/services/data_broker.dart';

void main() {
  tearDown(DataBroker.reset);
  test(
    'sources resolve XYZ order and isolate caches including custom API keys',
    () {
      final osm = MapSource.builtIn[0];
      final esri = MapSource.builtIn[1];
      expect(
        osm.tileUrl(4, 10, 6),
        'https://tile.openstreetmap.org/4/10/6.png',
      );
      expect(esri.tileUrl(4, 10, 6), endsWith('/4/6/10'));
      expect(osm.cacheNamespace, isNot(esri.cacheNamespace));
      const a = MapSource(
        'custom',
        'Custom',
        'https://tiles.example/{z}/{x}/{y}?key=private',
        'Tiles',
        '',
      );
      const b = MapSource(
        'custom',
        'Custom',
        'https://other.example/{z}/{x}/{y}?key=private',
        'Tiles',
        '',
      );
      expect(a.cacheNamespace, isNot(contains('private')));
      expect(a.cacheNamespace, isNot(b.cacheNamespace));
    },
  );
  test(
    'reject invalid sources and recover an invalid saved custom template',
    () {
      for (final bad in [
        'file:///{z}/{x}/{y}',
        'https://example/{z}/{x}',
        'https://user:pass@example/{z}/{x}/{y}',
      ]) {
        expect(MapSource.validateTemplate(bad), isNotNull);
      }
      expect(
        MapSource.validateTemplate('https://tiles.example/{z}/{x}/{y}.png'),
        isNull,
      );
      DataBroker.dispatch(deviceId: 0, name: 'MapSource', data: 'custom');
      DataBroker.dispatch(deviceId: 0, name: 'MapCustomUrl', data: 'broken');
      expect(MapSource.current.id, 'osm');
    },
  );
}
