import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_route_geometry.dart';

import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

List<RoutePoint> p0Road(String kind) => switch (kind) {
  'loop' => [
    testPoint(0),
    testPoint(200),
    testPoint(200, 100),
    testPoint(0, 100),
    testPoint(0),
    testPoint(160),
  ],
  'window-loop' => [
    testPoint(0),
    testPoint(160),
    testPoint(160, 20),
    testPoint(0, 20),
    testPoint(0),
    testPoint(160),
  ],
  'opposite' => [
    testPoint(0),
    testPoint(0, 100),
    testPoint(300, 100),
    testPoint(300),
    testPoint(160),
  ],
  _ => throw ArgumentError(kind),
};

Future<RouteFixture> p0Fixture(
  List<RoutePoint> road, {
  double origin = 0,
  double originY = 0,
  bool extendTrace = true,
  bool incomingHistory = false,
  bool atAnchor = false,
}) async {
  final f = RouteFixture();
  addTearDown(f.dispose);
  f.self = testFix(origin, y: originY, handle: 'self', speed: 0);
  final seed = incomingHistory
      ? [
          testFix(160, y: 100),
          testFix(160, y: 50, seq: 1),
          testFix(160, seq: 2),
        ]
      : [testFix(160)];
  f.trace = seed;
  f.leader = seed.last;
  f.update();
  f.calls.single.succeed(points: road, atAnchor: atAnchor);
  await flush();
  if (extendTrace) {
    f.trace = [
      ...seed,
      for (var n = 1; n <= 100; n++)
        testFix(160 + n * 10, seq: seed.last.seq + n),
    ];
    f.leader = f.trace.last;
  }
  f.update();
  return f;
}

