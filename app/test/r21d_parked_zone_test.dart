import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/models.dart';

import 'support/follow_route_fakes.dart';

Future<RouteFixture> parkedP0(
  List<LocationFix> trace, {
  double x = 0,
  double y = 0,
}) async {
  final f = RouteFixture();
  addTearDown(f.dispose);
  f.self = testFix(x, y: y, handle: 'self', speed: 0);
  f.leader = testFix(160);
  f.trace = [f.leader!];
  await f.start();
  f.trace = trace;
  f.leader = trace.last;
  f.update();
  return f;
}

void main() {
  for (final amplitude in [2.0, 4.0, 5.0]) {
    test(
      'R21d.1 sixty seconds of parked jitter cannot consume the P0 turn window ($amplitude)',
      () async {
        final f = await parkedP0(
          [
            testFix(160),
            for (var n = 1; n <= 12; n++)
              testFix(
                160 + (n.isOdd ? amplitude : -amplitude),
                seq: n,
                at: routeEpoch + n * 5000,
                speed: 0,
              ),
            for (var n = 1; n <= 50; n++)
              testFix(
                160 + n * 10,
                seq: n + 12,
                at: routeEpoch + 60000 + n * 1000,
                speed: 10,
              ),
          ],
          x: 160,
          y: 64,
        );
        f.drive(160, y: 44, speed: 20);
        f.drive(160, y: 24, speed: 20);
        expect(f.state.anchorReached, isFalse);
        for (final x in [180.0, 200.0, 220.0]) f.drive(x, y: 24, speed: 20);
        expect(f.state.phase, FollowPhase.onTrace);
        expect(f.rejoinedEvents, [false]);
        expect(f.departures, isEmpty);
        expect(f.calls, hasLength(1));
      },
    );
  }

  test(
    'R21d.2 a parked jitter tangent cannot reverse a slow correct P0 departure',
    () async {
      final f = await parkedP0([
        testFix(160),
        testFix(164, seq: 1, at: routeEpoch + 5000, speed: 0),
        testFix(156, seq: 2, at: routeEpoch + 10000, speed: 0),
        for (var n = 1; n <= 50; n++)
          testFix(
            160 + n * 10,
            seq: n + 2,
            at: routeEpoch + 10000 + n * 1000,
            speed: 10,
          ),
      ], x: 100);
      f.drive(115, speed: 15);
      f.drive(135, speed: 20);
      expect(f.state.anchorReached, isTrue);
      for (var x = 139.0; x <= 171; x += 4) {
        f.drive(x, elapsed: 2000, speed: 2);
        expect(f.departures, isEmpty);
        if (x < 167) {
          expect(
            f.joins,
            isEmpty,
            reason: 'parked length cannot supply the 10 m join progress',
          );
        }
      }
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.rejoinedEvents, [false]);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'R21d.3 a twelve metre spike and return cannot become the exit direction',
    () async {
      final f = await parkedP0(
        [
          testFix(160),
          testFix(160, y: 12, seq: 1, at: routeEpoch + 5000, speed: 0),
          testFix(160, seq: 2, at: routeEpoch + 10000, speed: 0),
          for (var n = 1; n <= 50; n++)
            testFix(
              160 + n * 10,
              seq: n + 2,
              at: routeEpoch + 10000 + n * 1000,
              speed: 10,
            ),
        ],
        x: 160,
        y: -40,
      );
      for (final y in [-20.0, 0.0, 6.0, 12.0]) f.drive(160, y: y, speed: 20);
      expect(f.state.phase, FollowPhase.approaching);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
    },
  );

  test(
    'R21d.3 the real exit after a twelve metre spike still accepts a correct pass',
    () async {
      final f = await parkedP0([
        testFix(160),
        testFix(160, y: 12, seq: 1, at: routeEpoch + 5000, speed: 0),
        testFix(160, seq: 2, at: routeEpoch + 10000, speed: 0),
        for (var n = 1; n <= 50; n++)
          testFix(
            160 + n * 10,
            seq: n + 2,
            at: routeEpoch + 10000 + n * 1000,
            speed: 10,
          ),
      ]);
      for (var x = 20.0; x <= 140; x += 20) f.drive(x, speed: 20);
      expect(f.state.anchorReached, isTrue);
      expect(f.joins, isEmpty);
      f.drive(160, speed: 20);
      f.drive(180, speed: 20);
      expect(f.rejoinedEvents, [false]);
      expect(f.departures, isEmpty);
    },
  );

  for (final speed in [0.0, null]) {
    test(
      'R21d.3 a parked spike without a real exit cannot supply join evidence (speed=$speed)',
      () async {
        final f = await parkedP0(
          [
            testFix(160),
            testFix(160, y: 12, seq: 1, at: routeEpoch + 5000, speed: speed),
            testFix(160, seq: 2, at: routeEpoch + 10000, speed: speed),
          ],
          x: 160,
          y: -40,
        );
        for (final y in [-20.0, 0.0, 6.0, 12.0]) f.drive(160, y: y, speed: 20);
        expect(f.state.phase, FollowPhase.approaching);
        expect(f.joins, isEmpty);
        expect(f.departures, isEmpty);
      },
    );
  }
}
