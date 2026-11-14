import 'dart:math' as math;

import '../net/follow_route.dart';
import '../net/models.dart';

const _radians = math.pi / 180;
const _earth = 6371000.0;

double routeDistance(RoutePoint a, RoutePoint b) {
  final lat = (b.lat - a.lat) * _radians;
  final lng = (b.lng - a.lng) * _radians;
  final h =
      math.pow(math.sin(lat / 2), 2) +
      math.cos(a.lat * _radians) *
          math.cos(b.lat * _radians) *
          math.pow(math.sin(lng / 2), 2);
  return 2 * _earth * math.asin(math.sqrt(h.clamp(0, 1)));
}

double routeBearing(RoutePoint a, RoutePoint b) =>
    (math.atan2(
          math.sin((b.lng - a.lng) * _radians) * math.cos(b.lat * _radians),
          math.cos(a.lat * _radians) * math.sin(b.lat * _radians) -
              math.sin(a.lat * _radians) *
                  math.cos(b.lat * _radians) *
                  math.cos((b.lng - a.lng) * _radians),
        ) /
        _radians) %
    360;

double routeDirectionDifference(double a, double b) =>
    ((a - b + 180) % 360 - 180).abs();
RoutePoint interpolateRoute(RoutePoint a, RoutePoint b, double t) =>
    RoutePoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);

/// Pleos has no documented metre accuracy. The 25 m fallback is an assumed
/// jump allowance only, never a measured accuracy or verified source identity.
/// Keep in sync with server/src/routes.ts. Explicit bad acc never falls back.
double? routeAccuracyAllowance(LocationFix fix) {
  final acc = fix.acc;
  if (acc == null) return fix.src == 'vehicle' ? 25 : null;
  return acc.isFinite && acc >= 0 && acc <= 25 ? acc : null;
}

bool routeQuality(LocationFix fix) =>
    fix.lat.isFinite &&
    fix.lng.isFinite &&
    fix.lat.abs() <= 90 &&
    fix.lng.abs() <= 180 &&
    routeAccuracyAllowance(fix) != null;

bool traceContinuous(LocationFix a, LocationFix b) {
  final seconds = (b.at - a.at) / 1000;
  return a.handle == b.handle &&
      a.stream == b.stream &&
      b.seq == a.seq + 1 &&
      routeQuality(a) &&
      routeQuality(b) &&
      seconds > 0 &&
      seconds <= 10 &&
      routeDistance(RoutePoint.fromFix(a), RoutePoint.fromFix(b)) <=
          70 * seconds +
              routeAccuracyAllowance(a)! +
              routeAccuracyAllowance(b)!;
}

class RouteProjection {
  const RouteProjection(
    this.point,
    this.index,
    this.fraction,
    this.distance,
    this.along,
    this.bearing, {
    this.ambiguous = false,
  });
  final RoutePoint point;
  final int index;
  final double fraction, distance, along, bearing;
  final bool ambiguous;
}

/// Coordinates are geometry, never fabricated location samples/sequence IDs.
RouteProjection? projectRoute(
  RoutePoint point,
  List<RoutePoint> path, {
  double minimum = 0,
  double maximum = double.infinity,
}) {
  final candidates = <RouteProjection>[];
  var along = 0.0;
  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i], b = path[i + 1];
    final length = routeDistance(a, b);
    if (length < .01) continue;
    final scale = math.cos(point.lat * _radians);
    final x = (b.lng - a.lng) * scale, y = b.lat - a.lat;
    final px = (point.lng - a.lng) * scale, py = point.lat - a.lat;
    final lower = ((minimum - along) / length).clamp(0.0, 1.0);
    final upper = ((maximum - along) / length).clamp(0.0, 1.0);
    if (along + length >= minimum && along <= maximum && lower <= upper) {
      final t = ((px * x + py * y) / (x * x + y * y)).clamp(lower, upper);
      final projected = interpolateRoute(a, b, t);
      candidates.add(
        RouteProjection(
          projected,
          i,
          t,
          routeDistance(point, projected),
          along + length * t,
          routeBearing(a, b),
        ),
      );
    }
    along += length;
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => a.distance.compareTo(b.distance));
  final best = candidates.first;
  // Non-neighbouring visits to a crossing/parallel road cannot be disambiguated
  // by a 2-D fix. Keep waiting rather than jumping to the later visit.
  final ambiguous = candidates
      .skip(1)
      .any(
        (other) =>
            (other.along - best.along).abs() > 40 &&
            other.distance <= 25 &&
            (other.distance - best.distance).abs() <= 5,
      );
  return RouteProjection(
    best.point,
    best.index,
    best.fraction,
    best.distance,
    best.along,
    best.bearing,
    ambiguous: ambiguous,
  );
}

double routeLength(List<RoutePoint> points) {
  var length = 0.0;
  for (var i = 1; i < points.length; i++) {
    length += routeDistance(points[i - 1], points[i]);
  }
  return length;
}

/// Only a locally aligned extension of the latest recorded segment suggests
/// passing its end. It is not proof of which vehicle is on which physical road.
bool isBeyondTraceEnd(
  RoutePoint self,
  List<RoutePoint> points,
  double direction,
) {
  if (points.length < 2) return false;
  final end = points.last;
  RoutePoint? before;
  for (var i = points.length - 2; i >= 0; i--) {
    if (routeDistance(points[i], end) >= 3) {
      before = points[i];
      break;
    }
  }
  if (before == null) return false;
  final tangent = routeBearing(before, end);
  if (routeDirectionDifference(direction, tangent) > 60) return false;
  final distance = routeDistance(end, self);
  final angle =
      routeDirectionDifference(tangent, routeBearing(end, self)) * _radians;
  return distance * math.cos(angle) > 25 &&
      (distance * math.sin(angle)).abs() <= 25;
}

