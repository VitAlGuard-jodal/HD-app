import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/meeting_plan.dart';

import 'support/follow_route_fakes.dart';

Future<RouteFixture> rejoining() async {
  final f = RouteFixture();
  addTearDown(f.dispose);
  await f.join();
  f.grow(2000);
  f.depart(y: 200);
  f.driveUntil(30000, y: 200);
  expect(f.calls, hasLength(2));
  return f;
}

void main() {
  test(
    'R20b the opposite U-turn leg 215 m behind is rejected by the lower bound',
    () {
      final trace = TracePath([
        testFix(0),
        testFix(200, seq: 1, at: routeEpoch + 3000),
        testFix(200, y: 15, seq: 2, at: routeEpoch + 4000),
        testFix(0, y: 15, seq: 3, at: routeEpoch + 7000),
      ]);
      final anchor = RouteAnchor.segment(
        SampleRef.of(trace.fixes[2]),
        SampleRef.of(trace.fixes[3]),
        .5,
      );
      final end = testPoint(100, 2), route = [testPoint(60, 2), end];
      final best = projectRoute(end, trace.points)!;
      expect(best.ambiguous, isFalse);
      expect(best.along - trace.resolve(anchor)!, closeTo(-215, .000001));
      expect(
        routeDirectionDifference(routeBearing(route.first, end), best.bearing),
        closeTo(0, .000001),
      );
      expect(projectTraceRejoinEndpoint(end, route, trace, anchor), isNull);
      final sameLeg = testPoint(108, 15);
      final accepted = projectTraceRejoinEndpoint(
        sameLeg,
        [testPoint(148, 15), sameLeg],
        trace,
        anchor,
      );
      expect(accepted, isNotNull);
      expect(accepted!.along - trace.resolve(anchor)!, closeTo(-8, .000001));
      expect(accepted.bearing, closeTo(270, .000001));
    },
  );

  for (final c in <(double, bool)>[
    (8, true),
    (10, true),
    (10.01, false),
    (15, false),
  ]) {
    test(
      'R20b a near endpoint ${c.$1} m behind has the bounded acceptance ${c.$2}',
      () {
        final trace = TracePath([
          testFix(0),
          testFix(400, seq: 1, at: routeEpoch + 6000),
        ]);
        final anchor = RouteAnchor.segment(
          SampleRef.of(trace.fixes[0]),
          SampleRef.of(trace.fixes[1]),
          .25,
        );
        final end = testPoint(100 - c.$1, 5.7),
            route = [testPoint(60 - c.$1, 5.7), end];
        expect(routeDistance(end, testPoint(100)), lessThan(25));
        expect(
          projectTraceRejoinEndpoint(end, route, trace, anchor) != null,
          c.$2,
        );
      },
    );
  }

  test(
    'R20b accepting a near endpoint 8 m behind retains the request anchor and its next validation floor',
    () async {
      final f = await rejoining();
      final call = f.calls.last;
      final requestedPoint = f.state.anchorPoint!,
          requestedAt = f.state.anchorAt;
      final x = requestedPoint.lng * metersPerDegree;
      call.succeed(
        points: [call.origin, testPoint(x - 48, 5.7), testPoint(x - 8, 5.7)],
      );
      await flush();
      expect(f.state.connector, isNotEmpty);
      expect(f.state.anchor, call.request.anchor);
      expect(f.state.anchorPoint, requestedPoint);
      expect(f.state.anchorAt, requestedAt);
      final trace = TracePath(f.trace);
      expect(
        trace.resolve(f.state.anchor!),
        trace.resolve(call.request.anchor),
      );
      // A later validation must still measure from the requested floor: -15 m
      // cannot turn into an acceptable -7 m after the first -8 m result.
      final later = testPoint(x - 15, 5.7);
      expect(
        projectTraceRejoinEndpoint(
          later,
          [testPoint(x - 55, 5.7), later],
          trace,
          f.state.anchor!,
        ),
        isNull,
      );
      expect(f.rejoinedEvents, [false]);
      expect(f.calls, hasLength(2));
    },
  );
  test(
    'R20 an endpoint 5.7 m beside the target may project 0.001 m behind minimum',
    () {
      final trace = TracePath([
        testFix(0),
        testFix(400, seq: 1, at: routeEpoch + 6000),
      ]);
      final anchor = RouteAnchor.segment(
        SampleRef.of(trace.fixes.first),
        SampleRef.of(trace.fixes.last),
        .25,
      );
      final end = testPoint(99.999, 5.7);
      final before = testPoint(
        59.999,
        5.7 - 40 * math.tan(1.4 * math.pi / 180),
      );
      final p = projectTraceRejoinEndpoint(end, [before, end], trace, anchor);
      expect(p, isNotNull);
      expect(p!.along - 100, closeTo(-.001, .000001));
      expect(p.distance, closeTo(5.7, .000001));
    },
  );

  test(
    'R20 an endpoint 30 m from the target and 10 m behind remains rejected',
    () {
      final trace = TracePath([
        testFix(0),
        testFix(400, seq: 1, at: routeEpoch + 6000),
      ]);
      final anchor = RouteAnchor.segment(
        SampleRef.of(trace.fixes.first),
        SampleRef.of(trace.fixes.last),
        .025,
      );
      final end = testPoint(-20);
      expect(routeDistance(end, testPoint(10)), closeTo(30, .000001));
      expect(
        projectTraceRejoinEndpoint(end, [testPoint(-40), end], trace, anchor),
        isNull,
      );
    },
  );

  test(
    'R20 an opposite endpoint inside 25 m stays rejected even behind minimum',
    () {
      final trace = TracePath([
        testFix(0),
        testFix(400, seq: 1, at: routeEpoch + 6000),
      ]);
      final anchor = RouteAnchor.segment(
        SampleRef.of(trace.fixes.first),
        SampleRef.of(trace.fixes.last),
        .25,
      );
      final end = testPoint(99.999, 5.7);
      expect(
        projectTraceRejoinEndpoint(
          end,
          [testPoint(139.999, 5.7), end],
          trace,
          anchor,
        ),
        isNull,
      );
    },
  );

  test(
    'R20 the near-target radius does not bypass the upper bound or ambiguity',
    () {
      final shapes = [
        [
          (0.0, 20.0),
          (100.0, 20.0),
          (100.0, 100.0),
          (0.0, 100.0),
          (0.0, 0.0),
          (100.0, 0.0),
        ],
        [
          (0.0, 0.0),
          (100.0, 0.0),
          (100.0, 100.0),
          (0.0, 100.0),
          (0.0, 4.0),
          (100.0, 4.0),
        ],
      ];
      for (final shape in shapes) {
        final trace = TracePath([
          for (var i = 0; i < shape.length; i++)
            testFix(
              shape[i].$1,
              y: shape[i].$2,
              seq: i,
              at: routeEpoch + i * 2000,
            ),
        ]);
        final anchor = RouteAnchor.segment(
          SampleRef.of(trace.fixes[0]),
          SampleRef.of(trace.fixes[1]),
          .5,
        );
        final end = testPoint(50);
        expect(
          routeDistance(end, trace.pointAt(trace.resolve(anchor)!)),
          lessThanOrEqualTo(25),
        );
        expect(
          projectTraceRejoinEndpoint(end, [testPoint(30), end], trace, anchor),
          isNull,
        );
      }
    },
  );

  test(
    'R20 the near-boundary result paints the grey route without an early join',
    () async {
      final f = await rejoining();
      final call = f.calls.last;
      final endX = call.anchor.lng * metersPerDegree - .001;
      final points = [
        call.origin,
        testPoint(endX - 40, 5.7),
        testPoint(endX, 5.7),
      ];
      call.succeed(points: points);
      await flush();
      expect(f.state.connector, points);
      expect(f.state.status, '회색 경로를 따라 다시 합류');
      expect(
        f.state.anchorPoint!.lng * metersPerDegree,
        closeTo(call.anchor.lng * metersPerDegree, .000001),
      );
      expect(f.state.anchor, call.request.anchor);
      expect(f.rejoinedEvents, [false]);
      for (var n = 1; n <= 4; n++) {
        final p = interpolateRoute(call.origin, points[1], n / 4);
        f.drive(p.lng * metersPerDegree, y: p.lat * metersPerDegree, speed: 50);
      }
      for (final x in [endX - 20, endX, endX + 6])
        f.drive(x, y: 5.7, speed: 20);
      expect(f.rejoinedEvents, [false, true]);
      expect(f.calls, hasLength(2));
    },
  );
  test(
    'R17 grey route accepts a shifted endpoint and uses its trace projection as the marker',
    () async {
      final f = await rejoining();
      final call = f.calls.last;
      final endX = call.anchor.lng * metersPerDegree + 80;
      final points = [call.origin, testPoint(endX - 40, 5), testPoint(endX, 5)];
      final json = routeJson(
        call.request,
        call.origin,
        call.anchor,
        points: points,
      )..['endGapMeters'] = routeDistance(points.last, call.anchor);
      call.pending.complete(FollowRouteResult.fromJson(json, call.request));
      await flush();
      expect(f.state.connector, points);
      expect(f.state.anchorPoint!.lng * metersPerDegree, closeTo(endX, .01));
      expect(f.state.anchorPoint!.lat * metersPerDegree, closeTo(0, .01));
      expect(f.state.anchor, isNot(call.request.anchor));
      expect(
        f.joins,
        hasLength(1),
        reason: 'accepting a route is not a rejoin',
      );
      for (var n = 1; n <= 4; n++) {
        final point = interpolateRoute(call.origin, points[1], n / 4);
        f.drive(
          point.lng * metersPerDegree,
          y: point.lat * metersPerDegree,
          speed: 55,
        );
      }
      for (final x in [endX - 20, endX, endX + 6]) f.drive(x, y: 5, speed: 20);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.rejoinedEvents, [false, true]);
      expect(f.calls, hasLength(2));
    },
  );

  test(
    'R17 endpoint failure already tries one candidate 60 m ahead after 30 seconds',
    () async {
      final f = await rejoining();
      final target = f.calls.last.anchor.lng * metersPerDegree;
      f.calls.last.fail('ENDPOINT_MISMATCH');
      await flush();
      f.driveUntil(59000, y: 200);
      expect(f.calls, hasLength(2));
      f.driveUntil(60000, y: 200);
      expect(f.calls, hasLength(3));
      expect(
        f.calls.last.anchor.lng * metersPerDegree,
        closeTo(target + 60, .01),
      );
      f.calls.last.fail('ENDPOINT_MISMATCH');
      await flush();
      f.driveUntil(90000, y: 200);
      expect(f.calls, hasLength(3));
    },
  );

  test(
    'R17 rejoin failure explains the pending retry and its countdown',
    () async {
      final f = await rejoining();
      f.calls.last.fail('ENDPOINT_MISMATCH');
      await flush();
      expect(f.state.status, contains('재합류'));
      expect(f.state.status, contains('30초'));
      f.drive(f.self!.lng * metersPerDegree + 3, y: 200, speed: 3);
      expect(f.state.status, contains('29초'));
      expect(f.state.connector, isEmpty);
      expect(f.state.marker, isNull);
    },
  );

  test(
    'R17 trace endpoint distance, forward window, heading and ambiguity match the server',
    () {
      final trace = TracePath([
        testFix(0),
        testFix(400, seq: 1, at: routeEpoch + 6000),
      ]);
      final anchor = RouteAnchor.segment(
        SampleRef.of(trace.fixes.first),
        SampleRef.of(trace.fixes.last),
        .25,
      );
      for (final c in <(double, double, double, bool)>[
        (0, 0, 0, true),
        (120, 25, 0, true),
        (120.01, 0, 0, false),
        (-.01, 0, 0, true),
        (-25, 0, 0, false),
        (-25.01, 0, 0, false),
        (80, 25.01, 0, false),
        (80, 0, 60, true),
        (80, 0, 60.01, false),
        (10, 0, 90, true),
        (10, 0, 120, false),
        (10, 0, 180, false),
      ]) {
        final end = testPoint(100 + c.$1, c.$2);
        final before = testPoint(
          100 + c.$1 - 20 * math.cos(c.$3 * math.pi / 180),
          c.$2 - 20 * math.sin(c.$3 * math.pi / 180),
        );
        expect(
          projectTraceRejoinEndpoint(end, [before, end], trace, anchor) != null,
          c.$4,
          reason: 'advance=${c.$1}, offset=${c.$2}, angle=${c.$3}',
        );
      }
      final competing = TracePath([
        testFix(0),
        testFix(400, seq: 1, at: routeEpoch + 6000),
        testFix(400, y: 100, seq: 2, at: routeEpoch + 8000),
        testFix(0, y: 100, seq: 3, at: routeEpoch + 14000),
        testFix(0, y: 4, seq: 4, at: routeEpoch + 16000),
        testFix(400, y: 4, seq: 5, at: routeEpoch + 22000),
      ]);
      expect(
        projectTraceRejoinEndpoint(
          testPoint(180, 2),
          [testPoint(160, 2), testPoint(180, 2)],
          competing,
          anchor,
        ),
        isNull,
      );
    },
  );

  test(
    'R17 schema 2 keeps the requested anchor while permitting a verified rejoin point gap',
    () async {
      final f = await rejoining();
      final call = f.calls.last;
      final endX = call.anchor.lng * metersPerDegree + 80;
      final request = PlanRouteRequest(
        planId: 'plan-1',
        planRevision: 1,
        followRequestId: call.request.followRequestId,
        guidanceGeneration: call.request.guidanceGeneration,
        calculationId: call.request.calculationId,
        requestId: call.request.requestId,
        routeKind: PlanRouteKind.traceRejoin,
        originRef: call.request.originRef,
        traceAnchor: call.request.anchor,
      );
      final payload = routeJson(
        call.request,
        call.origin,
        call.anchor,
        points: [call.origin, testPoint(endX - 40), testPoint(endX)],
      )..remove('mode');
      payload.addAll(request.toJson());
      payload['endGapMeters'] = 80;
      final result = request.parseResult(payload);
      expect(result.anchor, call.anchor);
      expect(result.actualEnd, testPoint(endX));
      payload['endGapMeters'] = 145.01;
      expect(() => request.parseResult(payload), throwsFormatException);
      call.fail('NO_ROUTE');
      await flush();
    },
  );

  test(
    'R17 an opposite endpoint cannot paint a grey route even inside 25 m',
    () async {
      final f = await rejoining();
      final call = f.calls.last;
      final x = call.anchor.lng * metersPerDegree;
      call.succeed(
        points: [call.origin, testPoint(x + 50, 5), testPoint(x + 10, 5)],
      );
      await flush();
      expect(f.state.connector, isEmpty);
      expect(f.state.marker, isNull);
      expect(f.state.status, contains('재합류'));
      expect(f.rejoinedEvents, [false]);
    },
  );

  test(
    'R17 an elapsed retry waits for movement and never promises a stopped-car request',
    () async {
      final f = await rejoining();
      f.calls.last.fail('ENDPOINT_MISMATCH');
      await flush();
      for (var n = 0; n < 31; n++)
        f.drive(f.self!.lng * metersPerDegree, y: 200, speed: 0);
      expect(f.calls, hasLength(2));
      expect(f.state.status, contains('이동 확인'));
      f.drive(f.self!.lng * metersPerDegree + 3, y: 200, speed: 3);
      expect(f.calls, hasLength(3));
      expect(f.state.status, '재합류 경로 계산 중');
    },
  );
}
