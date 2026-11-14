import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/meeting_plan.dart';

import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

void main() {
  test(
    'R18.6 a narrower fallback cannot replace the wider reachable projection',
    () {
      const request = FollowRouteRequest(
        followRequestId: 'follow-1',
        guidanceGeneration: 1,
        calculationId: 'window',
        requestId: 'window',
        mode: FollowRouteKind.initial,
        originRef: SampleRef('0123456789abcdef', 0),
        anchor: RouteAnchor.sample(SampleRef('0123456789abcdef', 1)),
      );
      final route = FollowRouteResult.fromJson(
        routeJson(request, testPoint(0), testPoint(1000)),
        request,
      );
      final original = projectGuidanceRoute(
        testPoint(250, 80),
        route,
        advance: 300,
      );
      final fallback = projectGuidanceRoute(
        testPoint(250, 80),
        route,
        advance: 300,
        fallbackAdvance: 120,
      );
      expect(original.window!.along, closeTo(250, .01));
      expect(fallback.window, isNotNull);
      expect(fallback.window!.along, closeTo(original.window!.along, .000001));
      expect(
        fallback.window!.distance,
        closeTo(original.window!.distance, .000001),
      );
      expect(fallback.usable, isFalse);
      expect(fallback.progress, 0);
    },
  );
  test(
    'R18.2 endpoint matching uses the anchor branch instead of lines across GPS gaps',
    () {
      final fixes = [
        testFix(111),
        testFix(600, seq: 1, at: routeEpoch + 11000),
        testFix(0, seq: 2, at: routeEpoch + 31000),
        testFix(200, seq: 3, at: routeEpoch + 35000),
        testFix(600, seq: 4, at: routeEpoch + 41000),
      ];
      final anchor = RouteAnchor.segment(
        SampleRef.of(fixes[3]),
        SampleRef.of(fixes[4]),
        0,
      );
      final branches = splitFollowTrace(fixes);
      expect(branches, hasLength(3));
      final branch = branches.singleWhere((p) => p.resolve(anchor) != null);
      final endpoint = projectTraceRejoinEndpoint(
        testPoint(280),
        [testPoint(240), testPoint(280)],
        branch,
        anchor,
      );
      expect(endpoint, isNotNull);
      expect(endpoint!.along, closeTo(280, .01));
    },
  );
  for (final retained in [false, true]) {
    test(
      'R18.1 plan trace primes without a first-approach request (retained=$retained)',
      () async {
        var time = 0, seq = 0, joins = 0;
        final calls = <PlanRouteRequest>[];
        final c = FollowRouteController(
          load: (_, __, ___) =>
              throw StateError('no schema 1 request in a plan'),
          loadPlan: (_, request, __) {
            calls.add(request);
            expect(calls.length, 1);
            return Completer<FollowRouteResult>().future;
          },
          canChange: () => true,
          onJoined: (_, __, ___) => joins++,
          onDeparted: (_, __) {},
          onInvalidated: () {},
          now: () => time,
        );
        addTearDown(c.dispose);
        const request = PlanRouteRequest(
          planId: 'plan-1',
          planRevision: 1,
          followRequestId: 'follow-1',
          guidanceGeneration: 1,
          calculationId: 'approach',
          requestId: 'approach',
          routeKind: PlanRouteKind.planJoin,
          originRef: SampleRef('0123456789abcdef', 0),
        );
        final approach = PlanRouteCall(
          request,
          RouteCancellation(),
          testPoint(-100),
          testPoint(0),
        );
        final trace = [for (var n = 0; n <= 200; n++) testFix(n * 10, seq: n)];
        void update(
          double x, {
          double y = 0,
          bool missing = false,
          String? condition,
        }) {
          time += 1000;
          final self = testFix(
            x,
            y: y,
            handle: 'self',
            seq: seq++,
            at: routeEpoch + time,
            speed: 6,
          );
          c.update(
            FollowRouteInput(
              room: 'ROOM',
              account: 'self',
              device: 'device',
              relationship: 'follow-1',
              target: 'leader',
              self: self,
              origin: self,
              leader: trace.last,
              selfAgeMs: 0,
              originAgeMs: 0,
              leaderAgeMs: 0,
              trace: missing ? [] : trace,
              consent: true,
              connected: true,
              planCondition: condition,
              planApproachRoute: retained
                  ? request.parseResult(approach.json)
                  : null,
              planTrace: const PlanTraceContext(
                'plan-1',
                1,
                RouteAnchor.sample(SampleRef('0123456789abcdef', 0)),
              ),
            ),
          );
        }

        update(0, missing: true);
        expect(calls, isEmpty);
        update(0);
        expect(c.state!.rejoining, isFalse);
        for (var n = 1; n <= 5; n++) update(n * 6);
        expect(calls, isEmpty);
        expect(joins, 1);
        update(30, condition: 'locationDelayed');
        update(36);
        expect(calls, isEmpty);
        for (var n = 0; n < 8; n++) update(42 + n * 6, y: 80);
        expect(calls.single.routeKind, PlanRouteKind.traceRejoin);
        expect(c.state!.rejoining, isTrue);
        expect(calls.single.traceAnchor!.end, isNotNull);
      },
    );
  }
}