class TracePath {
  TracePath(List<LocationFix> fixes)
    : fixes = List.unmodifiable(fixes),
      points = List.unmodifiable(fixes.map(RoutePoint.fromFix)) {
    cumulative = [0];
    _indices = {
      for (var i = 0; i < fixes.length; i++) SampleRef.of(fixes[i]): i,
    };
    for (var i = 1; i < points.length; i++) {
      cumulative.add(cumulative.last + routeDistance(points[i - 1], points[i]));
    }
  }
  final List<LocationFix> fixes;
  final List<RoutePoint> points;
  late final List<double> cumulative;
  late final Map<SampleRef, int> _indices;
  double? resolve(RouteAnchor anchor) {
    final i = _indices[anchor.start];
    if (i == null) return null;
    if (anchor.end == null) return cumulative[i];
    if (i + 1 == fixes.length || SampleRef.of(fixes[i + 1]) != anchor.end)
      return null;
    return cumulative[i] +
        (cumulative[i + 1] - cumulative[i]) * anchor.fraction;
  }

  RouteAnchor at(double meters) {
    for (var i = 1; i < fixes.length; i++) {
      final length = cumulative[i] - cumulative[i - 1];
      if (length > .01 && (meters <= cumulative[i] || i == fixes.length - 1)) {
        return RouteAnchor.segment(
          SampleRef.of(fixes[i - 1]),
          SampleRef.of(fixes[i]),
          ((meters - cumulative[i - 1]) / length).clamp(0.0, 1.0),
        );
      }
    }
    return RouteAnchor.sample(SampleRef.of(fixes.last));
  }

  RoutePoint pointAt(double meters) {
    if (points.length == 1) return points.single;
    for (var i = 1; i < points.length; i++) {
      final length = cumulative[i] - cumulative[i - 1];
      if (length > .01 && meters <= cumulative[i]) {
        return interpolateRoute(
          points[i - 1],
          points[i],
          ((meters - cumulative[i - 1]) / length).clamp(0.0, 1.0),
        );
      }
    }
    return points.last;
  }

  List<RoutePoint> after(double meters) => [
    pointAt(meters),
    for (var i = 0; i < points.length; i++)
      if (cumulative[i] > meters) points[i],
  ];
}

List<TracePath> splitFollowTrace(List<LocationFix> fixes) {
  final paths = <TracePath>[];
  var current = <LocationFix>[];
  for (final fix in fixes) {
    if (!routeQuality(fix) ||
        current.isNotEmpty && !traceContinuous(current.last, fix)) {
      if (current.isNotEmpty) paths.add(TracePath(current));
      current = [];
    }
    if (routeQuality(fix)) current.add(fix);
  }
  if (current.isNotEmpty) paths.add(TracePath(current));
  return paths;
}

class JoinCandidate {
  const JoinCandidate(this.anchor, this.point, this.path);
  final RouteAnchor anchor;
  final RoutePoint point;
  final TracePath path;
}

JoinCandidate? selectJoinCandidate(
  RoutePoint self,
  List<TracePath> paths, {
  RouteAnchor? progress,
  num? progressAt,
  double advance = 60,
}) {
  JoinCandidate? best;
  var distance = double.infinity;
  var ambiguous = false;
  var reachedProgress = progress == null;
  for (final path in paths) {
    final minimum = progress == null ? 0.0 : path.resolve(progress);
    if (minimum != null) reachedProgress = true;
    if (!reachedProgress &&
        progressAt != null &&
        path.fixes.first.at > progressAt) {
      reachedProgress = true;
    }
    if (!reachedProgress) continue;
    final projection = projectRoute(self, path.points, minimum: minimum ?? 0);
    if (projection == null || projection.ambiguous) continue;
    if (best != null && (projection.distance - distance).abs() <= 5)
      ambiguous = true;
    if (projection.distance >= distance) continue;
    if (distance - projection.distance > 5) ambiguous = false;
    distance = projection.distance;
    final meters = math.min(projection.along + advance, path.cumulative.last);
    final anchor = path.at(meters);
    if (anchor.end != null)
      best = JoinCandidate(anchor, path.pointAt(meters), path);
  }
  return ambiguous ? null : best;
}

/// Snapshot delivery and duplicate refs never restart a location's age.
class FollowLocationClock {
  FollowLocationClock(this.now);
  final int Function() now;
  LocationFix? _fix;
  int _observed = 0;
  double _initialAge = double.infinity;
  num? _serverNow;
  num? get serverNowMs =>
      _serverNow == null ? null : _serverNow! + now() - _observed;
  void observe(LocationFix fix, num? serverNowMs) {
    if (_fix != null && _fix!.handle != fix.handle) clear();
    final old = _fix;
    if (old != null && SampleRef.of(old) == SampleRef.of(fix)) return;
    if (old != null &&
        (fix.at <= old.at || old.stream == fix.stream && fix.seq <= old.seq))
      return;
    _fix = fix;
    _observed = now();
    _serverNow = serverNowMs;
    _initialAge =
        serverNowMs == null ||
            !serverNowMs.isFinite ||
            fix.receivedAt <= 0 ||
            serverNowMs < fix.receivedAt ||
            serverNowMs < fix.at
        ? double.infinity
        : math
              .max(serverNowMs - fix.receivedAt, serverNowMs - fix.at)
              .toDouble();
  }

  double age(LocationFix? fix) =>
      fix == null ||
          _fix == null ||
          SampleRef.of(fix) != SampleRef.of(_fix!) ||
          fix.handle != _fix!.handle
      ? double.infinity
      : _initialAge + now() - _observed;
  void clear() {
    _fix = null;
    _serverNow = null;
    _initialAge = double.infinity;
  }
}
