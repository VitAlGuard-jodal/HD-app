import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:latlong2/latlong.dart';

import '../net/models.dart';

class RoomMapPosition {
  const RoomMapPosition(
    this.fix, {
    required this.displayName,
    this.avatar = const Avatar(),
    this.order = 0,
  });
  final LocationFix fix;
  final String displayName;
  final Avatar avatar;
  final int order;

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

/// 서버 표본은 그대로 두고, 지도에 남아 있는 참여자마다 기준점 한 개만 보관한다.
class RoomDirectionTracker {
  // 수 m 안의 정차 GPS 흔들림을 매번 새 방향으로 해석하지 않는다.
  static const minimumMovementMeters = 3.0;
  // 보행 이하의 속도에서는 센서 heading이 없거나 0으로 고정되기 쉽다.
  static const minimumHeadingSpeed = 1.5;
  // 이동 방위가 주 기준이다. 같은 사분면의 heading만 작은 보정값으로 쓴다.
  static const maximumHeadingDifference = 45.0;
  static const headingWeight = .2;

  final _members = <String, _RoomDirectionState>{};

  double? operator [](String? handle) => _members[handle]?.direction;

  void update(Iterable<LocationFix> fixes) {
    final active = <String>{};
    for (final fix in fixes) {
      active.add(fix.handle);
      final state = _members[fix.handle];
      if (state == null || state.last.stream != fix.stream) {
        // 한 번도 움직이지 않았거나 새 송신 세션이면 북쪽을 추측하지 않는다.
        _members[fix.handle] = _RoomDirectionState(fix);
        continue;
      }
      if (fix.seq <= state.last.seq) continue;
      state.last = fix;
      if (roomDistanceMeters(state.anchor, fix) < minimumMovementMeters) {
        // 기준점은 유지하여 작은 이동이 누적되게 한다. heading도 정차 중 무시한다.
        continue;
      }
      var direction =
          _distance.bearing(_point(state.anchor), _point(fix)) % 360;
      final heading = fix.heading;
      if (heading != null &&
          heading.isFinite &&
          (fix.speed ?? 0) >= minimumHeadingSpeed) {
        final difference = (heading - direction + 180) % 360 - 180;
        // 에뮬레이터의 heading 0도 이동 방위와 크게 다르면 여기서 버린다.
        if (difference.abs() <= maximumHeadingDifference) {
          direction = (direction + difference * headingWeight) % 360;
        }
      }
      state.anchor = fix;
      state.direction = direction;
    }
    _members.removeWhere((handle, _) => !active.contains(handle));
  }
}

class _RoomDirectionState {
  _RoomDirectionState(LocationFix fix) : anchor = fix, last = fix;
  LocationFix anchor, last;
  double? direction;
}

/// 화면에 선 작은 방향 표시의 각도. 지도 방위를 빼고 기울임의 세로 축소를
/// 투영하되 아이콘 자체는 눕히지 않아 프로필 테두리 바깥의 간격을 유지한다.
double roomScreenDirection(
  double direction, {
  double cameraBearing = 0,
  double cameraTilt = 0,
}) {
  final radians = ((direction - cameraBearing) % 360) * math.pi / 180;
  return (math.atan2(
            math.sin(radians),
            math.cos(radians) * math.cos(cameraTilt * math.pi / 180),
          ) *
          180 /
          math.pi) %
      360;
}

/// 방향이 있으면 전방 반평면에서 가장 가까운 점, 없으면 궤적의 최근접
/// 꼭짓점 다음 점을 고른다. 앞쪽 점이 없으면 그룹장의 현재 위치를 쓴다.
RoomMapBounds? followBounds({
  required LocationFix? self,
  required LocationFix? leader,
  required List<LocationFix> trail,
  double? direction,
}) {
  if (self == null || leader == null) return null;
  return RoomMapBounds(
    self,
    roomForwardPoint(
      self: self,
      leader: leader,
      trail: trail,
      direction: direction,
    )!,
  );
}

LocationFix? roomForwardPoint({
  required LocationFix? self,
  required LocationFix? leader,
  required List<LocationFix> trail,
  double? direction,
}) {
  if (self == null) return null;
  LocationFix? ahead;
  var nearest = double.infinity;
  var nearestIndex = -1;
  for (var i = 0; i < trail.length; i++) {
    final point = trail[i];
    final meters = _distance(_point(self), _point(point));
    if (direction != null) {
      final heading = direction * math.pi / 180;
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
  if (direction == null) {
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

class RoomFollowCameraPolicy {
  // 근거리에서는 도로 폭을 읽을 수 있는 내비 수준. 멀어진 앞차를 찾을 때만 축소한다.
  static const navigationZoom = 18.0;
  static const minimumZoom = 14.0;
  static const maximumZoom = 18.0;
}

/// Both roles default to heading-up. Only an explicit false locks north;
/// without a measured direction, retain the camera's existing bearing.
double roomCameraBearing({
  required double currentBearing,
  double? direction,
  bool? headingAligned,
}) => headingAligned == false ? 0 : (direction ?? currentBearing) % 360;

/// Self-only camera hysteresis. This does not change route/movement evidence.
class RoomSelfCameraPolicy {
  static const movingSpeed = 2.0;
  static const movingDistance = 3.0;
  static const displacementDistance = 10.0;
  static const edgeFraction = .2;
  LocationFix? _centered;

  void centered(LocationFix? fix) => _centered = fix;

  bool needsCenter(LocationFix self, Offset screen, Size viewport) {
    if (!viewport.width.isFinite ||
        !viewport.height.isFinite ||
        viewport.width <= 0 ||
        viewport.height <= 0)
      return false;
    if (screen.dx <= viewport.width * edgeFraction ||
        screen.dx >= viewport.width * (1 - edgeFraction) ||
        screen.dy <= viewport.height * edgeFraction ||
        screen.dy >= viewport.height * (1 - edgeFraction))
      return true;
    final previous = _centered;
    if (previous == null) {
      _centered = self;
      return false;
    }
    final distance = roomDistanceMeters(previous, self);
    return distance >= displacementDistance ||
        self.speed != null &&
            self.speed!.isFinite &&
            self.speed! >= movingSpeed &&
            distance >= movingDistance;
  }
}

double zoomForDistance(double meters) => switch (meters) {
  < 200 => RoomFollowCameraPolicy.maximumZoom,
  < 600 => 17,
  < 1500 => 16,
  < 4000 => 15,
  _ => RoomFollowCameraPolicy.minimumZoom,
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
  required double currentBearing,
  double? direction,
  bool isLeader = false,
  bool? headingAligned,
}) {
  if (self == null) return null;
  return RoomFollowCamera(
    target: self,
    zoom: isLeader || leader == null
        ? RoomFollowCameraPolicy.navigationZoom
        : zoomForDistance(roomDistanceMeters(self, leader)),
    // 대상의 위치는 내 진행 방향이 아니다. 아직 모르면 현재 방위를 유지한다.
    bearing: roomCameraBearing(
      currentBearing: currentBearing,
      direction: direction,
      headingAligned: headingAligned,
    ),
  );
}

/// NPathOverlay는 좌표가 둘 이상일 때만 생성·갱신한다.
List<LocationFix> roomPathPoints(List<LocationFix> trail) =>
    trail.length < 2 ? const [] : trail;
