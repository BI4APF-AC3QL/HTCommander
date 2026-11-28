/// Validated one-shot position. Requesting GPS does not authorize transmission.
class RemotePositionFix {
  const RemotePositionFix(
    this.latitude,
    this.longitude,
    this.accuracy,
    this.capturedAt,
    this.radio,
  );
  final double latitude, longitude;
  final double? accuracy;
  final DateTime capturedAt;
  final bool radio;

  static RemotePositionFix? parse(
    Map value,
    DateTime now, {
    required bool radio,
  }) {
    final lat = value['latitude'],
        lon = value['longitude'],
        accuracy = value['accuracy'];
    final stamp = radio ? value['receivedTime'] : value['capturedAt'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        stamp is! String) {
      return null;
    }
    final time = DateTime.tryParse(stamp);
    if (time == null ||
        now.difference(time) > const Duration(minutes: 2) ||
        time.difference(now) > const Duration(seconds: 5)) {
      return null;
    }
    if (radio && value['locked'] != true) return null;
    if (accuracy is! num ||
        !accuracy.isFinite ||
        accuracy < 0 ||
        accuracy > 100 ||
        (!radio && accuracy == 0)) {
      return null;
    }
    return RemotePositionFix(
      lat.toDouble(),
      lon.toDouble(),
      accuracy == 0 ? null : accuracy.toDouble(),
      time,
      radio,
    );
  }

  Map<String, Object?> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'capturedAt': capturedAt.toIso8601String(),
    'radio': radio,
  };

  String get information =>
      '!${_coordinate(latitude, true)}/${_coordinate(longitude, false)}'
      '${radio ? '-' : '>'}HTCommander ${radio ? 'radio' : 'phone'}';

  // Round total minutes first so 59.999 minutes carries into degrees.
  static String _coordinate(double value, bool latitude) {
    final units = (value.abs() * 6000).round();
    final degrees = units ~/ 6000, minutes = units % 6000;
    final hemisphere = latitude
        ? (value < 0 ? 'S' : 'N')
        : (value < 0 ? 'W' : 'E');
    return '${degrees.toString().padLeft(latitude ? 2 : 3, '0')}'
        '${(minutes ~/ 100).toString().padLeft(2, '0')}.'
        '${(minutes % 100).toString().padLeft(2, '0')}$hemisphere';
  }
}

class RemotePositionRequest {
  const RemotePositionRequest(this.radioDeviceId, this.clientId, this.fix);
  final int radioDeviceId, clientId;
  final RemotePositionFix fix;
}
