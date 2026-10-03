import 'remote_connection_models.dart';

ConnectionProbes createConnectionProbes() => _Unavailable();

class _Unavailable implements ConnectionProbes {
  @override
  Future<ConnectionCheck> dns(Uri uri) async =>
      const ConnectionCheck('dns', 'unavailable');
  @override
  Future<ConnectionCheck> certificate(Uri uri) async =>
      const ConnectionCheck('certificate', 'unavailable');
  @override
  Future<ConnectionCheck> http(Uri uri, {required bool backend}) async =>
      ConnectionCheck(backend ? 'backend' : 'public', 'unavailable');
  @override
  void cancel() {}
}
