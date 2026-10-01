import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../services/data_broker.dart';

/// All built-in layers use Web Mercator with WGS84 input. GCJ-02 tiles must
/// not be substituted without also transforming every overlay coordinate.
class MapSource {
  const MapSource(
    this.id,
    this.name,
    this.urlTemplate,
    this.attribution,
    this.attributionUrl,
  );

  final String id;
  final String name;
  final String urlTemplate;
  final String attribution;
  final String attributionUrl;

  static const builtIn = <MapSource>[
    MapSource(
      'osm',
      'OpenStreetMap',
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      '© OpenStreetMap contributors',
      'https://www.openstreetmap.org/copyright',
    ),
    MapSource(
      'esri-street',
      'Esri World Street Map',
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
      'Tiles © Esri and its data providers',
      'https://www.esri.com/',
    ),
    MapSource(
      'esri-satellite',
      'Esri World Imagery',
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      'Imagery © Esri and its data providers',
      'https://www.esri.com/',
    ),
    MapSource(
      'carto',
      'CARTO Voyager',
      'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
      '© OpenStreetMap contributors © CARTO',
      'https://carto.com/attributions',
    ),
  ];

  /// Separate cache namespaces prevent old OSM tiles appearing on a new layer.
  /// Use a digest so custom URLs/API keys never become filesystem paths.
  String get cacheNamespace => id == 'osm'
      ? 'osm'
      : sha256.convert(utf8.encode(urlTemplate)).toString().substring(0, 24);

  String tileUrl(int z, int x, int y) => urlTemplate
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y')
      .replaceAll('{s}', 'a');

  static String? validateTemplate(String template) {
    final value = template.trim();
    if (!['{z}', '{x}', '{y}'].every(value.contains)) {
      return 'Use an XYZ URL containing {z}, {x} and {y}.';
    }
    final uri = Uri.tryParse(value.replaceAll(RegExp(r'\{[zxys]\}'), '0'));
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return 'Enter a valid HTTP(S) tile URL without embedded login credentials.';
    }
    return null;
  }

  static MapSource get current {
    final id = DataBroker.getValue<String>(0, 'MapSource', 'osm') ?? 'osm';
    if (id == 'custom') {
      final url = DataBroker.getValue<String>(0, 'MapCustomUrl', '') ?? '';
      if (validateTemplate(url) == null) {
        return MapSource(
          'custom',
          'Custom XYZ',
          url.trim(),
          DataBroker.getValue<String>(
                0,
                'MapCustomAttribution',
                'Custom map',
              ) ??
              'Custom map',
          '',
        );
      }
    }
    return builtIn.firstWhere((s) => s.id == id, orElse: () => builtIn.first);
  }
}
