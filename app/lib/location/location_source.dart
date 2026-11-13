class LocationSample {
  const LocationSample({
    required this.lat,
    required this.lng,
    this.accuracy,
    this.speed,
    this.heading,
    this.altitude,
    this.confidence,
    required this.at,
  });
  final double lat, lng;
  final double? accuracy, speed, heading;
  // Pleos confidence has no documented metre unit; never send it as accuracy.
  final double? altitude, confidence;
  final DateTime at;
}

enum LocationPermissionState { granted, denied, deniedForever, serviceOff }

abstract class LocationSource {
  Future<LocationPermissionState> requestPermission();

  // 구독 해제 시 실제 위치 하드웨어의 구독도 함께 끝내야 한다.
  Stream<LocationSample> watch();
}
