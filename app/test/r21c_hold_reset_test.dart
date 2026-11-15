import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';

import 'support/follow_route_fakes.dart';

void main() {
  test(
    'R21c location hold restarts join evidence while preserving confirmed P0 passage',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.start();
      f.grow(500);
      f.drive(-20, speed: 20);
      expect(f.state.anchorReached, isTrue);
      expect(f.joins, isEmpty);

      f.time += 10001;
      f.selfAge = 10001;
      f.update();
      expect(f.state.condition, FollowRouteCondition.locationDelayed);

      f.selfAge = 0;
      // R21e keeps the physical passage fact. The hold still invalidates
      // movement evidence, so three new samples must precede the join.
      f.drive(30, speed: 20);
      for (final x in [36.0, 42.0]) {
        f.drive(x, speed: 6);
        expect(f.joins, isEmpty);
      }
      expect(f.state.phase, FollowPhase.approaching);
      f.drive(48, speed: 6);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.rejoinedEvents, [false]);

      // Keep the original return leg, and reject a duplicate join notice.
      f.drive(-20, elapsed: 2000, speed: 34);
      f.drive(0, speed: 20);
      f.drive(6, speed: 6);
      expect(f.joins, hasLength(1));
      f.drive(12, speed: 6);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.rejoinedEvents, [false]);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );
}
