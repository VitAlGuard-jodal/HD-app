import 'package:flutter/foundation.dart';

import 'follow_route_geometry.dart';

/// Debug-only aggregates. Never log coordinates, accounts or route shapes.
void debugGuidanceProjection(String kind, GuidanceRouteProjection value) {
  if (!kDebugMode) return;
  void write(String scope, RouteProjection? projection) {
    debugPrint(
      'follow-guidance: projection=$kind/$scope '
      'ambiguous=${projection?.ambiguous} '
      'distance=${projection?.distance.toStringAsFixed(1)} '
      'along=${projection?.along.toStringAsFixed(1)} '
      'candidates=${projection?.candidateCount ?? 0}',
    );
  }

  write('full', value.full);
  write('window', value.window);
}
