import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/meeting_plan.dart';

import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

List<RoutePoint> approachLoop() => [
  testPoint(0),
  testPoint(-300),
  testPoint(-300, 4),
  testPoint(1000, 4),
];

Future<RouteFixture> p0Loop({List<RoutePoint>? points}) async {
  final f = RouteFixture();
  addTearDown(f.dispose);
  f.self = testFix(0, handle: 'self', speed: 0);
  f.leader = testFix(1000);
  f.trace = [f.leader!];
  f.update();
  f.calls.single.succeed(points: points ?? approachLoop());
  await flush();
  f.trace = [for (var n = 0; n <= 100; n++) testFix(1000 + n * 10, seq: n)];
  f.leader = f.trace.last;
  f.update();
  return f;
}

void main() {
  test(
    'R15 planJoin passes J after skipping the initial U-turn loop',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(
        plan: planJson(join: 1000, destination: 2000, policy: 'proceed'),
        runtime: runtimeJson(phase: 'departed', leaderPhase: 'toDestination'),
      );
      f.routes.single.succeed(points: approachLoop());
      await flush();
      expect(f.controller.view!.connector, isNotEmpty);
      for (var x = 20.0; x <= 1020; x += 20) f.drive(x, speed: 20);
      final passes = f.calls.where((c) => c.path.endsWith('/pass-evidence'));
      expect(passes, hasLength(1));
      expect(passes.single.body!['pointKind'], 'joinPoint');
      expect(f.routes, hasLength(1));
      passes.single.complete({
        'runtime': runtimeJson(
          runtimeRevision: 2,
          phase: 'departed',
          leaderPhase: 'toDestination',
          followerPhase: 'toDestination',
          branch: 'destination',
          passed: routeEpoch + f.time,
        ),
      });
      await flush();
      expect(f.routes, hasLength(2));
      expect(f.routes.last.request.routeKind, PlanRouteKind.planDestination);
      f.routes.last.succeed();
      await flush();
      expect(f.controller.status, '목적지로 먼저 이동');
    },
  );

  test(
    'R15 P0 joins the trace after skipping the initial U-turn loop',
    () async {
      final f = await p0Loop();
      for (var x = 20.0; x <= 1020; x += 20) f.drive(x, speed: 20);
      expect(f.joins, hasLength(1));
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'R15 grey connector rejoins after skipping its initial U-turn loop',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.grow(2000);
      f.depart();
      f.driveUntil(30000);
      final call = f.calls.last;
      final x = call.origin.lng * metersPerDegree;
      final y = call.origin.lat * metersPerDegree;
      final anchorX = call.anchor.lng * metersPerDegree;
      call.succeed(
        points: [
          call.origin,
          testPoint(x - 300, y),
          testPoint(x - 300, y + 4),
          testPoint(anchorX, y + 4),
          call.anchor,
        ],
      );
      await flush();
      expect(f.state.status, '회색 경로를 따라 다시 합류');
      for (var step = 10.0; step <= 60; step += 10)
        f.drive(x + step, y: y, speed: 10);
      for (var south = y - 20; south >= 0; south -= 20)
        f.drive(anchorX, y: south, speed: 20);
      for (final step in [6.0, 12.0, 18.0]) f.drive(anchorX + step, speed: 6);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.rejoinedEvents, [false, true]);
      expect(f.departures, hasLength(1));
      expect(f.calls, hasLength(2));
    },
  );

  test(
    'R15 progress requires three distinct samples, two seconds and ten metres',
    () async {
      final f = await p0Loop();
      f.drive(20, speed: 20);
      f.drive(25, speed: 5);
      for (var n = 0; n < 5; n++) f.update();
      expect(f.state.routeProgress, lessThan(120));
      f.drive(29, speed: 4);
      expect(
        f.state.routeProgress,
        lessThan(120),
        reason: 'only 9 m of evidence',
      );
      // Stay above 10 m in projected arclength despite the 4 m latitude offset.
      f.drive(30.01, speed: 3);
      expect(f.state.routeProgress, greaterThan(600));
      expect(f.joins, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'R15 three fast samples cannot replace two seconds of evidence',
    () async {
      final f = await p0Loop();
      for (final x in [20.0, 40.0, 60.0]) f.drive(x, elapsed: 500, speed: 40);
      expect(f.state.routeProgress, lessThan(120));
      f.drive(80, elapsed: 1000, speed: 20);
      expect(f.state.routeProgress, greaterThan(600));
      expect(f.joins, isEmpty);
    },
  );

  for (final offset in [25.0, 25.1]) {
    test('R15 later road distance boundary is 25 m ($offset)', () async {
      final f = await p0Loop();
      f.drive(20, y: 4 + offset, elapsed: 2000, speed: 20);
      f.drive(30, y: 4 + offset, speed: 10);
      f.drive(40, y: 4 + offset, speed: 10);
      expect(f.state.routeProgress > 600, offset == 25);
      expect(f.joins, isEmpty);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    });
  }

  for (final angle in [60.0, 60.1]) {
    test('R15 later road direction boundary is 60 degrees ($angle)', () async {
      final f = await p0Loop();
      f.drive(100, y: -10, elapsed: 2000, speed: 50);
      for (var n = 1; n <= 2; n++) {
        f.drive(
          100 + n * 10,
          y: -10 + n * 10 * math.tan(angle * math.pi / 180),
          speed: 20,
        );
      }
      expect(f.state.routeProgress > 600, angle == 60);
      expect(f.joins, isEmpty);
    });
  }

  for (final gap in [false, true]) {
    test(
      'R15 ${gap ? 'sample gap' : 'stop'} clears unfinished forward evidence',
      () async {
        final f = await p0Loop(
          points: [
            testPoint(0),
            testPoint(-1000),
            testPoint(-1000, 4),
            testPoint(1000, 4),
          ],
        );
        f.drive(20, speed: 20);
        f.drive(25, speed: 5);
        f.drive(30, elapsed: gap ? 11000 : 1000, speed: 0);
        f.drive(35, speed: 5);
        f.drive(40, speed: 5);
        expect(f.state.routeProgress, lessThan(120));
        f.drive(45.01, speed: 5);
        expect(f.state.routeProgress, greaterThan(2000));
        expect(f.joins, isEmpty);
      },
    );
  }

  test(
    'R15 competing connector visits stay ambiguous while P0 arrival joins the trace',
    () async {
      final f = await p0Loop(
        points: [
          ...approachLoop(),
          testPoint(1000, 100),
          testPoint(0, 100),
          testPoint(0, 4),
          testPoint(1000, 4),
        ],
      );
      for (var x = 20.0; x <= 1020; x += 20) f.drive(x, speed: 20);
      expect(f.state.routeProgress, lessThan(120));
      expect(f.rejoinedEvents, [false]);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );
}
