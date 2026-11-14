import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/net/follow_route.dart';

import 'support/follow_route_fakes.dart';

void main() {
  test('r12 grey rejoin keeps a route that revisits its origin', () async {
    final f = RouteFixture();
    addTearDown(f.dispose);
    await f.join();
    f.grow(500);
    f.depart();
    f.driveUntil(30000);
    final call = f.calls.last;
    final x = call.origin.lng * metersPerDegree;
    final y = call.origin.lat * metersPerDegree;
    final points = [
      call.origin,
      testPoint(x, y + 200),
      testPoint(x + 4, y),
      call.anchor,
    ];
    call.succeed(points: points);
    await flush();
    expect(f.state.connector, points);
    expect(f.state.status, '회색 경로를 따라 다시 합류');
    expect(f.state.routeProgress, closeTo(0, .01));
    for (var n = 0; n < 6; n++) f.drive(x, y: y, speed: 0);
    expect(f.state.connector, points);
    expect(f.state.routeProgress, closeTo(0, .01));
    expect(f.rejoinedEvents, [false]);
    expect(f.calls, hasLength(2));
  });

  for (final speed in <double?>[0, 1.99, null]) {
    test(
      'parked off trace ($speed m/s) does not accumulate or calculate',
      () async {
        final f = RouteFixture();
        addTearDown(f.dispose);
        await f.join();
        for (var n = 0; n < 40; n++) {
          f.drive(30, y: 90, speed: speed);
        }
        expect(f.departures, isEmpty);
        expect(f.calls, hasLength(1));
        // Moving again starts new evidence, including at the exact speed boundary.
        for (var n = 0; n < 6; n++) {
          f.drive(33.0 + n * 3, y: 90, speed: 2);
        }
        expect(f.departures, hasLength(1));
        expect(f.calls, hasLength(2));
      },
    );
  }
  test(
    'stopping while confirmed off route prevents a cooldown timer request',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.depart();
      expect(f.departures, hasLength(1));
      for (var n = 0; n < 30; n++) {
        f.drive(45, y: 80, speed: 0);
        expect(f.state.condition, FollowRouteCondition.offRoute);
      }
      f.update();
      expect(f.calls, hasLength(1));
      f.drive(48, y: 80);
      expect(f.calls, hasLength(2));
      expect(f.departures, hasLength(1));
    },
  );
  for (final acc in <double?>[null, -1, 25.01]) {
    test(
      'invalid accuracy $acc and duplicate delivery break departure evidence',
      () async {
        final f = RouteFixture();
        addTearDown(f.dispose);
        await f.join();
        f.drive(20, y: 80);
        f.drive(23, y: 80);
        f.drive(26, y: 80, elapsed: 3000, speed: 3);
        f.drive(29, y: 80, acc: acc);
        f.drive(32, y: 80);
        f.drive(35, y: 80);
        f.time += 5000;
        f.update();
        f.update();
        expect(f.departures, isEmpty);
        expect(f.calls, hasLength(1));
      },
    );
  }
  test(
    'a location jump and measurement time reversal cannot confirm departure',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.drive(20);
      f.drive(800, y: 800);
      f.self = testFix(
        801,
        y: 800,
        handle: 'self',
        seq: ++f.selfSeq,
        at: routeEpoch,
      );
      f.update();
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );
  test(
    'ten seconds of reverse travel on the same trace triggers a forward rejoin',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.grow(500);
      f.drive(60);
      f.drive(100);
      f.drive(150);
      final progress = f.state.progress;
      for (var n = 1; n <= 10; n++) f.drive(150.0 - n * 3);
      expect(f.departures, isEmpty);
      f.drive(117);
      expect(f.departures, hasLength(1));
      expect(f.state.progress, progress);
      for (var n = 0; f.time < 30000; n++) f.drive(114.0 - n * 3);
      expect(f.calls, hasLength(2));
      expect(
        f.state.anchorPoint!.lng * metersPerDegree,
        greaterThanOrEqualTo(150),
      );
    },
  );
  test(
    'recorded endpoint extension waits without routing back or claiming leader behind',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      for (var x = 30.0; x <= 300; x += 10) f.drive(x);
      expect(f.state.aheadOfTrace, isTrue);
      expect(f.state.status, '앞쪽 이동 경로를 기다립니다');
      expect(f.state.connector, isEmpty);
      expect(f.calls, hasLength(1));
      expect(f.departures, isEmpty);
      f.grow(400);
      f.drive(310);
      expect(f.state.aheadOfTrace, isFalse);
      expect(f.state.phase, FollowPhase.onTrace);
    },
  );
  test('a car beside the endpoint is not treated as overtaking', () {
    final points = [testPoint(0), testPoint(100)];
    expect(isBeyondTraceEnd(testPoint(130), points, 90), isTrue);
    expect(isBeyondTraceEnd(testPoint(130, 60), points, 90), isFalse);
    expect(isBeyondTraceEnd(testPoint(130), points, 270), isFalse);
    expect(isBeyondTraceEnd(testPoint(50), points, 90), isFalse);
  });
  for (final lateSuccess in [true, false]) {
    test(
      'natural return cancels a pending rejoin and rejects late ${lateSuccess ? 'success' : 'failure'}',
      () async {
        final f = RouteFixture();
        addTearDown(f.dispose);
        await f.join();
        f.grow(500);
        f.depart();
        f.driveUntil(30000);
        final pending = f.calls.last;
        // Return before J, without waiting for the provider or touching J.
        for (final x in [100.0, 106.0, 112.0, 118.0]) f.drive(x);
        expect(f.state.phase, FollowPhase.onTrace);
        expect(f.state.rejoining, isFalse);
        expect(f.state.connector, isEmpty);
        expect(pending.cancellation.isCancelled, isTrue);
        expect(f.rejoinedEvents, [false, true]);
        if (lateSuccess) {
          pending.succeed();
        } else {
          pending.fail('PROVIDER_AUTH_FAILED');
        }
        await flush();
        expect(f.state.phase, FollowPhase.onTrace);
        expect(f.state.condition, FollowRouteCondition.ready);
        expect(f.state.connector, isEmpty);
        expect(f.joins, hasLength(2));
      },
    );
  }
  test(
    'natural return during cooldown emits a rejoin and a later departure starts a new round',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.depart();
      for (final x in [60.0, 66.0, 72.0, 78.0, 84.0]) f.drive(x);
      expect(f.calls, hasLength(1));
      expect(f.rejoinedEvents, [false, true]);
      f.depart();
      expect(f.departures, [('follow-1', 1), ('follow-1', 2)]);
    },
  );
  test(
    'stale leader hides grey route and starts fresh join evidence after recovery',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.rejoinRoute();
      expect(f.state.connector, isNotEmpty);
      f.leaderAge = 10001;
      f.update();
      expect(f.state.connector, isEmpty);
      expect(f.state.marker, isNull);
      expect(f.state.condition, FollowRouteCondition.locationDelayed);
      f.leaderAge = 0;
      f.drive(110);
      expect(f.joins, hasLength(1));
      for (final x in [116.0, 122.0, 128.0]) f.drive(x);
      expect(f.rejoinedEvents, [false, true]);
    },
  );
  test(
    'missing trace invalidates an in-flight rejoin without inventing a connector',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.depart();
      f.driveUntil(30000);
      final pending = f.calls.last;
      f.trace = [];
      f.update();
      expect(f.state.condition, FollowRouteCondition.traceBroken);
      expect(pending.cancellation.isCancelled, isTrue);
      pending.succeed();
      await flush();
      expect(f.state.connector, isEmpty);
      expect(f.calls, hasLength(2));
    },
  );
  test(
    'leaving each grey route allows three new calculations per rolling five minutes',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.rejoinRoute();
      final firstAnchor = f.state.anchor;
      for (var n = 1; n <= 3; n++) {
        final y = 80.0 + n * 100;
        f.driveUntil((n + 1) * 30000, y: y);
        if (n < 3) {
          expect(f.calls, hasLength(n + 2));
          f.calls.last.succeed();
          await flush();
        }
      }
      expect(f.calls, hasLength(4)); // initial + three recoveries
      expect(f.state.anchor, isNot(firstAnchor));
      expect(f.state.condition, FollowRouteCondition.resetRequired);
      expect(f.state.connector, isEmpty);
      expect(f.departures, hasLength(1));
      f.driveUntil(330000, y: 380);
      expect(
        f.calls,
        hasLength(4),
      ); // budget expiry does not dismiss the reset UI
    },
  );
  test(
    'leaving the initial connector uses a segment anchor, never another P0',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(-200, handle: 'self');
      await f.start();
      f.grow(500);
      final p0 = f.state.anchor;
      f.depart(y: 100);
      f.driveUntil(30000, y: 100);
      expect(f.calls, hasLength(2));
      expect(f.state.anchor, isNot(p0));
      expect(f.calls.last.request.mode, FollowRouteKind.rejoin);
      expect(f.state.anchor!.end, isNotNull);
      expect(
        f.state.anchorPoint!.lng * metersPerDegree,
        lessThanOrEqualTo(f.leader!.lng * metersPerDegree),
      );
      expect(f.departures, hasLength(1));
    },
  );
  for (final speed in <double?>[2, null]) {
    test(
      'two metres per second ($speed reported) can build a movement direction and join',
      () async {
        final f = RouteFixture();
        addTearDown(f.dispose);
        await f.start();
        f.grow();
        for (var x = -20.0; x <= 30; x += 2) f.drive(x, speed: speed);
        expect(f.joins, hasLength(1));
      },
    );
  }
  test(
    'detectable parallel branches defer joining despite distance and matching direction',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.start();
      f.trace = [
        testFix(0),
        testFix(40, seq: 1),
        testFix(40, y: 8, seq: 2),
        testFix(0, y: 8, seq: 3),
      ];
      f.leader = f.trace.last;
      f.update();
      for (final x in [10.0, 14.0, 18.0, 22.0]) f.drive(x, y: 4);
      expect(f.joins, isEmpty);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );
  test(
    'natural rejoin after terminal route failure does not wait for another provider response',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.depart();
      f.driveUntil(30000);
      f.calls.last.fail('INVALID_PROVIDER_RESPONSE');
      await flush();
      expect(f.state.condition, FollowRouteCondition.noRoute);
      expect(f.state.connector, isEmpty);
      for (final x in [100.0, 106.0, 112.0, 118.0]) f.drive(x);
      expect(f.rejoinedEvents, [false, true]);
      expect(f.calls, hasLength(2));
    },
  );
  test('rejoin retry budget keeps B anchor and sent origin frozen', () async {
    final f = RouteFixture();
    addTearDown(f.dispose);
    await f.join();
    f.grow(500);
    f.depart();
    f.driveUntil(30000);
    final first = f.calls.last.request;
    for (var n = 0; n < 3; n++) {
      f.calls.last.fail('ROUTE_TIMEOUT', retryable: true);
      await flush();
      f.driveUntil(60000 + n * 30000);
    }
    expect(f.calls, hasLength(4)); // initial A + B + two retries
    for (final call in f.calls.skip(1)) {
      expect(call.request.mode, FollowRouteKind.rejoin);
      expect(call.request.calculationId, first.calculationId);
      expect(call.request.originRef, first.originRef);
      expect(call.request.anchor, first.anchor);
    }
    expect(f.state.condition, FollowRouteCondition.noRoute);
    expect(f.departures, hasLength(1));
  });
  test(
    'recovery pauses for a missing sent-origin reference and resumes on valid movement',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      await f.join();
      f.depart();
      f.originAge = 10001;
      f.driveUntil(30000);
      expect(f.calls, hasLength(1));
      expect(f.state.condition, FollowRouteCondition.waitingLocation);
      f.originAge = 0;
      f.driveUntil(39000);
      expect(f.calls, hasLength(2));
      expect(f.departures, hasLength(1));
    },
  );
}
