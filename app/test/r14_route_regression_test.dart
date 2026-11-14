import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_route_geometry.dart';

import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

void main() {
  test('R14.1 initially rejected connector resumes beyond 120 m', () async {
    final f = RouteFixture();
    addTearDown(f.dispose);
    f.self = testFix(0, handle: 'self', speed: 0);
    f.leader = testFix(2000);
    f.trace = [f.leader!];
    f.update();
    f.drive(300, y: 100, elapsed: 5000, speed: 60);
    f.calls.single.succeed();
    await flush();
    expect(f.state.condition, FollowRouteCondition.routeMismatch);
    f.drive(300, y: 50, speed: 50);
    f.drive(320, speed: 54);
    expect(f.state.connector, isNotEmpty);
    expect(f.state.routeProgress, closeTo(320, .01));
    expect(f.calls, hasLength(1));
    expect(f.departures, isEmpty);
    expect(f.joins, isEmpty);
  });

  for (final destination in [false, true]) {
    test(
      'R14.1 rejected ${destination ? 'D' : 'J'} resumes beyond 120 m',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll(
          plan: planJson(join: 2000, destination: destination ? 2000 : 3000),
        );
        f.drive(300, y: 100, elapsed: 5000, speed: 60);
        f.routes.single.succeed();
        await flush();
        expect(
          f.controller.view!.condition,
          FollowRouteCondition.routeMismatch,
        );
        f.drive(300, y: 50, speed: 50);
        f.drive(320, speed: 54);
        expect(f.controller.view!.connector, isNotEmpty);
        expect(f.routes, hasLength(1));
        expect(
          f.calls.where((c) => c.path.endsWith('/pass-evidence')),
          isEmpty,
        );
      },
    );
  }

  test(
    'R14.1 slow geometry recovery does not require moving-pass speed',
    () async {
      final trace = RouteFixture();
      final meeting = MeetingFixture();
      addTearDown(trace.dispose);
      addTearDown(meeting.dispose);
      trace.self = testFix(0, handle: 'self', speed: 0);
      trace.leader = testFix(2000);
      trace.trace = [trace.leader!];
      trace.update();
      meeting.stop();
      await meeting.enroll(plan: planJson(join: 2000, destination: 3000));
      trace.drive(300, y: 61, elapsed: 6000, speed: 50);
      meeting.drive(300, y: 61, elapsed: 6000, speed: 50);
      trace.calls.single.succeed();
      meeting.routes.single.succeed();
      await flush();
      expect(trace.state.condition, FollowRouteCondition.routeMismatch);
      expect(
        meeting.controller.view!.condition,
        FollowRouteCondition.routeMismatch,
      );
      trace.drive(301, y: 60, speed: 1.5);
      meeting.drive(301, y: 60, speed: 1.5);
      trace.drive(302, y: 59, speed: 1.5);
      meeting.drive(302, y: 59, speed: 1.5);
      expect(trace.state.connector, isNotEmpty);
      expect(meeting.controller.view!.connector, isNotEmpty);
      expect(trace.joins, isEmpty);
      expect(trace.departures, isEmpty);
      expect(
        meeting.calls.where((c) => c.path.endsWith('/pass-evidence')),
        isEmpty,
      );
    },
  );

  for (final destination in [false, true]) {
    test(
      'R14.2 recovered ${destination ? 'D' : 'J'} uses only its own progress',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll(
          plan: planJson(
            join: 200,
            destination: destination ? 200 : 1000,
            policy: 'proceed',
          ),
        );
        f.routes.single.succeed();
        await flush();
        for (var x = 20.0; x <= 100; x += 20) f.drive(x, speed: 20);
        f.drive(100, elapsed: 24000, speed: 0);
        for (var n = 0; n < 6; n++) {
          f.drive(100 + n * 3, y: 80, elapsed: n == 0 ? 2000 : 1000, speed: 40);
        }
        expect(f.routes, hasLength(2));
        // The discarded 200 m road still lies beneath these fixes while the
        // replacement (only about 117 m long) is being calculated.
        f.drive(130, y: 40, speed: 45);
        f.drive(150, speed: 45);
        f.routes.last.succeed();
        await flush();
        expect(f.controller.view!.connector, isNotEmpty);
        for (var x = 170.0; x <= 230; x += 20) f.drive(x, speed: 20);
        final passes = f.calls.where((c) => c.path.endsWith('/pass-evidence'));
        expect(passes, hasLength(1));
        expect(
          passes.single.body!['pointKind'],
          destination ? 'destination' : 'joinPoint',
        );
        expect(f.routes, hasLength(2));
      },
    );
  }

  for (final gap in [false, true]) {
    test(
      'R14.3 confirmed departure survives ${gap ? 'a sample gap' : 'a stop'}',
      () async {
        final f = RouteFixture();
        addTearDown(f.dispose);
        await f.join();
        f.grow(2000);
        f.depart();
        expect(f.state.condition, FollowRouteCondition.offRoute);
        if (gap) {
          f.drive(48, y: 80, elapsed: 30000, speed: 0);
        } else {
          for (var n = 0; n < 30; n++) f.drive(48, y: 80, speed: 0);
        }
        expect(f.state.condition, FollowRouteCondition.offRoute);
        expect(f.state.marker, isNull);
        expect(f.state.connector, isEmpty);
        expect(
          f.calls,
          hasLength(1),
          reason: 'stopping cannot trigger recovery',
        );
        f.drive(51, y: 80, speed: 3);
        expect(
          f.calls,
          hasLength(2),
          reason: 'departure was already confirmed',
        );
        expect(f.departures, hasLength(1));
      },
    );

    test(
      'R14.3 fixed departure survives ${gap ? 'a sample gap' : 'a stop'}',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll(plan: planJson(join: 2000, destination: 3000));
        f.routes.single.succeed();
        await flush();
        for (var n = 0; n < 7; n++) f.drive(10 + n * 3, y: 80, speed: 3);
        expect(f.controller.view!.condition, FollowRouteCondition.offRoute);
        if (gap) {
          f.drive(28, y: 80, elapsed: 30000, speed: 0);
        } else {
          for (var n = 0; n < 30; n++) f.drive(28, y: 80, speed: 0);
        }
        expect(f.controller.view!.condition, FollowRouteCondition.offRoute);
        expect(f.controller.view!.connector, isEmpty);
        expect(f.routes, hasLength(1));
        for (var n = 1; n <= 6; n++) f.drive(28 + n * 3, y: 80, speed: 3);
        expect(f.routes, hasLength(2));
      },
    );
  }

  test('R14.4 a normal U-turn starting 20 m from J remains usable', () async {
    final f = MeetingFixture(
      account: 'leader',
      target: null,
      relationship: null,
    );
    addTearDown(f.dispose);
    f.stop();
    f.controller.applyPlan(
      snapshot(
        plan: planJson(join: 20, destination: 2000, policy: 'proceed'),
        runtime: runtimeJson(follower: 'follower'),
      ),
    );
    await f.controller.selectOwnGuidance();
    f.routes.single.succeed(
      points: [
        testPoint(0),
        testPoint(-600),
        testPoint(-600, 5),
        testPoint(20, 5),
      ],
    );
    await flush();
    expect(f.controller.view!.condition, FollowRouteCondition.ready);
    expect(f.controller.status, '합류 지점으로 이동');
    expect(f.controller.view!.connector, isNotEmpty);
    expect(f.routes, hasLength(1));
    expect(f.calls.where((c) => c.path.endsWith('/pass-evidence')), isEmpty);
  });

  for (final trailing in [false, true]) {
    test(
      'R14.6 endpoint window includes a ${trailing ? 'trailing' : 'leading'} sub-centimetre segment',
      () {
        final points = trailing
            ? [testPoint(0), testPoint(100), testPoint(100.005)]
            : [testPoint(0), testPoint(.005), testPoint(100)];
        // _primePlanTrace uses this total as the retained connector's floor.
        final progress = routeLength(points);
        final projection = projectRoute(points.last, points, minimum: progress);
        expect(projection, isNotNull);
        expect(projection!.along, closeTo(progress, .000001));
        expect(projection.distance, lessThan(.01));
      },
    );
  }

  test(
    'R14.6 a tiny segment cannot move the existing 25 m anchor boundary',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(100);
      f.trace = [f.leader!];
      f.update();
      f.calls.single.succeed(
        points: [testPoint(0), testPoint(.005), testPoint(100)],
      );
      await flush();
      f.trace = [for (var n = 0; n <= 20; n++) testFix(100 + n * 10, seq: n)];
      f.leader = f.trace.last;
      f.update();
      f.drive(75, elapsed: 2000, speed: 37.5);
      expect(f.state.anchorReached, isTrue);
      expect(f.joins, isEmpty, reason: 'one sample cannot prove a join');
      expect(f.calls, hasLength(1));
    },
  );
}
