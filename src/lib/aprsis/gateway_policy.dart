import '../radio/ax25_address.dart';
import '../services/data_broker.dart';

/// Host-owned forwarding policy. Internet -> RF remains opt-in and also
/// requires the application's general transmit permission.
class GatewayPolicy {
  const GatewayPolicy({
    this.toInternet = true,
    this.rfPath = '',
    this.rfPerMinute = 6,
  });
  final bool toInternet;
  final String rfPath;
  final int rfPerMinute;
  static const paths = ['', 'WIDE1-1', 'WIDE2-1', 'WIDE1-1,WIDE2-1'];
  static GatewayPolicy get current {
    final path = DataBroker.getValue<String>(0, 'AprsIsRfPath', '') ?? '';
    final limit = DataBroker.getValue<int>(0, 'AprsIsRfPerMinute', 6) ?? 6;
    return GatewayPolicy(
      toInternet: DataBroker.getValue<int>(0, 'AprsIsGateToInternet', 1) == 1,
      rfPath: paths.contains(path) ? path : '',
      rfPerMinute: limit.clamp(1, 30),
    );
  }

  List<AX25Address> get addresses => AX25Address.parsePath(rfPath)!;
  void save() {
    if (!paths.contains(rfPath) || rfPerMinute < 1 || rfPerMinute > 30) {
      throw const FormatException('Invalid gateway path or rate.');
    }
    DataBroker.dispatch(
      deviceId: 0,
      name: 'AprsIsGateToInternet',
      data: toInternet ? 1 : 0,
    );
    DataBroker.dispatch(deviceId: 0, name: 'AprsIsRfPath', data: rfPath);
    DataBroker.dispatch(
      deviceId: 0,
      name: 'AprsIsRfPerMinute',
      data: rfPerMinute,
    );
  }
}
