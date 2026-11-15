import '../net/follow_route.dart';
import 'follow_route_geometry.dart';

typedef P0Exit = ({
  RouteAnchor anchor,
  RoutePoint point,
  num at,
  double bearing,
});

/// Facts belong to one initial P0, not to a run of fresh GPS measurements.
/// The controller discards this object only when that guidance/anchor changes.
class P0Arrival {
  P0Arrival(this.seed, this.point);
  final RouteAnchor seed;
  final RoutePoint point;
  bool visited = false;
  RouteAnchor? passage;
  P0Exit? exit;
  TracePath? _source, _guidance;

  TracePath? cachedPath(TracePath source) =>
      identical(source, _source) ? _guidance : null;

  TracePath prepare(TracePath source) {
    if (identical(source, _source)) return _guidance!;
    _source = source;
    if (exit == null) _findExit(source);
    final ref = exit?.anchor.start ?? seed.start;
    final index = source.fixes.indexWhere((fix) => SampleRef.of(fix) == ref);
    if (index < 0) return _guidance = source;
    // Before departure is established, the post-P0 samples are parked
    // geometry. After it is established, ordinary projection starts at exit.
    return _guidance = TracePath(
      exit == null ? [source.fixes[index]] : source.fixes.sublist(index),
    );
  }

  void _findExit(TracePath path) {
    final seedIndex = path.fixes.indexWhere(
      (fix) => SampleRef.of(fix) == seed.start,
    );
    if (seedIndex < 0) return;
    var start = seedIndex;
    int? firstOutside;
    double? previousBearing;
    for (var i = seedIndex + 1; i < path.points.length; i++) {
      final previous = path.points[i - 1], next = path.points[i];
      final before = routeDistance(point, previous);
      final distance = routeDistance(point, next);
      final moved = routeDistance(previous, next);
      if (moved < .01) {
        if (firstOutside == null && distance < 10) start = i;
        previousBearing = null;
        continue;
      }
      final bearing = routeBearing(previous, next);
      final reversed =
          previousBearing != null &&
          routeDirectionDifference(previousBearing, bearing) >= 120;
      if (reversed) {
        firstOutside = null;
        start = distance < 10 ? i : i - 1;
        if (distance < 10) {
          previousBearing = null;
          continue;
        }
      } else if (path.fixes[i - 1].speed == 0 &&
          before < 10 &&
          (path.fixes[i].speed == null
              ? moved >= 2.999999
              : path.fixes[i].speed!.isFinite && path.fixes[i].speed! > 0)) {
        // Speed can locate the end of a stop; it cannot veto slow geometry.
        start = i - 1;
      }
      previousBearing = bearing;
      if (distance < 9.999999) {
        firstOutside = null;
        continue;
      }
      if (firstOutside == null) {
        firstOutside = i;
        continue;
      }
      // Sustained geometry, including a slow/curved exit: two outside samples
      // and the existing 3 m direction baseline. A lone spike returning to
      // P0 cannot qualify. No speed or strictly increasing-radius gate.
      if (routeDistance(path.points[firstOutside], next) < 2.999999) continue;
      exit = (
        anchor: RouteAnchor.sample(SampleRef.of(path.fixes[start])),
        point: path.points[start],
        at: path.fixes[start].at,
        bearing: routeBearing(point, path.points[firstOutside]),
      );
      return;
    }
  }

  bool near(RoutePoint self) => routeDistance(self, point) <= 25.000001;

  void observe(
    RoutePoint self,
    TracePath? path,
    RouteProjection? projection,
    double? direction,
  ) {
    if (near(self)) visited = true;
    if (passage != null ||
        !visited ||
        exit == null ||
        path == null ||
        projection == null ||
        projection.ambiguous ||
        projection.distance > 25.000001 ||
        direction == null)
      return;
    final atP0 =
        near(self) &&
        routeDirectionDifference(direction, exit!.bearing) <= 60.000001;
    final afterP0 =
        projection.along > 0 &&
        projection.along <= 60.000001 &&
        routeDirectionDifference(direction, projection.bearing) <= 60.000001;
    if (atP0 || afterP0) passage = path.at(projection.along);
  }
}
