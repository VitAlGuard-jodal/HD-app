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
        (-.01, 0, 0, false),
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
