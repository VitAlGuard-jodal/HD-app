import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/models.dart';

import 'support/follow_route_fakes.dart';

void main() {
  test(
    'r12 connector progress stays on the later visit after a full loop',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      f.calls.single.succeed(
        points: [
          testPoint(-50),
          testPoint(150),
          testPoint(150, 100),
          testPoint(-50, 100),
          testPoint(-50, 4),
          testPoint(0),
        ],
      );
      await flush();
      f.grow(500);
      for (var x = -30.0; x <= 150; x += 20) f.drive(x, speed: 20);
      expect(f.joins, isEmpty);
      for (var y = 20.0; y <= 100; y += 20) f.drive(150, y: y, speed: 20);
      for (var x = 130.0; x >= -50; x -= 20) f.drive(x, y: 100, speed: 20);
      for (var y = 80.0; y >= 20; y -= 20) f.drive(-50, y: y, speed: 20);
      f.drive(-50, y: 4, speed: 20);
      expect(f.state.routeProgress, greaterThan(590));
      expect(f.joins, isEmpty);
      f.drive(-30, y: 2.4, speed: 20);
      expect(f.state.routeProgress, greaterThan(610));
      f.drive(-10, y: .8, speed: 20);
      expect(f.state.routeProgress, greaterThan(630));
      for (final x in [0.0, 6.0, 12.0, 18.0]) f.drive(x, speed: 6);
      expect(f.joins, hasLength(1));
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'r12 ambiguous initial route explains why a parked car must wait',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      f.calls.single.succeed(
        points: [testPoint(-50), testPoint(0), testPoint(-50, 4), testPoint(0)],
      );
      await flush();
      expect(f.state.connector, isEmpty);
      expect(f.state.status, contains('경로가 겹쳐'));
      for (var n = 0; n < 35; n++) f.drive(-50, speed: 0);
      expect(f.state.status, contains('경로가 겹쳐'));
      expect(f.calls, hasLength(1));
      expect(f.joins, isEmpty);
      expect(f.departures, isEmpty);
      f.drive(-30, speed: 20);
      f.drive(-10, speed: 20);
      expect(f.state.connector, isNotEmpty);
      expect(f.state.status, isNot(contains('경로가 겹쳐')));
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'r12 initial route keeps the first visit while parked at its origin',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      final points = [
        testPoint(-50),
        testPoint(150),
        testPoint(-50, 4),
        testPoint(0),
      ];
      f.calls.single.succeed(points: points);
      await flush();
      expect(f.state.connector, points);
      expect(f.state.routeProgress, closeTo(0, .01));
      for (var n = 0; n < 6; n++) f.drive(-50, speed: 0);
      expect(f.state.connector, points);
      expect(f.state.routeProgress, closeTo(0, .01));
      expect(f.joins, isEmpty);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test('r8 parked leader then 160 m approach joins within 3 s of P0', () async {
    final f = RouteFixture();
    addTearDown(f.dispose);
    f.self = testFix(0, handle: 'self', speed: 0);
    f.leader = testFix(160, speed: 0, acc: null, src: 'vehicle');
    f.trace = [f.leader!];
    await f.start();
    final anchor = f.state.anchor;
    var leaderSeq = 0;
    // A minute of 5 s stationary heartbeats after accepting the request.
    for (var second = 5; second <= 65; second += 5) {
      f.leader = testFix(
        160,
        seq: ++leaderSeq,
        at: routeEpoch + second * 1000,
        speed: 0,
        acc: null,
        src: 'vehicle',
      );
      f.trace = [...f.trace, f.leader!];
      f.drive(0, elapsed: 5000, speed: 0);
    }
    for (var second = 1; second <= 18; second++) {
      f.leader = testFix(
        160 + second * 13.9,
        seq: ++leaderSeq,
        at: routeEpoch + (65 + second) * 1000,
        speed: 13.9,
        acc: null,
        src: 'vehicle',
      );
      f.trace = [...f.trace, f.leader!];
      f.drive(
        second <= 3 ? 0 : (second - 3) * 13.9,
        speed: second <= 3 ? 0 : 13.9,
      );
    }
    expect(f.state.anchor, anchor);
    expect(f.state.phase, FollowPhase.onTrace);
    expect(f.joins, [('follow-1', 1)]);
    expect(f.calls, hasLength(1));
  });

  test('vehicle fixes without metre accuracy start A and join once', () async {
    final f = RouteFixture(mapFix: vehicleFix);
    addTearDown(f.dispose);
    f.update();
    expect(f.calls, hasLength(1));
    expect(f.calls.single.request.mode, FollowRouteKind.initial);
    f.calls.single.succeed();
    await flush();
    expect(f.state.connector, isNotEmpty);
    f.grow();
    f.drive(-20);
    f.drive(0);
    f.drive(6);
    f.update(); // Duplicate delivery adds no join evidence.
    expect(f.state.phase, FollowPhase.approaching);
    expect(f.joins, isEmpty);
    f.drive(12);
    f.drive(18);
    expect(f.state.phase, FollowPhase.onTrace);
    expect(f.state.connector, isEmpty);
    expect(f.joins, [('follow-1', 1)]);
    f.update();
    expect(f.joins, hasLength(1));
  });

  test(
    'vehicle fixes support automatic B rejoining with the same cooldown',
    () async {
      final f = RouteFixture(mapFix: vehicleFix);
      addTearDown(f.dispose);
      await f.join();
      f.grow(500);
      f.depart();
      expect(f.calls, hasLength(1));
      f.driveUntil(30000);
      expect(f.calls, hasLength(2));
      expect(f.calls.last.request.mode, FollowRouteKind.rejoin);
      f.calls.last.succeed();
      await flush();
      final x = f.state.anchorPoint!.lng * metersPerDegree;
      f.drive(x - 20, y: 15, elapsed: 2000);
      f.drive(x);
      f.drive(x + 6);
      f.drive(x + 12);
      f.drive(x + 18);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.state.mode, FollowMode.a);
      expect(f.state.connector, isEmpty);
      expect(f.joins, [('follow-1', 1), ('follow-1', 2)]);
    },
  );

  test(
    'vehicle stationary, reverse, jump and stale samples cannot merge',
    () async {
      final f = RouteFixture(mapFix: vehicleFix);
      addTearDown(f.dispose);
      await f.start();
      f.grow();
      f.drive(-20);
      for (var i = 0; i < 5; i++) f.drive(0, speed: 0);
      expect(f.joins, isEmpty);
      f.drive(-6);
      f.drive(-12);
      f.drive(-18);
      expect(f.joins, isEmpty);
      f.drive(500);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
      f.selfAge = 10001;
      f.update();
      expect(f.state.condition, FollowRouteCondition.locationDelayed);
      expect(f.joins, isEmpty);
    },
  );

  for (final leader in [false, true]) {
    test(
      'missing phone accuracy still holds ${leader ? 'leader' : 'self'}',
      () {
        final f = RouteFixture(mapFix: vehicleFix);
        addTearDown(f.dispose);
        if (leader) {
          f.leader = testFix(0, acc: null);
        } else {
          f.self = testFix(-50, handle: 'self', acc: null);
        }
        f.update();
        expect(f.state.condition, FollowRouteCondition.poorAccuracy);
        expect(f.calls, isEmpty);
      },
    );
  }

  test(
    'C5 approach accepts the connector; onTrace no longer accepts the old connector',
    () async {
      final approaching = RouteFixture();
      addTearDown(approaching.dispose);
      approaching.self = testFix(-200, handle: 'self');
      await approaching.start();
      approaching.grow();
      approaching.drive(-150, elapsed: 2000);
      approaching.drive(-140, elapsed: 3000);
      approaching.drive(-130, elapsed: 2000);
      expect(approaching.state.phase, FollowPhase.approaching);
      expect(approaching.state.condition, isNot(FollowRouteCondition.offRoute));
      final joined = RouteFixture();
      addTearDown(joined.dispose);
      await joined.join();
      joined.drive(18);
      joined.drive(-70, elapsed: 2000);
      joined.drive(-80, elapsed: 3000);
      joined.drive(-90, elapsed: 2000);
      expect(joined.state.condition, FollowRouteCondition.offRoute);
      expect(joined.calls, hasLength(1));
    },
  );

  test('C6 exactly sixty metres is not a sustained departure', () async {
    final f = RouteFixture();
    addTearDown(f.dispose);
    await f.join();
    f.drive(30, y: 60, elapsed: 2000);
    f.drive(40, y: 60, elapsed: 3000);
    f.drive(50, y: 60, elapsed: 2000);
    f.time = 30000;
    f.update();
    expect(f.calls, hasLength(1));
    expect(f.state.condition, isNot(FollowRouteCondition.offRoute));
  });
  test(
    'unusable initial response waits for sustained moving departure before rejoin',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      f.grow(500);
      f.drive(-50, y: 100, elapsed: 2000);
      f.calls.single.succeed();
      await flush();
      expect(f.state.connector, isEmpty);
      expect(f.departures, isEmpty);
      f.depart(y: 100);
      f.driveUntil(30000, y: 100);
      expect(f.calls, hasLength(2));
      expect(f.calls.last.request.mode, FollowRouteKind.rejoin);
    },
  );
  test(
    'G2 spatial progress with less than two seconds is insufficient',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.start();
      f.grow();
      f.drive(-20);
      f.drive(0, elapsed: 500);
      f.drive(6, elapsed: 500);
      f.drive(12, elapsed: 500);
      expect(f.joins, isEmpty);
      f.drive(18, elapsed: 1000);
      expect(f.joins, hasLength(1));
    },
  );
  test(
    'D3 disabled/provider mismatch blocks requests while keeping independent trace data',
    () {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.routingEnabled = false;
      f.grow();
      expect(f.calls, isEmpty);
      expect(f.state.condition, FollowRouteCondition.disabled);
      expect(f.state.activeTrace, isNotEmpty);
      expect(f.calls, isEmpty);
      f.routingEnabled = true;
      f.update();
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'C7 missing required progress becomes broken instead of restarting at first retained point',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      final progress = f.state.progress;
      f.trace = f.trace.skip(10).toList();
      f.update();
      expect(f.state.condition, FollowRouteCondition.traceBroken);
      expect(f.state.progress, progress);
      expect(f.calls, hasLength(1));
      f.time = 30000;
      f.update();
      expect(f.calls, hasLength(1));
      expect(f.state.progress, progress);
    },
  );

  test(
    'automatic rejoin keeps follow mode and emits the next round once',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.depart();
      f.driveUntil(30000);
      final call = f.calls.last;
      call.succeed();
      await flush();
      final anchor = f.state.anchorPoint!;
      final x = anchor.lng * metersPerDegree;
      f.drive(x - 20, y: 15, elapsed: 2000);
      f.drive(x, elapsed: 1000);
      f.drive(x + 6);
      f.drive(x + 12);
      f.drive(x + 18);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.state.mode, FollowMode.a);
      expect(f.joins, [('follow-1', 1), ('follow-1', 2)]);
      f.update();
      expect(f.joins, hasLength(2));
    },
  );

  test(
    'LOCATION_NOT_READY waits for a new measurement, not timer retry',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      f.calls.single.fail('LOCATION_NOT_READY');
      await flush();
      f.update();
      f.time = 30000;
      f.update();
      expect(f.calls, hasLength(1));
      f.drive(-40);
      expect(f.calls, hasLength(2));
    },
  );
  test(
    'C1 each follower freezes its own latest P0, never the shared first point',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.grow(80);
      final request = f.calls.single.request;
      expect(request.anchor, RouteAnchor.sample(SampleRef.of(f.leader!)));
      expect(request.anchor.start.seq, 8);
      f.calls.single.succeed();
      await flush();
      f.drive(0);
      f.drive(6);
      f.drive(12);
      expect(f.joins, isEmpty);
      expect(f.state.phase, FollowPhase.approaching);
    },
  );
  test(
    'C2 consent and both locations wait, then duplicate acceptance computes once',
    () {
      final f = RouteFixture();
      addTearDown(f.dispose);
      final leader = f.leader;
      f.consent = false;
      f.update();
      expect(f.calls, isEmpty);
      f.consent = true;
      f.leader = null;
      f.update();
      expect(f.calls, isEmpty);
      f.leader = leader;
      f.update();
      f.update();
      f.update();
      expect(f.calls, hasLength(1));
    },
  );
  test(
    'C3 moving leader extends the trace without changing origin, P0 or successful route',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      final first = f.calls.single;
      f.grow();
      first.succeed();
      await flush();
      final route = f.state.route;
      final origin = f.state.originRef, anchor = f.state.anchor;
      f.grow(300);
      expect(f.calls, hasLength(1));
      expect(f.state.route, same(route));
      expect(f.state.originRef, origin);
      expect(f.state.anchor, anchor);
      expect(f.state.activeTrace.single.length, 31);
    },
  );
  test(
    'G2 three distinct fixes over two seconds and ten metres merge exactly once',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.state.connector, isEmpty);
      expect(f.state.marker, isNull);
      expect(f.joins, [('follow-1', 1)]);
      f.update();
      f.update();
      f.grow(300);
      expect(f.joins, hasLength(1));
    },
  );
  test(
    'G1/G3 atAnchor, repeated samples, stationary heartbeats and jitter do not merge',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self');
      f.update();
      f.calls.single.succeed(atAnchor: true);
      await flush();
      expect(f.state.condition, FollowRouteCondition.atAnchorWaitingTrace);
      for (var n = 0; n < 5; n++) {
        f.update();
        f.drive(n.isEven ? 1 : 0);
      }
      expect(f.joins, isEmpty);
      f.grow();
      for (var n = 0; n < 5; n++) {
        f.drive(0);
      }
      expect(f.joins, isEmpty);
    },
  );
  test(
    'G4 reverse motion and crossing trace away from P0 do not merge',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.start();
      f.grow();
      for (final x in [80.0, 70.0, 60.0, 50.0]) {
        f.drive(x, elapsed: 2000);
      }
      expect(f.joins, isEmpty);
      for (final y in [-40.0, 0.0, 40.0]) {
        f.drive(50, y: y);
      }
      expect(f.joins, isEmpty);
    },
  );
  test(
    'G7 poor accuracy and delayed location clear accumulated evidence, not the phase',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      final progress = f.state.progress;
      f.selfAge = 10001;
      f.update();
      expect(f.state.condition, FollowRouteCondition.locationDelayed);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.state.progress, progress);
      f.selfAge = 0;
      f.drive(20, acc: null);
      expect(f.state.condition, FollowRouteCondition.poorAccuracy);
      f.drive(25);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.joins, hasLength(1));
    },
  );
  test(
    'reserved meeting-point mode cannot start a route or invalidate A',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      final initial = f.calls.single;
      final generation = f.state.generation;
      expect(f.controller.changeMode(FollowMode.meetingPoint), isFalse);
      expect(f.controller.changeMode(FollowMode.a), isFalse);
      expect(f.state.generation, generation);
      expect(f.calls, hasLength(1));
      expect(initial.cancellation.isCancelled, isFalse);
      initial.succeed();
      await flush();
      expect(f.state.route, isNotNull);
    },
  );
  test(
    'C4 onTrace mode changes preserve progress and never compute or announce again',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      final progress = f.state.progress;
      expect(f.controller.changeMode(FollowMode.meetingPoint), isFalse);
      f.controller.changeMode(FollowMode.a);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.state.progress, progress);
      expect(f.calls, hasLength(1));
      expect(f.joins, hasLength(1));
    },
  );
  test('C4 driving restriction is enforced by controller methods', () {
    final f = RouteFixture();
    addTearDown(f.dispose);
    f.update();
    f.locked = true;
    expect(f.controller.changeMode(FollowMode.meetingPoint), isFalse);
    expect(f.controller.reset(), isFalse);
    expect(f.state.mode, FollowMode.a);
    expect(f.calls, hasLength(1));
  });
  test(
    'sustained departure automatically rejoins after at least thirty seconds',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.depart();
      expect(f.state.condition, FollowRouteCondition.offRoute);
      expect(f.calls, hasLength(1));
      expect(f.departures, [('follow-1', 1)]);
      f.driveUntil(29000);
      expect(f.calls, hasLength(1));
      f.driveUntil(30000);
      expect(f.calls, hasLength(2));
      expect(f.state.phase, FollowPhase.approaching);
      expect(f.state.progress, isNotNull);
      expect(f.calls.last.request.toJson()['mode'], 'B');
      expect(f.calls.last.request.anchor.end, isNotNull);
      expect(f.state.mode, FollowMode.a);
    },
  );
  test(
    'C6 a one-second excursion and normal return reset departure evidence',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.drive(20, y: 61, elapsed: 2000);
      f.drive(30, elapsed: 2000);
      f.time = 31000;
      f.update();
      expect(f.calls, hasLength(1));
      expect(f.state.condition, FollowRouteCondition.ready);
    },
  );
  test(
    'response projects current progress but a different road hides the line until judged',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      f.drive(-25);
      f.calls.single.succeed();
      await flush();
      expect(f.state.routeProgress, closeTo(25, .01));
      f.controller.reset();
      final next = f.calls.last;
      f.drive(-25, y: 100, elapsed: 2000);
      next.succeed();
      await flush();
      expect(f.state.condition, FollowRouteCondition.routeMismatch);
      expect(f.state.connector, isEmpty);
    },
  );
  test(
    'road failure tries one distinct forward candidate after thirty seconds',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.grow(500);
      f.depart();
      f.driveUntil(30000);
      final first = f.calls.last;
      first.fail('NO_ROUTE');
      await flush();
      f.driveUntil(59000);
      expect(f.calls, hasLength(2));
      f.driveUntil(60000);
      expect(f.calls, hasLength(3));
      expect(f.calls.last.request.anchor, isNot(first.request.anchor));
      f.calls.last.fail('ENDPOINT_MISMATCH');
      await flush();
      f.driveUntil(95000);
      expect(f.calls, hasLength(3));
      expect(f.state.condition, FollowRouteCondition.noRoute);
    },
  );
  test('candidate at trace end is not retried as a second candidate', () async {
    final f = RouteFixture();
    addTearDown(f.dispose);
    await f.join();
    f.grow(140);
    f.depart();
    f.driveUntil(30000);
    expect(f.calls, hasLength(2));
    expect(f.state.anchor!.end, SampleRef.of(f.leader!));
    expect(f.state.anchor!.fraction, 1);
    f.calls.last.fail('NO_ROUTE');
    await flush();
    f.driveUntil(95000);
    expect(f.calls, hasLength(2));
    expect(f.state.condition, FollowRouteCondition.noRoute);
  });
  test(
    'retry budget is two, input stays frozen while self and leader move',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      final initial = f.calls.single.request;
      for (var n = 0; n < 3; n++) {
        f.calls.last.fail('ROUTE_TIMEOUT', retryable: true);
        await flush();
        f.time += 30000;
        f.grow();
        f.update();
      }
      expect(f.calls, hasLength(3));
      expect(f.calls.map((c) => c.request.calculationId).toSet(), {
        initial.calculationId,
      });
      expect(f.calls.map((c) => c.request.requestId).toSet(), hasLength(3));
      expect(
        f.calls.every(
          (c) =>
              c.request.anchor == initial.anchor &&
              c.request.originRef == initial.originRef,
        ),
        isTrue,
      );
      expect(f.state.condition, FollowRouteCondition.noRoute);
    },
  );
  test(
    'RATE_LIMITED pinned input is retried without consuming transient retry budget',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      final first = f.calls.single.request;
      f.calls.last.fail(
        'RATE_LIMITED',
        delay: 30000,
        accepted: true,
        expires: routeEpoch + 120000,
      );
      await flush();
      f.time = 29999;
      f.update();
      expect(f.calls, hasLength(1));
      f.time++;
      f.update();
      expect(f.calls, hasLength(2));
      expect(f.calls.last.request.originRef, first.originRef);
      expect(f.calls.last.request.calculationId, first.calculationId);
    },
  );
  test(
    'rate limit beyond pin expiry requires reset instead of silently replacing P0',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      f.calls.single.fail(
        'RATE_LIMITED',
        delay: 30000,
        accepted: true,
        expires: routeEpoch + 20000,
      );
      await flush();
      f.time = 40000;
      f.grow();
      expect(f.calls, hasLength(1));
      expect(f.state.condition, FollowRouteCondition.resetRequired);
    },
  );
  for (final code in [
    'ROUTING_DISABLED',
    'PROVIDER_AUTH_FAILED',
    'INVALID_PROVIDER_RESPONSE',
    'ROUTE_TOO_LARGE',
    'INVALID_REQUEST',
    'REQUEST_TOO_LARGE',
    'CONSENT_REQUIRED_TARGET',
    'CONSENT_REQUIRED_SELF',
    'UNAUTHENTICATED',
    'NOT_ROOM_MEMBER',
    'NOT_ACTIVE_SENDER',
    'FOLLOW_NOT_ACTIVE',
    'CONTEXT_MISMATCH',
    'REFERENCE_EXPIRED',
  ]) {
    test(
      'error $code never retries just because a fresh fix arrives',
      () async {
        final f = RouteFixture();
        addTearDown(f.dispose);
        f.update();
        f.calls.single.fail(code, retryable: true);
        await flush();
        f.time = 31000;
        f.drive(-40);
        f.grow();
        expect(f.calls, hasLength(1));
        expect(f.state.connector, isEmpty);
      },
    );
  }
  for (final success in [true, false]) {
    for (final change in [
      'stop',
      'room',
      'account',
      'device',
      'relationship',
      'consent',
    ]) {
      test(
        'L1/L2 late ${success ? 'success' : 'failure'} after $change cannot restore guidance',
        () async {
          final f = RouteFixture();
          addTearDown(f.dispose);
          f.update();
          final old = f.calls.single;
          switch (change) {
            case 'stop':
              f.controller.update(null);
            case 'room':
              f.room = 'OTHER';
              f.update();
            case 'account':
              f.account = 'other';
              f.update();
            case 'device':
              f.device = 'replacement';
              f.update();
            case 'relationship':
              f.relationship = 'follow-2';
              f.update();
            case 'consent':
              f.consent = false;
              f.update();
          }
          final state = f.controller.state;
          if (success) {
            old.succeed();
          } else {
            old.fail('PROVIDER_AUTH_FAILED');
          }
          await flush();
          expect(f.controller.state, same(state));
          expect(f.controller.state?.route, isNull);
          expect(f.joins, isEmpty);
          expect(old.cancellation.isCancelled, isTrue);
        },
      );
    }
  }
  test(
    'L3 reconnect holds response until hello reconciles same relationship',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.update();
      final anchor = f.state.anchor;
      f.connected = false;
      f.update();
      f.calls.single.succeed();
      await flush();
      expect(f.state.route, isNull);
      f.connected = true;
      f.update();
      expect(f.state.route, isNotNull);
      expect(f.state.anchor, anchor);
      expect(f.calls, hasLength(1));
      f.controller.update(null);
      expect(f.controller.state, isNull);
    },
  );
  test(
    'L6 process context loss requires reset; ordinary update preserves P0',
    () {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.restored = true;
      f.update();
      expect(f.calls, isEmpty);
      expect(f.state.condition, FollowRouteCondition.resetRequired);
      f.controller.reset();
      expect(f.calls, hasLength(1));
      final p0 = f.state.anchor;
      f.grow();
      f.update();
      expect(f.state.anchor, p0);
    },
  );
}

LocationFix vehicleFix(LocationFix fix) => LocationFix.fromJson({
  ...fix.toJson()..remove('acc'),
  'handle': fix.handle,
  'receivedAt': fix.receivedAt,
  'src': 'vehicle',
});
