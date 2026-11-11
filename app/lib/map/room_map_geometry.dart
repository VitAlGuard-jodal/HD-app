import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../net/models.dart';

class RoomMapPosition {
  const RoomMapPosition(this.fix, {required this.displayName});
  final LocationFix fix;
  final String displayName;

  String get name => displayName.trim().isEmpty ? fix.handle : displayName;
}

class RoomMapBounds {
  const RoomMapBounds(this.self, this.ahead);
  final LocationFix self, ahead;
  double get south => math.min(self.lat, ahead.lat);
  double get north => math.max(self.lat, ahead.lat);
  double get west => math.min(self.lng, ahead.lng);
  double get east => math.max(self.lng, ahead.lng);
}

const _distance = Distance(roundResult: false);
LatLng _point(LocationFix fix) => LatLng(fix.lat, fix.lng);

/// 방향이 있으면 전방 반평면에서 가장 가까운 점, 없으면 궤적의 최근접
/// 꼭짓점 다음 점을 고른다. 앞쪽 점이 없으면 그룹장의 현재 위치를 쓴다.
RoomMapBounds? followBounds({
  required LocationFix? self,
  required LocationFix? leader,
  required List<LocationFix> trail,
}) {
  if (self == null || leader == null) return null;
  return RoomMapBounds(
    self,
    roomForwardPoint(self: self, leader: leader, trail: trail)!,
  );
}

LocationFix? roomForwardPoint({
  required LocationFix? self,
  required LocationFix? leader,
  required List<LocationFix> trail,
}) {
  if (self == null) return null;
  LocationFix? ahead;
  var nearest = double.infinity;
  var nearestIndex = -1;
  for (var i = 0; i < trail.length; i++) {
    final point = trail[i];
    final meters = _distance(_point(self), _point(point));
    if (self.heading != null) {
      final heading = self.heading! * math.pi / 180;
      final north = point.lat - self.lat;
      final east = (point.lng - self.lng) * math.cos(self.lat * math.pi / 180);
      if (meters < 1 ||
          north * math.cos(heading) + east * math.sin(heading) <= 0)
        continue;
    }
    // 겹치는 길에서는 더 최근에 지나간 꼭짓점을 택한다.
    if (meters <= nearest) {
      nearest = meters;
      nearestIndex = i;
      ahead = point;
    }
  }
  if (self.heading == null) {
    ahead = nearestIndex >= 0 && nearestIndex + 1 < trail.length
        ? trail[nearestIndex + 1]
        : null;
  }
  return ahead ?? leader;
}

double roomDistanceMeters(LocationFix self, LocationFix leader) =>
    _distance(_point(self), _point(leader));

String roomDistanceLabel(LocationFix self, LocationFix leader) {
  final meters = roomDistanceMeters(self, leader);
  return meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(1)} km'
      : '${meters.round()} m';
}

double zoomForDistance(double meters) => switch (meters) {
  < 200 => 17,
  < 600 => 16,
  < 1500 => 15,
  < 4000 => 14,
  _ => 13,
};

class RoomFollowCamera {
  const RoomFollowCamera({
    required this.target,
    required this.zoom,
    required this.bearing,
    this.tilt = 50,
  });
  final LocationFix target;
  final double zoom, bearing, tilt;
}

/// SDK 좌표·카메라 객체 없이 주행 카메라의 파라미터를 계산한다.
RoomFollowCamera? naverFollowCamera({
  required LocationFix? self,
  required LocationFix? leader,
  required List<LocationFix> trail,
  required double currentBearing,
  bool isLeader = false,
}) {
  if (self == null) return null;
  final ahead = roomForwardPoint(self: self, leader: leader, trail: trail);
  final hasDirection =
      ahead != null && (ahead.lat != self.lat || ahead.lng != self.lng);
  final bearing =
      self.heading ??
      (hasDirection
          ? (_distance.bearing(_point(self), _point(ahead)) + 360) % 360
          : currentBearing);
  return RoomFollowCamera(
    target: self,
    zoom: isLeader || leader == null
        ? 16
        : zoomForDistance(roomDistanceMeters(self, leader)),
    bearing: bearing % 360,
  );
}

/// NPathOverlay는 좌표가 둘 이상일 때만 생성·갱신한다.
List<LocationFix> roomPathPoints(List<LocationFix> trail) =>
    trail.length < 2 ? const [] : trail;