void main() {
  for (final kind in ['loop', 'opposite', 'window-loop']) {
    test(
      'R21 P0 arrival follows the leader trace despite the connector ($kind)',
      () async {
        final road = p0Road(kind);
        final f = await p0Fixture(road);
        final elapsed = kind == 'window-loop' ? 5000 : 1000;
        final speed = kind == 'window-loop' ? 4.0 : 20.0;
        for (var x = 20.0; x <= 120; x += 20)
          f.drive(x, elapsed: elapsed, speed: speed);
        expect(f.state.anchorReached, isFalse);
        f.drive(140, elapsed: elapsed, speed: speed);
        expect(f.state.anchorReached, isTrue);
        expect(f.state.routeProgress, lessThan(routeLength(road) - 25));
        expect(f.joins, isEmpty, reason: 'arrival alone is not a trace join');
        f.drive(160, elapsed: elapsed, speed: speed);
        expect(f.joins, isEmpty);
        f.drive(180, elapsed: elapsed, speed: speed);
        expect(f.state.phase, FollowPhase.onTrace);
        expect(f.rejoinedEvents, [false]);
        expect(f.calls, hasLength(1));
        expect(f.departures, isEmpty);
      },
    );
  }

  test(
    'R21 following the connector backward through P0 is not arrival against the leader trace',
    () async {
      final f = await p0Fixture([testPoint(220), testPoint(160)], origin: 220);
      for (final x in [200.0, 180.0, 160.0, 140.0]) {
        f.drive(x, speed: 20);
        expect(f.state.anchorReached, isFalse);
      }
      expect(f.joins, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'R21 the outgoing trace direction cannot bypass the P0 radius',
    () async {
      final f = await p0Fixture(p0Road('loop'));
      for (var x = 20.0; x <= 120; x += 20) f.drive(x, speed: 20);
      f.drive(134.99, speed: 15);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
      f.drive(135, speed: 3);
      expect(f.state.anchorReached, isTrue, reason: 'exactly 25 m from P0');
    },
  );

  test(
    'R21 P0 uses the outgoing trace segment, not the incoming one',
    () async {
      final f = await p0Fixture(p0Road('opposite'), incomingHistory: true);
      for (var x = 20.0; x <= 140; x += 20) f.drive(x, speed: 20);
      expect(f.state.anchorReached, isTrue);
      expect(f.joins, isEmpty);
      for (final x in [160.0, 180.0, 186.0, 192.0]) f.drive(x, speed: 20);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.rejoinedEvents, [false]);
    },
  );

  for (final angle in [60.0, 60.01]) {
    test('R21 P0 direction boundary remains 60 degrees ($angle)', () async {
      final radians = angle * math.pi / 180;
      final f = await p0Fixture(
        const [],
        origin: 160 - 10 * math.cos(radians),
        originY: -10 * math.sin(radians),
        atAnchor: true,
      );
      expect(f.state.anchorReached, isFalse);
      f.drive(160, speed: 10);
      expect(f.state.anchorReached, angle == 60);
      expect(f.joins, isEmpty);
    });
  }

  test(
    'R21 being parked beside P0 with a trace is not directional arrival',
    () async {
      final f = await p0Fixture(const [], origin: 160, atAnchor: true);
      for (var n = 0; n < 6; n++) f.drive(n.isEven ? 160 : 161, speed: 0);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  for (final atAnchor in [false, true]) {
    test(
      'R21 no outgoing trace preserves waiting (atAnchor=$atAnchor)',
      () async {
        final f = await p0Fixture(
          [testPoint(0), testPoint(160)],
          origin: atAnchor ? 160 : 0,
          extendTrace: false,
          atAnchor: atAnchor,
        );
        if (!atAnchor) {
          for (var x = 20.0; x <= 160; x += 20) f.drive(x, speed: 20);
        }
        for (var n = 0; n < 4; n++) f.drive(160, speed: 0);
        expect(f.state.phase, FollowPhase.approaching);
        expect(
          f.state.condition,
          atAnchor
              ? FollowRouteCondition.atAnchorWaitingTrace
              : FollowRouteCondition.waitingTrace,
        );
        expect(f.joins, isEmpty);
        expect(f.departures, isEmpty);
        expect(f.calls, hasLength(1));
      },
    );
  }

  test('R21 actual trace ambiguity still holds P0 arrival', () async {
    final f = await p0Fixture(p0Road('loop'), extendTrace: false);
    f.trace = [
      testFix(160),
      testFix(200, seq: 1),
      testFix(200, y: 8, seq: 2),
      testFix(160, y: 8, seq: 3),
    ];
    f.leader = f.trace.last;
    for (var x = 20.0; x <= 180; x += 20) f.drive(x, y: 4, speed: 20);
    expect(f.state.anchorReached, isFalse);
    expect(f.joins, isEmpty);
    expect(f.departures, isEmpty);
  });

  test(
    'R21 P0 arrival still needs distinct samples, two seconds and ten metres to join',
    () async {
      final f = await p0Fixture(p0Road('loop'));
      for (var x = 20.0; x <= 160; x += 20) f.drive(x, speed: 20);
      expect(f.state.anchorReached, isTrue);
      for (var n = 0; n < 5; n++) f.update();
      expect(f.joins, isEmpty, reason: 'duplicate deliveries cannot join');
      f.drive(169, speed: 9);
      expect(f.joins, isEmpty, reason: 'only 9 m of trace progress');
      f.drive(172, speed: 3);
      expect(f.rejoinedEvents, [false]);
    },
  );

  test(
    'R21 a fast P0 pass cannot replace two seconds of join evidence',
    () async {
      final f = await p0Fixture(p0Road('loop'));
      for (var x = 20.0; x <= 120; x += 20) f.drive(x, speed: 20);
      for (final x in [140.0, 160.0, 180.0])
        f.drive(x, elapsed: 500, speed: 40);
      expect(f.state.anchorReached, isTrue);
      expect(f.joins, isEmpty);
      f.drive(200, speed: 20);
      expect(f.rejoinedEvents, [false]);
    },
  );

  test(
    'R21 slow P0 passage does not reverse against an opposite connector',
    () async {
      final f = await p0Fixture([testPoint(220), testPoint(160)], origin: 220);
      f.drive(132, elapsed: 2000, speed: 44);
      // Turn into the leader's outgoing direction. Reaching 10 m of trace
      // progress takes longer than the existing 10 s reverse-travel interval.
      for (final x in [140.0, 148.0, 156.0, 164.0]) {
        f.drive(x, elapsed: 4000, speed: 2);
        expect(f.state.anchorReached, isTrue);
        expect(f.joins, isEmpty);
        expect(f.departures, isEmpty);
      }
      f.drive(172, elapsed: 4000, speed: 2);
      expect(f.rejoinedEvents, [false]);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  for (final kind in ['loop', 'opposite']) {
    test('R21 P0 arrival does not replace J route passage ($kind)', () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(
        plan: planJson(join: 160, destination: 1000, policy: 'proceed'),
        runtime: runtimeJson(phase: 'departed', leaderPhase: 'toDestination'),
      );
      f.routes.single.succeed(points: p0Road(kind));
      await flush();
      for (var x = 20.0; x <= 180; x += 20) f.drive(x, speed: 20);
      expect(f.calls.where((c) => c.path.endsWith('/pass-evidence')), isEmpty);
      expect(f.routes, hasLength(1));
    });
  }
}
