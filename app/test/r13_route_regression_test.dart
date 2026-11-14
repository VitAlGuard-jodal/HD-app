import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/meeting_plan.dart';

import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

void main() {
  test(
    'A1 invalid jump does not advance connector progress while resuming gaps',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(100);
      f.trace = [f.leader!];
      await f.start();
      f.drive(10, speed: 10);
      f.drive(100, speed: 90); // 90 m in 1 s exceeds 70 m/s + 2 + 2 m accuracy.
      expect(f.state.routeProgress, closeTo(10, .01));
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
    },
  );

  test(
    'A7 grey rejoin result uses elapsed reachability through a ramp',
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
      f.drive(x + 150, y: y, elapsed: 2200, speed: 68);
      f.drive(x + 150, y: y + 150, elapsed: 2200, speed: 68);
      f.drive(x, y: y + 150, elapsed: 2200, speed: 68);
      f.drive(x, y: y + 100, elapsed: 1000, speed: 50);
      call.succeed(
        points: [
          call.origin,
          testPoint(x + 150, y),
          testPoint(x + 150, y + 150),
          testPoint(x, y + 150),
          testPoint(x, y + 100),
          call.anchor,
        ],
      );
      await flush();
      expect(f.state.connector, isNotEmpty);
      expect(f.state.routeProgress, closeTo(500, .01));
      expect(f.state.rejoining, isTrue);
      expect(f.calls, hasLength(2));
      expect(f.joins, hasLength(1));
    },
  );

  test(
    'A6 failed recovery keeps the three-per-five-minute limit and reset hold',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(plan: planJson(join: 2000, destination: 3000));
      f.routes.single.succeed();
      await flush();
      var x = 10.0;
      for (var attempt = 0; attempt < 3; attempt++) {
        for (var n = 0; n < 35; n++) {
          f.drive(x, y: 80, speed: 3);
          x += 3;
        }
        expect(f.routes, hasLength(attempt + 2));
        f.routes.last.pending.completeError(
          const FollowRouteException('NO_ROUTE'),
        );
        await flush();
      }
      for (var n = 0; n < 330; n++) {
        f.drive(x, y: 80, speed: 3);
        x += 3;
      }
      expect(f.routes, hasLength(4));
      expect(f.controller.view!.condition, FollowRouteCondition.resetRequired);
    },
  );

  test(
    'R3 a long detour without an opposite early J visit remains usable',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      f.stop();
      f.controller.applyPlan(
        snapshot(
          plan: planJson(join: 300, destination: 2000, policy: 'proceed'),
          runtime: runtimeJson(follower: 'follower'),
        ),
      );
      await f.controller.selectOwnGuidance();
      f.routes.single.succeed(
        points: [
          testPoint(0),
          testPoint(0, 100),
          testPoint(600, 100),
          testPoint(600, 5),
          testPoint(300, 5),
        ],
      );
      await flush();
      expect(f.controller.status, '합류 지점으로 이동');
      expect(f.controller.view!.connector, isNotEmpty);
    },
  );

  test(
    'A1 trace tracking also resumes after a tunnel without a new join',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.grow(2000);
      f.drive(518, elapsed: 30000, speed: 20);
      for (var n = 1; n <= 4; n++) f.drive(518 + n * 20, speed: 20);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.departures, isEmpty);
      expect(f.joins, hasLength(1));
      expect(TracePath(f.trace).resolve(f.state.progress!), closeTo(598, .01));
    },
  );

  test(
    'R3 manual J with an opposite-direction return warns before guidance',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      f.stop();
      f.controller.applyPlan(
        snapshot(
          plan: planJson(join: 300, destination: 2000, policy: 'proceed'),
          runtime: runtimeJson(follower: 'follower'),
        ),
      );
      await f.controller.selectOwnGuidance();
      f.routes.single.succeed(
        points: [
          testPoint(0),
          testPoint(600),
          testPoint(600, 100),
          testPoint(350, 100),
          testPoint(350, 5),
          testPoint(300, 5),
        ],
      );
      await flush();
      expect(f.controller.status, contains('진행 방향 도로'));
      expect(f.controller.view!.condition, FollowRouteCondition.resetRequired);
      expect(f.controller.view!.connector, isEmpty);
      for (var x = 20.0; x <= 2000; x += 20) f.drive(x, speed: 20);
      expect(
        f.calls.where((c) => c.path.endsWith('/pass-evidence')),
        isEmpty,
        reason:
            'R3(b): proximity and the straight bearing to D do not prove the access road',
      );
      expect(f.controller.ownRuntime!.phase, 'toJoin');
      expect(f.routes, hasLength(1));
      expect(f.controller.status, contains('진행 방향 도로'));
    },
  );

  test('R2 meeting trace priming never uses the mode A approach message', () {
    final guidance = FollowGuidance('plan-1', 'follow-1')
      ..mode = FollowMode.meetingPoint
      ..condition = FollowRouteCondition.ready;
    expect(guidance.view.status, '앞차 이동 경로 확인 중');
    guidance.phase = FollowPhase.onTrace;
    expect(guidance.view.status, '앞차가 지나간 경로를 따라갑니다');
    guidance.phase = FollowPhase.approaching;
    guidance.rejoining = true;
    expect(guidance.view.status, '회색 경로를 따라 다시 합류');
    guidance.rejoining = false;
    guidance.mode = FollowMode.a;
    expect(guidance.view.status, '추천 경로로 기준 지점까지 이동');
  });

  test('A10 geometry does not depend directly on Flutter logging', () {
    final geometry = File(
      'lib/location/follow_route_geometry.dart',
    ).readAsStringSync();
    expect(geometry, isNot(contains('package:flutter/')));
    expect(geometry, isNot(contains('debugPrint')));
  });

  test(
    'A9 shared judgement resumes J progress after a gap without inventing passage',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(
        plan: planJson(join: 1000, destination: 2000, policy: 'proceed'),
      );
      f.routes.single.succeed();
      await flush();
      f.drive(500, elapsed: 30000, speed: 20);
      final passes = f.calls.where((c) => c.path.endsWith('/pass-evidence'));
      expect(passes, isEmpty);
      for (var x = 520.0; x <= 1020; x += 20) f.drive(x, speed: 20);
      expect(passes, hasLength(1));
      expect(f.routes, hasLength(1));
    },
  );

  test(
    'A8 temporary mismatch hides the old marker without demanding reset',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(1000);
      f.trace = [f.leader!];
      f.update();
      f.drive(0, y: 100, elapsed: 2000, speed: 0);
      f.calls.single.succeed();
      await flush();
      expect(f.state.condition, FollowRouteCondition.routeMismatch);
      expect(f.state.marker, isNull);
      expect(f.state.status, isNot(contains('다시 설정')));
      f.drive(0, speed: 0);
      f.drive(0, speed: 0);
      expect(f.state.connector, isNotEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test('A8 fixed-route mismatch is also a temporary hold', () async {
    final f = MeetingFixture();
    addTearDown(f.dispose);
    f.stop();
    await f.enroll();
    f.drive(0, y: 100, elapsed: 2000, speed: 0);
    f.routes.single.succeed();
    await flush();
    expect(f.controller.view!.condition, FollowRouteCondition.routeMismatch);
    expect(f.controller.status, isNot(contains('다시 설정')));
    f.drive(0, speed: 0);
    expect(f.controller.view!.connector, isNotEmpty);
  });

  test(
    'A7 initial result accepts a driven ramp longer than displacement',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(1000, y: 100);
      f.trace = [f.leader!];
      f.update();
      f.drive(150, elapsed: 2200, speed: 68);
      f.drive(150, y: 150, elapsed: 2200, speed: 68);
      f.drive(0, y: 150, elapsed: 2200, speed: 68);
      f.drive(0, y: 100, elapsed: 1000, speed: 50);
      f.calls.single.succeed(
        points: [
          testPoint(0),
          testPoint(150),
          testPoint(150, 150),
          testPoint(0, 150),
          testPoint(0, 100),
          testPoint(1000, 100),
        ],
      );
      await flush();
      expect(f.state.connector, isNotEmpty);
      expect(f.state.routeProgress, closeTo(500, .01));
      expect(f.departures, isEmpty);
    },
  );

  for (final destination in [false, true]) {
    test(
      'A7 ${destination ? 'D' : 'J'} result accepts a driven ramp',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll(
          plan: planJson(join: 1000, destination: destination ? 1000 : 2000),
        );
        f.drive(150, elapsed: 2200, speed: 68);
        f.drive(150, y: 150, elapsed: 2200, speed: 68);
        f.drive(0, y: 150, elapsed: 2200, speed: 68);
        f.drive(0, y: 100, elapsed: 1000, speed: 50);
        f.routes.single.succeed(
          points: [
            testPoint(0),
            testPoint(150),
            testPoint(150, 150),
            testPoint(0, 150),
            testPoint(0, 100),
            testPoint(1000),
          ],
        );
        await flush();
        expect(f.controller.view!.connector, isNotEmpty);
        expect(f.controller.view!.condition, FollowRouteCondition.ready);
      },
    );
  }

  for (final destination in [false, true]) {
    test(
      'A6 ${destination ? 'D' : 'J'} recovery continues after NO_ROUTE with a new input',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll(
          plan: planJson(join: 2000, destination: destination ? 2000 : 3000),
        );
        f.routes.single.succeed();
        await flush();
        for (var n = 0; n < 35; n++) f.drive(10 + n * 3, y: 80, speed: 3);
        expect(f.routes, hasLength(2));
        final failed = f.routes.last.request;
        f.routes.last.pending.completeError(
          const FollowRouteException('NO_ROUTE'),
        );
        await flush();
        for (var n = 0; n < 35; n++) f.drive(115 + n * 3, y: 80, speed: 3);
        expect(f.routes, hasLength(3));
        expect(f.routes.last.request.routeKind, failed.routeKind);
        expect(
          f.routes.last.request.calculationId,
          isNot(failed.calculationId),
        );
        expect(f.routes.last.request.originRef, isNot(failed.originRef));
        expect(f.controller.view!.connector, isEmpty);
      },
    );
  }

  test(
    'A5 stopping in cooldown cannot restore a departed J approach',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(plan: planJson(join: 2000, destination: 3000));
      f.routes.single.succeed();
      await flush();
      for (var n = 0; n < 7; n++) f.drive(10 + n * 3, y: 80, speed: 3);
      expect(f.controller.view!.connector, isEmpty);
      for (var n = 0; n < 3; n++) f.drive(28, y: 40, speed: 0);
      expect(f.controller.view!.connector, isEmpty);
      expect(f.controller.status, isNot(contains('벗어났습니다')));
      expect(f.routes, hasLength(1));
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(runtimeRevision: 2, followerPhase: 'atJoinWaiting'),
        ),
      );
      expect(f.controller.approachRoute, isNull);
    },
  );

  test(
    'A4 stopping near a departed connector does not accept it again',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(2000);
      f.trace = [f.leader!];
      await f.start();
      for (var n = 0; n < 7; n++) f.drive(10 + n * 3, y: 80, speed: 3);
      expect(f.departures, hasLength(1));
      expect(f.state.route, isNull);
      for (var n = 0; n < 3; n++) f.drive(28, y: 40, speed: 0);
      expect(f.state.route, isNull);
      expect(f.state.connector, isEmpty);
      expect(f.state.status, isNot(contains('벗어났습니다')));
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'A1 tunnel gap does not turn a later on-route fix into a departure',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(2000);
      f.trace = [f.leader!];
      await f.start();
      f.drive(10, speed: 10);
      f.drive(510, elapsed: 30000, speed: 20);
      for (var n = 1; n <= 8; n++) f.drive(510 + n * 20, speed: 20);
      expect(f.departures, isEmpty);
      expect(f.state.rejoining, isFalse);
      expect(f.state.connector, isNotEmpty);
      expect(f.calls, hasLength(1));
      expect(f.joins, isEmpty);
      expect(f.state.routeProgress, closeTo(670, .01));
    },
  );

  for (final offset in [0.0, 40.0]) {
    test('A2 progress follows slow or offset travel ($offset m)', () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(2000);
      f.trace = [f.leader!];
      await f.start();
      for (var n = 1; n <= 120; n++) {
        f.drive(n * 1.5, y: offset, speed: offset == 0 ? 1.5 : 3);
      }
      expect(f.state.routeProgress, closeTo(180, .01));
      for (var n = 1; n <= 8; n++) f.drive(180 + n * 10, y: offset, speed: 10);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
      expect(f.joins, isEmpty);
    });
  }

  for (final destination in [false, true]) {
    for (final offset in [0.0, 40.0]) {
      test(
        'A3 ${destination ? 'D' : 'J'} stays usable after slow/offset progress $offset',
        () async {
          final f = MeetingFixture();
          addTearDown(f.dispose);
          f.stop();
          await f.enroll(
            plan: planJson(join: 2000, destination: destination ? 2000 : 3000),
          );
          f.routes.single.succeed();
          await flush();
          for (var n = 1; n <= 120; n++)
            f.drive(n * 1.5, y: offset, speed: offset == 0 ? 1.5 : 3);
          for (var n = 1; n <= 8; n++)
            f.drive(180 + n * 10, y: offset, speed: 10);
          expect(f.controller.view!.connector, isNotEmpty);
          expect(f.controller.view!.rejoining, isFalse);
          expect(f.routes, hasLength(1));
          expect(
            f.calls.where((c) => c.path.endsWith('/pass-evidence')),
            isEmpty,
          );
        },
      );
    }
  }
}
