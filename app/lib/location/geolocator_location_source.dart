import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'location_source.dart';

LocationPermissionState locationPermissionState(
  LocationPermission permission,
) => switch (permission) {
  LocationPermission.always ||
  LocationPermission.whileInUse => LocationPermissionState.granted,
  LocationPermission.deniedForever => LocationPermissionState.deniedForever,
  LocationPermission.denied ||
  LocationPermission.unableToDetermine => LocationPermissionState.denied,
};

class GeolocatorLocationSource implements LocationSource {
  @override
  Future<LocationPermissionState> requestPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionState.serviceOff;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    // 권한 시트가 열린 동안 서비스를 끈 경우도 같은 상태로 알린다.
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionState.serviceOff;
    }
    return locationPermissionState(permission);
  }

  LocationSettings get settings => switch (defaultTargetPlatform) {
    TargetPlatform.android => AndroidSettings(
      forceLocationManager: true,
      accuracy: LocationAccuracy.high,
      intervalDuration: const Duration(seconds: 1),
      distanceFilter: 0,
    ),
    TargetPlatform.iOS || TargetPlatform.macOS => AppleSettings(
      accuracy: LocationAccuracy.best,
      activityType: ActivityType.automotiveNavigation,
      distanceFilter: 0,
      allowBackgroundLocationUpdates: false,
    ),
    _ => const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    ),
  };

  @override
  Stream<LocationSample> watch() =>
      Geolocator.getPositionStream(locationSettings: settings).map(
        (position) => LocationSample(
          lat: position.latitude,
          lng: position.longitude,
          accuracy: position.hasAccuracy
              ? _nonnegative(position.accuracy)
              : null,
          speed: position.hasSpeed ? _nonnegative(position.speed) : null,
          heading: position.hasHeading && position.heading <= 360
              ? _nonnegative(position.heading)
              : null,
          at: position.timestamp,
        ),
      );
}

// iOS의 알 수 없는 속도/방향(-1)을 서버의 유효한 숫자로 보내지 않는다.
double? _nonnegative(double value) =>
    value.isFinite && value >= 0 ? value : null;
