import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/meeting_plan.dart';
import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

void main() {
  test(
    'plan trace keeps progress through a location hold and uses schema 2 for actual rejoining',
    () {
      var time = 0, seq = 0, joined = 0;
      final calls = <PlanRouteRequest>[];
      final c = FollowRouteController(
        load: (_, __, ___) => throw StateError('schema 1 must not be used'),
        loadPlan: (_, request, __) {
          calls.add(request);
          return Completer<FollowRouteResult>().future;
        },
        canChange: () => true,
        onJoined: (_, __, ___) {
          joined++;
        },
        onDeparted: (_, __) {},
        onInvalidated: () {},
        now: () => time,
      );
      addTearDown(c.dispose);
      final trace = [for (var i = 0; i < 80; i++) testFix(i * 10, seq: i)];
      const approachRequest = PlanRouteRequest(
        planId: 'plan-1',
        planRevision: 1,
        followRequestId: 'follow-1',
        guidanceGeneration: 1,
        calculationId: 'approach',
        requestId: 'approach-1',
        routeKind: PlanRouteKind.planJoin,
        originRef: SampleRef('0123456789abcdef', 0),
      );
      final approach = PlanRouteCall(
        approachRequest,
        RouteCancellation(),
        testPoint(-100),
        testPoint(0),
      );
      final approachResult = approachRequest.parseResult(approach.json);
      void update(double x, {double y = 0, String? condition}) {
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
            trace: trace,
            consent: true,
            connected: true,
            planCondition: condition,
            planApproachRoute: approachResult,
            planTrace: const PlanTraceContext(
              'plan-1',
              1,
              RouteAnchor.sample(SampleRef('0123456789abcdef', 0)),
            ),
          ),
        );
      }

      for (var i = 0; i < 6; i++) {
        update(i * 6);
        if (i == 0) expect(c.state!.view.connector, isNotEmpty);
      }
      expect(joined, 1);
      expect(c.state!.view.connector, isEmpty);
      final progress = c.state!.progress, generation = c.state!.generation;
      update(30, condition: 'locationDelayed');
      expect(c.state!.phase, FollowPhase.onTrace);
      expect(c.state!.progress, progress);
      expect(c.state!.generation, generation);
      update(36);
      for (var i = 0; i < 8; i++) {
        update(42 + i * 6, y: 80);
      }
      expect(calls.single.routeKind, PlanRouteKind.traceRejoin);
      expect(calls.single.planId, 'plan-1');
      expect(calls.single.traceAnchor!.end, isNotNull);
    },
  );
  test(
    'manual wait requires place confirmation, saves self CAS, and keeps invitations separate from enrollment',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      f.stop();
      f.controller.beginEditing();
      await flush();
      f.controller.pickPoint(testPoint(1000));
      f.controller.confirmPoint();
      f.controller.selectField(MeetingPointField.joinPoint);
      f.controller.pickPoint(testPoint(100));
      f.controller.confirmPoint();
      final before = f.calls.length;
      await f.controller.save();
      expect(f.calls.length, before);
      expect(f.controller.error, contains('정차 가능한'));
      f.controller.confirmWaitingPlace();
      final save = f.controller.save(), c = f.calls.last;
      expect(c.path, '/follow-plans/self');
      expect(c.body!['expectedPlanId'], isNull);
      expect(c.body!['expectedRevision'], 0);
      expect(c.body!['participantFollowRequestIds'], ['follow-1']);
      c.complete({
        'plan': planJson(),
        'runtime': runtimeJson(
          enrolled: false,
          follower: 'follower',
          phase: 'idle',
        ),
      });
      await save;
      expect(f.controller.owner, isTrue);
      expect(f.routes, isEmpty);
      expect(f.controller.canDepart, isFalse);
      expect(f.controller.editing, isFalse);
    },
  );
  test(
    'replacement plan never takes over a cancelled selected plan; old clear never cancels new selection',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.controller.planCleared('plan-1', 'leader');
      f.controller.applyPlan(
        snapshot(
          plan: planJson(id: 'plan-2'),
          runtime: runtimeJson(id: 'plan-2'),
        ),
      );
      expect(f.controller.active, isNull);
      expect(f.controller.selected, isTrue);
      expect(f.routes.length, 1);
      final join = f.controller.enroll(true);
      f.calls.last.complete({
        'plan': planJson(id: 'plan-2'),
        'runtime': runtimeJson(id: 'plan-2'),
      });
      await join;
      expect(f.routes.length, 2);
      f.controller.planCleared('plan-1', 'leader');
      expect(f.controller.active!.plan.planId, 'plan-2');
      expect(f.routes.last.cancellation.isCancelled, isFalse);
    },
  );
  test(
    'wait leader first and leftEarly do not announce departure or skip the follower J',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(runtime: runtimeJson(leaderPhase: 'atJoinWaiting'));
      f.routes.single.succeed();
      await flush();
      expect(f.controller.routeKind, PlanRouteKind.planJoin);
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(runtimeRevision: 2, phase: 'leftEarly'),
        ),
      );
      expect(f.controller.status, contains('떠났습니다'));
      expect(f.controller.traceContext, isNull);
      expect(f.controller.routeKind, PlanRouteKind.planJoin);
      expect(f.routes.length, 1);
    },
  );
  test(
    'passing between samples submits the three original references even beyond the route endpoint',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(plan: planJson(policy: 'proceed'));
      f.routes.single.succeed();
      await flush();
      for (final x in [60.0, 130.0]) {
        f.drive(x, speed: 40);
      }
      final evidence = f.calls
          .where((c) => c.path.endsWith('/pass-evidence'))
          .last;
      expect(evidence.body!['pointKind'], 'joinPoint');
      expect(evidence.body!['revision'], 1);
      expect(
        evidence.body!['ownRefs'],
        f.controller.ownSamples
            .skip(f.controller.ownSamples.length - 3)
            .map((s) => SampleRef.of(s).toJson())
            .toList(),
      );
      expect(f.controller.ownRuntime!.branch, 'pending');
    },
  );
  test(
    'same hello keeps current guidance but capability loss stops trace guidance',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.controller.applySnapshot(
        [snapshot()],
        [],
        planFeatures,
        authoritative: true,
      );
      f.routes.single.succeed();
      await flush();
      expect(f.controller.view!.connector, isNotEmpty);
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(
            runtimeRevision: 2,
            followerPhase: 'tracePriming',
            branch: 'trace',
            trace: const RouteAnchor.sample(SampleRef('0123456789abcdef', 0)),
          ),
        ),
      );
      expect(f.controller.traceContext, isNotNull);
      f.controller.applySnapshot(
        [snapshot()],
        [],
        const MeetingCapabilities(),
        authoritative: true,
      );
      expect(f.controller.traceContext, isNull);
      expect(f.controller.view!.connector, isEmpty);
    },
  );
  test(
    'old server fails closed; missing stop evidence never enables editing',
    () {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      expect(f.controller.canEditMeetingPlan, isFalse);
      f.stop();
      expect(f.controller.canEditMeetingPlan, isTrue);
      f.controller.applySnapshot(
        [],
        [],
        const MeetingCapabilities(),
        authoritative: true,
      );
      expect(f.controller.beginEditing(), isFalse);
    },
  );
  test(
    'vehicle missing acc follows r6; phone missing acc and unknown/stale movement stay locked',
    () {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      for (var i = 0; i < 3; i++) {
        f.drive(0, acc: null, src: 'vehicle');
      }
      expect(f.controller.canEditMeetingPlan, isTrue);
      f.drive(0, acc: null);
      expect(f.controller.canEditMeetingPlan, isFalse);
      f.stop();
      f.age = 10001;
      f.update();
      expect(f.controller.canEditMeetingPlan, isFalse);
      f.age = 0;
      f.stop();
      f.restricted = true;
      f.update();
      expect(f.controller.canEditMeetingPlan, isFalse);
    },
  );
  test(
    'stationary unknown speed needs three continuous fixes; motion closes editor and invalidates query',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      for (var i = 0; i < 3; i++) {
        f.drive(0, speed: null);
      }
      expect(f.controller.beginEditing(), isTrue);
      await flush();
      final search = f.controller.search('서울 중구 세종대로 110');
      final call = f.calls.last;
      f.drive(10, speed: 10);
      call.complete({
        'requestId': call.body!['requestId'],
        'results': [
          {'lat': 0.0, 'lng': 0.1, 'roadAddress': '시험 주소', 'jibunAddress': ''},
        ],
      });
      await search;
      expect(f.controller.editing, isFalse);
      expect(f.controller.addresses, isEmpty);
      expect(call.cancellation.isCancelled, isTrue);
    },
  );
  test(
    'map and address selection remain candidates; D edit clears J and wait confirmation',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      f.stop();
      f.controller.beginEditing();
      await flush();
      f.controller.pickPoint(testPoint(1000));
      expect(f.controller.destination, isNull);
      f.controller.confirmPoint();
      f.controller.selectField(MeetingPointField.joinPoint);
      f.controller.pickPoint(testPoint(100));
      f.controller.confirmPoint();
      f.controller.confirmWaitingPlace();
      expect(f.controller.waitingPlaceConfirmed, isTrue);
      f.controller.selectField(MeetingPointField.destination);
      f.controller.pickPoint(testPoint(2000));
      f.controller.confirmPoint();
      expect(f.controller.joinPoint, isNull);
      expect(f.controller.waitingPlaceConfirmed, isFalse);
    },
  );
  test(
    'late D search is not applied to J; zero results are not a route failure',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      f.stop();
      f.controller.beginEditing();
      await flush();
      final pending = f.controller.search('서울 주소');
      final c = f.calls.last;
      f.controller.selectField(MeetingPointField.joinPoint);
      c.complete({
        'requestId': c.body!['requestId'],
        'results': [
          {'lat': 0, 'lng': 1, 'roadAddress': '옛 목적지', 'jibunAddress': ''},
        ],
      });
      await pending;
      expect(f.controller.addresses, isEmpty);
      final empty = f.controller.search('없는 주소');
      final e = f.calls.last;
      e.complete({'requestId': e.body!['requestId'], 'results': <Object>[]});
      await empty;
      expect(f.controller.searchMessage, contains('주소를 찾지 못했습니다'));
      expect(f.controller.error, isNull);
    },
  );
  test(
    'recommend without J/enrollment uses accepted direct IDs and explicit 18 second request',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      f.stop();
      f.controller.beginEditing();
      await flush();
      f.controller.pickPoint(testPoint(1000));
      f.controller.confirmPoint();
      final future = f.controller.recommend(), c = f.calls.last;
      expect(c.body!['participantFollowRequestIds'], ['follow-1']);
      expect(c.body!['planId'], isNull);
      expect(c.timeout, const Duration(seconds: 18));
      c.complete({
        'requestId': c.body!['requestId'],
        'draftGeneration': c.body!['draftGeneration'],
        'result': 'candidate',
        'joinPoint': pointJson(163, source: 'recommendation'),
        'calculatedAtMs': routeEpoch + f.time,
        'etaQuality': 'rough',
        'arrivals': [
          {'handle': 'leader', 'etaToJoinSeconds': 10, 'waitSeconds': 5},
          {'handle': 'follower', 'etaToJoinSeconds': 15, 'waitSeconds': 0},
        ],
        'remainingToDestinationMeters': 837,
        'remainingToDestinationSeconds': 60,
      });
      await future;
      expect(f.controller.joinPoint, isNull);
      expect(f.controller.recommendation!.remainingMeters, 837);
      f.controller.pickPoint(testPoint(200));
      expect(f.controller.recommendation, isNull);
      f.controller.confirmPoint();
      expect(f.controller.joinPoint!.point, testPoint(200));
    },
  );
  test(
    'wait follower first waits without trace and without join-complete announcement',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      expect(f.routes.single.request.routeKind, PlanRouteKind.planJoin);
      f.routes.single.succeed();
      await flush();
      expect(f.controller.view!.connector, isNotEmpty);
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(runtimeRevision: 2, followerPhase: 'atJoinWaiting'),
        ),
      );
      expect(f.controller.view!.connector, isNotEmpty);
      expect(f.controller.traceContext, isNull);
      expect(f.controller.status, contains('대기'));
      expect(f.notices.length, 2);
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(runtimeRevision: 2, followerPhase: 'atJoinWaiting'),
        ),
      );
      expect(f.notices.length, 2);
    },
  );
  test(
    'leader own X to J uses null relationship; departure announced enables current X to D',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      f.stop();
      f.controller.applyPlan(
        snapshot(runtime: runtimeJson(follower: 'follower')),
      );
      await f.controller.selectOwnGuidance();
      expect(f.routes.single.request.followRequestId, isNull);
      expect(f.routes.single.request.routeKind, PlanRouteKind.planJoin);
      f.routes.single.succeed();
      await flush();
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(
            runtimeRevision: 2,
            follower: 'follower',
            leaderPhase: 'atJoinWaiting',
            followerPhase: 'atJoinWaiting',
          ),
        ),
      );
      expect(f.controller.canDepart, isTrue);
      final departure = f.controller.depart();
      final c = f.calls.last;
      expect(c.body!['expectedRuntimeRevision'], 2);
      c.complete({
        'runtime': runtimeJson(
          runtimeRevision: 3,
          follower: 'follower',
          leaderPhase: 'atJoinWaiting',
          followerPhase: 'atJoinWaiting',
          announced: routeEpoch,
        ),
      });
      await departure;
      expect(f.routes.last.request.routeKind, PlanRouteKind.planDestination);
      expect(f.routes.length, 2);
    },
  );
  test(
    'proceed follower first fixes destination even if leader passes later',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(plan: planJson(policy: 'proceed'));
      f.routes.single.succeed();
      await flush();
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(
            runtimeRevision: 2,
            followerPhase: 'toDestination',
            branch: 'destination',
          ),
        ),
      );
      f.update();
      expect(f.routes.last.request.routeKind, PlanRouteKind.planDestination);
      expect(f.controller.traceContext, isNull);
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(
            runtimeRevision: 3,
            followerPhase: 'toDestination',
            branch: 'destination',
            trace: const RouteAnchor.sample(SampleRef('0123456789abcdef', 1)),
          ),
        ),
      );
      expect(f.routes.length, 2);
      expect(f.controller.traceContext, isNull);
    },
  );
  test(
    'proceed leader first only primes actual reference; ambiguous order stays pending',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(plan: planJson(policy: 'proceed'));
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(runtimeRevision: 2, passed: routeEpoch),
        ),
      );
      expect(f.controller.routeKind, isNull);
      expect(f.controller.traceContext, isNull);
      expect(f.controller.status, contains('확인 중'));
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(
            runtimeRevision: 3,
            followerPhase: 'tracePriming',
            branch: 'trace',
            trace: const RouteAnchor.sample(SampleRef('0123456789abcdef', 8)),
          ),
        ),
      );
      expect(f.controller.traceContext!.start.start.seq, 8);
      expect(f.notices.single, endsWith(':ready'));
    },
  );
  test(
    'J equals D has destination guidance and no departure or trace',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(plan: planJson(join: 1000));
      expect(f.routes.single.request.routeKind, PlanRouteKind.planDestination);
      expect(f.controller.canDepart, isFalse);
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(
          runtimeJson(
            runtimeRevision: 2,
            followerPhase: 'completed',
            branch: 'destination',
          ),
        ),
      );
      expect(f.controller.routeKind, isNull);
      expect(f.controller.active, isNotNull);
    },
  );
  test(
    'runtime progress does not reset the fixed route; old revisions are ignored',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(runtimeJson(runtimeRevision: 9)),
      );
      f.controller.applyRuntime(
        MeetingRuntime.fromJson(runtimeJson(runtimeRevision: 2)),
      );
      expect(f.controller.active!.runtime!.runtimeRevision, 9);
      expect(f.routes.length, 1);
      f.routes.single.succeed();
      await flush();
      expect(f.controller.view!.connector, isNotEmpty);
    },
  );
  test(
    'empty authoritative hello retires plan and rejects late success/update without auto A',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      final call = f.routes.single;
      f.controller.applySnapshot([], [], planFeatures, authoritative: true);
      call.succeed();
      await flush();
      f.controller.applyPlan(snapshot());
      expect(f.controller.active, isNull);
      expect(f.controller.selected, isTrue);
      expect(f.controller.view!.connector, isEmpty);
    },
  );
  test(
    'restored enrollment requires deliberate reset and never enrolls on reconnect',
    () {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      f.controller.applySnapshot(
        [snapshot()],
        [],
        planFeatures,
        authoritative: true,
      );
      expect(f.controller.restored, isTrue);
      expect(f.calls, isEmpty);
      expect(f.routes, isEmpty);
      f.controller.resetGuidance();
      expect(f.routes.length, 1);
    },
  );
  test(
    'replaced device, consent loss and relation replacement discard late route failures',
    () async {
      for (final invalidation in ['device', 'consent', 'relation']) {
        final f = MeetingFixture();
        f.stop();
        await f.enroll();
        final c = f.routes.single;
        if (invalidation == 'device') f.device = 'new';
        if (invalidation == 'consent') f.consent = false;
        if (invalidation == 'relation') f.relationship = 'new-follow';
        f.update();
        c.pending.completeError(const FollowRouteException('NO_ROUTE'));
        await flush();
        expect(f.controller.view?.connector ?? [], isEmpty);
        f.dispose();
      }
    },
  );
  test(
    'persistent deviation before J recalculates same J, not an old trace point',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.routes.single.succeed();
      await flush();
      for (var i = 0; i < 35; i++) {
        f.drive(10 + i * 3, y: 80, speed: 3);
      }
      expect(f.routes.length, 2);
      expect(f.routes.last.request.routeKind, PlanRouteKind.planJoin);
      expect(f.routes.last.goal, testPoint(100));
      expect(f.controller.view!.rejoining, isTrue);
    },
  );
  test(
    'rate limit keeps accepted inputs, displays delay, and expires without endless retry',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      final first = f.routes.single.request;
      f.routes.single.pending.completeError(
        FollowRouteException(
          'RATE_LIMITED',
          retryAfterMs: 30000,
          inputAccepted: true,
          inputExpiresAtMs: routeEpoch + 120000,
        ),
      );
      await flush();
      expect(f.controller.status, contains('30초'));
      for (var i = 0; i < 31; i++) {
        f.drive(0);
      }
      expect(f.routes.length, 2);
      expect(f.routes.last.request.originRef, first.originRef);
      expect(f.routes.last.request.calculationId, first.calculationId);
    },
  );
  test(
    'actual plan trace needs direction, distinct fixes, time and forward movement; no initial route',
    () {
      final f = RouteFixture();
      addTearDown(f.dispose);
      var joins = 0, calls = 0, time = 0;
      final c = FollowRouteController(
        load: (_, __, ___) {
          calls++;
          throw StateError('schema 1 must not run');
        },
        canChange: () => true,
        onJoined: (_, __, ___) {
          joins++;
        },
        onDeparted: (_, __) {},
        onInvalidated: () {},
        now: () => time,
      );
      addTearDown(c.dispose);
      final trace = [for (var i = 0; i < 30; i++) testFix(i * 10, seq: i)];
      for (var i = 0; i < 6; i++) {
        time = i * 1000;
        final self = testFix(i * 6, handle: 'self', seq: i, speed: 6);
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
            trace: trace,
            consent: true,
            connected: true,
            planTrace: const PlanTraceContext(
              'plan-1',
              1,
              RouteAnchor.sample(SampleRef('0123456789abcdef', 0)),
            ),
          ),
        );
      }
      expect(calls, 0);
      expect(joins, 1);
      expect(c.state!.mode, FollowMode.meetingPoint);
      expect(c.state!.phase, FollowPhase.onTrace);
    },
  );
}
