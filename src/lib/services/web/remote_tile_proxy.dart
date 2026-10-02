import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../utils/map_source.dart';

class RemoteTile {
  const RemoteTile(this.bytes, this.contentType);
  final Uint8List bytes;
  final ContentType contentType;
}

/// Authenticated callers select a host-configured source, never an arbitrary
/// upstream URL. Custom provider tokens stay on the host. Memory, concurrency,
/// body size and the entire fetch duration are bounded independently of UI.
class RemoteTileProxy {
  RemoteTileProxy({
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 5),
  }) : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  final Duration timeout;
  static const maxEntries = 64, maxRequests = 8, maxBytes = 256 * 1024;
  final _cache = <String, (DateTime, RemoteTile)>{};
  final _pending = <String, Future<RemoteTile?>>{};
  final _clients = <HttpClient>{};
  bool _closed = false;
  int get cacheSize => _cache.length;
  int get pendingCount => _pending.length;

  Future<RemoteTile?> tile(MapSource source, int z, int x, int y) async {
    if (_closed ||
        z < 0 ||
        z > 18 ||
        x < 0 ||
        y < 0 ||
        x >= (1 << z) ||
        y >= (1 << z)) {
      return null;
    }
    final key = '${source.cacheNamespace}/$z/$x/$y';
    final cached = _cache.remove(key);
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 10)) {
      _cache[key] = cached;
      return cached.$2;
    }
    if (_pending.containsKey(key)) return _pending[key];
    if (_pending.length >= maxRequests) return null;
    final future = _fetch(source, z, x, y);
    _pending[key] = future;
    try {
      final result = await future;
      if (result != null && !_closed) {
        _cache[key] = (DateTime.now(), result);
        while (_cache.length > maxEntries) {
          _cache.remove(_cache.keys.first);
        }
      }
      return result;
    } finally {
      _pending.remove(key);
    }
  }

  Future<RemoteTile?> _fetch(MapSource source, int z, int x, int y) async {
    final client = _clientFactory();
    _clients.add(client);
    final timer = Timer(timeout, () => client.close(force: true));
    try {
      final request = await client
          .getUrl(Uri.parse(source.tileUrl(z, x, y)))
          .timeout(timeout);
      request.followRedirects = false;
      request.headers.set(
        'User-Agent',
        'HTCommander/1.0 (+https://github.com/BI4APF-AC3QL/HTCommander)',
      );
      final response = await request.close().timeout(timeout);
      final type = response.headers.contentType;
      if (response.statusCode != HttpStatus.ok ||
          type == null ||
          !['image/png', 'image/jpeg', 'image/webp'].contains(type.mimeType) ||
          response.contentLength > maxBytes) {
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (_closed || bytes.length + chunk.length > maxBytes) return null;
        bytes.add(chunk);
      }
      final data = bytes.takeBytes();
      // Refuse empty/HTML error bodies mislabeled as an image.
      final png =
          data.length >= 8 &&
          data[0] == 137 &&
          data[1] == 80 &&
          data[2] == 78 &&
          data[3] == 71;
      final jpeg =
          data.length >= 3 &&
          data[0] == 255 &&
          data[1] == 216 &&
          data[2] == 255;
      final webp =
          data.length >= 12 &&
          data[0] == 82 &&
          data[1] == 73 &&
          data[2] == 70 &&
          data[3] == 70 &&
          data[8] == 87 &&
          data[9] == 69 &&
          data[10] == 66 &&
          data[11] == 80;
      if (!(type.mimeType == 'image/png' && png ||
          type.mimeType == 'image/jpeg' && jpeg ||
          type.mimeType == 'image/webp' && webp)) {
        return null;
      }
      return RemoteTile(data, type);
    } catch (_) {
      // Never expose an upstream URL, key, or network exception to the phone.
      return null;
    } finally {
      timer.cancel();
      client.close(force: true);
      _clients.remove(client);
    }
  }

  void close() {
    _closed = true;
    _cache.clear();
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }
}
