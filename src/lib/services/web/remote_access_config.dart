import '../data_broker.dart';

class RemoteAccessConfig {
  const RemoteAccessConfig({
    this.enabled = false,
    this.password = '',
    this.publicOrigin = '',
    this.allowTransmit = false,
    this.allowAprs = false,
    this.allowPosition = false,
    this.defaultReadOnly = false,
  });

  final bool enabled;
  final String password;
  final String publicOrigin;
  final bool allowTransmit;
  final bool allowAprs;
  final bool allowPosition;
  final bool defaultReadOnly;

  static RemoteAccessConfig get current => RemoteAccessConfig(
    defaultReadOnly:
        DataBroker.getValue<int>(0, 'webServerDefaultReadOnly', 0) == 1,
    enabled: DataBroker.getValue<int>(0, 'webServerRemoteEnabled', 0) == 1,
    password: DataBroker.getValue<String>(0, 'webServerPassword', '') ?? '',
    publicOrigin:
        DataBroker.getValue<String>(0, 'webServerPublicOrigin', '') ?? '',
    allowTransmit:
        DataBroker.getValue<int>(0, 'webServerAllowTransmit', 0) == 1,
    allowAprs: DataBroker.getValue<int>(0, 'webServerAllowAprs', 0) == 1,
    allowPosition:
        DataBroker.getValue<int>(0, 'webServerAllowPosition', 0) == 1,
  );

  static String? validateOrigin(String value) {
    if (value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return 'Use an HTTPS origin, e.g. https://radio.example.com';
    }
    return null;
  }

  String? get validationError {
    if (!enabled) return null;
    if (password.length < 12) return 'Use a password of at least 12 characters';
    return validateOrigin(publicOrigin);
  }

  String? get externalOrigin => publicOrigin.trim().isEmpty
      ? null
      : Uri.parse(publicOrigin.trim()).origin;
}
