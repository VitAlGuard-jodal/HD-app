import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/meeting_plan.dart';
import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

void main() {
  test('r12 trace handoff starts at the completed approach endpoint', () async {
    final f = RouteFixture();
    addTearDown(f.dispose);
    const request = PlanRouteRequest(
      planId: 'plan-1',
      planRevision: 1,
      followRequestId: 'follow-1',
      guidanceGeneration: 1,
      calculationId: 'approach',
      requestId: 'approach-1',
      routeKind: PlanRouteKind.planJoin,
      originRef: SampleRef('0123456789abcdef', 0),
    );
    final call = PlanRouteCall(
      request,
      RouteCancellation(),
      testPoint(-50),
      testPoint(0),
    );
    call.succeed(
      points: [
        testPoint(-50),
        testPoint(40),
        testPoint(-50, 4),
        testPoint(200, 4),
        testPoint(200, 100),
        testPoint(0, 100),
        testPoint(0),
      ],
    );
    final approach = await call.pending.future;
    final trace = [for (var n = 0; n <= 50; n++) testFix(n * 10, seq: n)];
    for (var n = 0; n < 5; n++) {
      f.time += 1000;
      final fix = testFix(
        n * 6,
        handle: 'self',
        seq: n,
        at: routeEpoch + f.time,
        speed: 6,
      );
      f.controller.update(
        FollowRouteInput(
          room: 'ROOM',
          account: 'self',
          device: 'device',
          relationship: 'follow-1',
          target: 'leader',
          self: fix,
          origin: fix,
          leader: trace.last,
          selfAgeMs: 0,
          originAgeMs: 0,
          leaderAgeMs: 0,
          trace: trace,
          consent: true,
          connected: true,
          planApproachRoute: approach,
          planTrace: const PlanTraceContext(
            'plan-1',
            1,
            RouteAnchor.sample(SampleRef('0123456789abcdef', 0)),
          ),
        ),
      );
    }
    expect(f.joins, hasLength(1));
    expect(f.state.phase, FollowPhase.onTrace);
    expect(f.calls, isEmpty);
  });

  test(
    'r12 route diagnostics expose only projection metrics in debug builds',
    () async {
      final previous = debugPrint;
      final logs = <String>[];
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = previous);
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.routes.single.succeed(
        points: [testPoint(0), testPoint(200), testPoint(0, 4), testPoint(100)],
      );
      await flush();
      expect(
        logs,
        kDebugMode
            ? [
                'follow-guidance: projection=planJoin/full ambiguous=true distance=0.0 along=0.0 candidates=3',
                'follow-guidance: projection=planJoin/window ambiguous=false distance=0.0 along=0.0 candidates=1',
              ]
            : isEmpty,
      );
    },
  );

  for (final owner in [false, true]) {
    for (final destination in [false, true]) {
      if (!owner && !destination)
        continue; // Covered by the original repro below.
      test(
        'r12 ${owner ? 'owner' : 'follower'} ${destination ? 'D' : 'J'} route retains a parked origin revisit',
        () async {
          final f = owner
              ? MeetingFixture(
                  account: 'leader',
                  target: null,
                  relationship: null,
                )
              : MeetingFixture();
          addTearDown(f.dispose);
          f.stop();
          final plan = planJson(join: destination ? 1000 : 100);
          if (owner) {
            f.controller.applyPlan(
              snapshot(
                plan: plan,
                runtime: runtimeJson(follower: 'follower'),
              ),
            );
            await f.controller.selectOwnGuidance();
          } else {
            await f.enroll(plan: plan);
          }
          final call = f.routes.single;
          final points = [
            testPoint(0),
            testPoint(200),
            testPoint(0, 4),
            call.goal,
          ];
          call.succeed(points: points);
          await flush();
          for (var n = 0; n < 6; n++) f.drive(0);
          expect(f.controller.view!.connector, points);
          expect(
            f.controller.status,
            destination ? (owner ? '목적지로 이동' : '목적지로 먼저 이동') : '합류 지점으로 이동',
          );
          expect(
            call.request.routeKind,
            destination
                ? PlanRouteKind.planDestination
                : PlanRouteKind.planJoin,
          );
          expect(f.routes, hasLength(1));
          expect(
            f.calls.where((c) => c.path.endsWith('/pass-evidence')),
            isEmpty,
          );
        },
      );
    }
  }

  test(
    'r12 a delayed result cannot snap a parked car to a distant later leg',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.drive(0, y: 100, elapsed: 2000, speed: 0);
      f.routes.single.succeed(
        points: [
          testPoint(0),
          testPoint(200),
          testPoint(200, 200),
          testPoint(0, 200),
          testPoint(0, 100),
          testPoint(100),
        ],
      );
      await flush();
      for (var n = 0; n < 35; n++) {
        f.drive(0, y: 100, speed: 0);
        expect(f.controller.status, contains('현재 위치에서 경로를 확인'));
        expect(f.controller.view!.connector, isEmpty);
      }
      expect(f.routes, hasLength(1));
      expect(f.calls.where((c) => c.path.endsWith('/pass-evidence')), isEmpty);
    },
  );

  test(
    'r12 proceed uses the later visit only after driving the loop',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(plan: planJson(policy: 'proceed'));
      f.routes.single.succeed(
        points: [
          testPoint(0),
          testPoint(200),
          testPoint(200, 100),
          testPoint(0, 100),
          testPoint(0, 4),
          testPoint(100),
        ],
      );
      await flush();
      final evidence = f.calls.where((c) => c.path.endsWith('/pass-evidence'));
      for (var x = 20.0; x <= 200; x += 20) f.drive(x, speed: 20);
      expect(
        evidence,
        isEmpty,
        reason: 'the first visit to J is not the route endpoint',
      );
      for (var y = 20.0; y <= 100; y += 20) f.drive(200, y: y, speed: 20);
      for (var x = 180.0; x >= 0; x -= 20) f.drive(x, y: 100, speed: 20);
      for (var y = 80.0; y >= 20; y -= 20) f.drive(0, y: y, speed: 20);
      f.drive(0, y: 4, speed: 20);
      expect(evidence, isEmpty);
      for (var x = 20.0; x <= 100; x += 20)
        f.drive(x, y: 4 * (1 - x / 100), speed: 20);
      expect(evidence, hasLength(1));
      expect(f.routes, hasLength(1));
      expect(f.controller.ownRuntime!.branch, 'pending');
    },
  );

  test('r12 parked follower keeps a route that revisits its origin', () async {
    final f = MeetingFixture();
    addTearDown(f.dispose);
    f.stop();
    await f.enroll();
    final points = [
      testPoint(0),
      testPoint(200),
      testPoint(0, 4),
      testPoint(100),
    ];
    f.routes.single.succeed(points: points);
    await flush();
    expect(f.controller.view!.connector, points);
    expect(f.controller.status, '합류 지점으로 이동');
    for (var n = 0; n < 6; n++) f.drive(0);
    expect(f.controller.view!.connector, points);
    expect(f.controller.status, '합류 지점으로 이동');
    expect(f.routes, hasLength(1));
    expect(f.calls.where((c) => c.path.endsWith('/pass-evidence')), isEmpty);
  });

  test(
    'r12 overlapping visits inside the window explain the hold while parked',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.routes.single.succeed(
        points: [testPoint(0), testPoint(50), testPoint(0, 4), testPoint(100)],
      );
      await flush();
      expect(f.controller.view!.connector, isEmpty);
      expect(f.controller.status, contains('경로가 겹쳐'));
      for (var n = 0; n < 35; n++) f.drive(0);
      expect(f.controller.status, contains('경로가 겹쳐'));
      expect(f.routes, hasLength(1));
      expect(f.calls.where((c) => c.path.endsWith('/pass-evidence')), isEmpty);
      f.drive(20, speed: 20);
      f.drive(40, speed: 20);
      expect(f.controller.view!.connector, isNotEmpty);
      expect(f.controller.status, '합류 지점으로 이동');
      expect(f.routes, hasLength(1));
    },
  );

  test(
    'r14 stopping after confirmed departure preserves the off-route message',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.routes.single.succeed();
      await flush();
      for (var n = 0; n < 7; n++) f.drive(10.0 + n * 3, y: 80, speed: 3);
      expect(f.controller.status, '경로를 벗어났습니다');
      for (var n = 0; n < 35; n++) {
        f.drive(28, y: 80, speed: 0);
        expect(f.controller.view!.condition, FollowRouteCondition.offRoute);
      }
      expect(f.controller.status, '경로를 벗어났습니다');
      expect(f.routes, hasLength(1));
      for (var n = 1; n <= 6; n++) f.drive(28.0 + n * 3, y: 80, speed: 3);
      expect(f.routes, hasLength(2));
    },
  );

  test(
    'r11 B8 repeated timer and SSE observations cannot move the first upload observation',
    () {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      // LocationShare notifies RoomSession synchronously at each accepted upload.
      // Later timer/SSE/UI updates of that same ref must not become new receipts.
      for (var n = 0; n < 3; n++) {
        f.age = 200;
        f.drive(0, elapsed: 5000);
        f.age = 9000;
        f.update();
      }
      expect(f.controller.canEditMeetingPlan, isTrue);
      f.age = 10001;
      f.update();
      expect(f.controller.canEditMeetingPlan, isFalse);
    },
  );
  test(
    'r11 B8 compressed first receipts do not invent a two-second stop window',
    () {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.controller.update(null);
      for (final (seq, measured, age) in [
        (1, 0, 9000.0),
        (2, 5000, 4500.0),
        (3, 10000, 0.0),
      ]) {
        f.self = testFix(
          0,
          handle: 'self',
          seq: seq,
          at: routeEpoch + measured,
          speed: 0,
        );
        f.age = age;
        f.update();
      }
      f.controller.applySnapshot([], [follower], planFeatures);
      expect(f.controller.canEditMeetingPlan, isFalse);
    },
  );
  test(
    'r11 A1 D route keeps the building pin and stops at the actual road endpoint',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll(
        plan: planJson(join: 1000),
        runtime: runtimeJson(
          followerPhase: 'toDestination',
          branch: 'destination',
        ),
      );
      final call = f.routes.single;
      final j = call.json;
      final end = {'lat': testPoint(940).lat, 'lng': testPoint(940).lng};
      j['points'] = [j['points'].first, end];
      j['actualEnd'] = end;
      j['endGapMeters'] = 60;
      call.pending.complete(call.request.parseResult(j));
      await flush();
      expect(f.controller.view!.connector.last, testPoint(940));
      expect(
        f.controller.pins.firstWhere((p) => p.id == 'destination').point,
        testPoint(1000),
      );
      expect(f.controller.view!.connector, isNot(contains(testPoint(1000))));
      expect(meetingErrorText('ENDPOINT_MISMATCH'), contains('도로'));
      expect(meetingErrorText('NO_ROUTE'), contains('경로'));
    },
  );
  test('r10 stop evidence rejects a window longer than 15 seconds', () {
    final f = MeetingFixture();
    addTearDown(f.dispose);
    for (var i = 0; i < 3; i++) f.drive(0, elapsed: 8000);
    expect(f.controller.canEditMeetingPlan, isFalse);
    expect(f.controller.beginEditing(), isFalse);
    f.drive(0, elapsed: 5000);
    expect(f.controller.canEditMeetingPlan, isTrue);
  });

  test(
    'r10 stop evidence includes all continuous fixes needed to span 2 seconds',
    () {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      for (var i = 0; i < 5; i++) f.drive(0, elapsed: 400);
      expect(f.controller.canEditMeetingPlan, isTrue);
    },
  );

  test(
    'r10 5-second parked uploads keep editing available between uploads',
    () {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.age = 200;
      for (var i = 0; i < 3; i++) f.drive(0, elapsed: 5000);
      expect(f.controller.canEditMeetingPlan, isTrue);
      f.time += 4999;
      f.age += 4999;
      f.update();
      expect(f.controller.canEditMeetingPlan, isTrue);
      f.age = 10001;
      f.update();
      expect(f.controller.canEditMeetingPlan, isFalse);
    },
  );

  test(
    'r10 wait arrival display and preparation follow server runtime at parked cadence',
    () async {
      final f = MeetingFixture(
        account: 'leader',
        target: null,
        relationship: null,
      );
      addTearDown(f.dispose);
      for (var i = 0; i < 3; i++) f.drive(0, elapsed: 5000);
      f.controller.applyPlan(
        snapshot(runtime: runtimeJson(follower: 'follower')),
      );
      await f.controller.selectOwnGuidance();
      f.routes.single.succeed();
      await flush();
      for (var i = 0; i < 3; i++) f.drive(100, elapsed: 5000);
      // Local proximity/stop evidence never invents arrival, passage or a trace.
      expect(f.controller.ownRuntime!.phase, 'toJoin');
      expect(f.controller.canDepart, isFalse);
      expect(f.calls.where((c) => c.path.endsWith('/pass-evidence')), isEmpty);
      final waiting = MeetingRuntime.fromJson(
        runtimeJson(
          runtimeRevision: 2,
          follower: 'follower',
          leaderPhase: 'atJoinWaiting',
          followerPhase: 'atJoinWaiting',
        ),
      );
      f.controller.applyRuntime(waiting);
      expect(f.controller.status, contains('대기'));
      expect(f.controller.canDepart, isTrue);
      expect(f.controller.traceContext, isNull);
      final notices = f.notices.length;
      f.time += 4999;
      f.age = 4999;
      f.update();
      f.controller.applyRuntime(waiting);
      expect(f.controller.canDepart, isTrue);
      expect(f.notices, hasLength(notices));
      final departure = f.controller.depart();
      final call = f.calls.last;
      expect(call.path, endsWith('/depart'));
      expect(call.body!['expectedRuntimeRevision'], 2);
      call.complete({
        'runtime': runtimeJson(
          runtimeRevision: 3,
          follower: 'follower',
          leaderPhase: 'atJoinWaiting',
          followerPhase: 'atJoinWaiting',
          announced: routeEpoch + f.time,
        ),
      });
      await departure;
      expect(f.controller.status, '출발 준비');
      expect(f.controller.traceContext, isNull);
    },
  );

  for (final owner in [false, true]) {
    test(
      'r8 approach ETA reports once for ${owner ? 'leader' : 'follower'}',
      () async {
        final f = owner
            ? MeetingFixture(
                account: 'leader',
                target: null,
                relationship: null,
              )
            : MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        if (owner) {
          f.controller.applyPlan(snapshot());
          await f.controller.selectOwnGuidance();
        } else {
          await f.enroll();
        }
        f.routes.single.succeed();
        await flush();
        final reports = f.calls.where(
          (c) => c.path.endsWith('/guidance-status'),
        );
        expect(reports, hasLength(1));
        final report = reports.single;
        expect(report.method, 'PUT');
        expect(report.body, {
          'planId': 'plan-1',
          'revision': 1,
          'followRequestId': owner ? null : 'follow-1',
          'originRef': SampleRef.of(f.self!).toJson(),
          'stage': 'toJoin',
          'etaSeconds': 12.345,
          'calculatedAtMs': routeEpoch,
        });
        report.complete({});
        await flush();
        for (var n = 0; n < 30; n++) f.drive(0);
        expect(reports, hasLength(1));
        expect(f.routes, hasLength(1));
        expect(f.controller.etaText, contains('계산 당시 약 1분'));
        expect(f.controller.ownRuntime!.phase, 'toJoin');
        expect(f.controller.ownRuntime!.branch, 'pending');
        // The server calculation clock, not receipt time, defines the 60 s TTL.
        f.time = 60000;
        f.update();
        expect(f.controller.etaText, '예상 시간 갱신 필요');
      },
    );
  }

  test(
    'r8 group ETA expires visibly and is hidden on delay or arrival',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      PlanVehicle vehicle({
        String phase = 'toJoin',
        String? condition,
        double? seconds = 120,
      }) => PlanVehicle(
        handle: 'leader',
        followRequestId: null,
        phase: phase,
        branch: 'pending',
        condition: condition,
        reportedStage: 'toJoin',
        etaSeconds: seconds,
        calculatedAtMs: routeEpoch,
      );
      expect(f.controller.vehicleEtaText(vehicle()), contains('2분'));
      f.time = 30000;
      f.update();
      expect(f.controller.vehicleEtaText(vehicle()), contains('2분'));
      f.time = 60000;
      f.update();
      expect(
        f.controller.vehicleEtaText(vehicle(seconds: null)),
        '예상 시간 갱신 필요',
      );
      expect(
        f.controller.vehicleEtaText(vehicle(condition: 'locationDelayed')),
        isNull,
      );
      expect(
        f.controller.vehicleEtaText(vehicle(phase: 'atJoinWaiting')),
        isNull,
      );
      f.connected = false;
      f.update();
      expect(f.controller.vehicleEtaText(vehicle()), isNull);
    },
  );

  for (final invalidation in ['plan', 'device', 'arrival', 'consent']) {
    test(
      'r8 late approach result cannot report after $invalidation changes',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll();
        final route = f.routes.single;
        switch (invalidation) {
          case 'plan':
            f.controller.planCleared('plan-1', 'leader');
          case 'device':
            f.device = 'replacement';
            f.update();
          case 'arrival':
            f.controller.applyRuntime(
              MeetingRuntime.fromJson(
                runtimeJson(runtimeRevision: 2, followerPhase: 'atJoinWaiting'),
              ),
            );
          case 'consent':
            f.consent = false;
            f.update();
        }
        route.succeed();
        await flush();
        expect(
          f.calls.where((c) => c.path.endsWith('/guidance-status')),
          isEmpty,
        );
      },
    );
  }

  test(
    'r8 delayed location defers ETA report; failure never stops guidance or repeats routing',
    () async {
      final f = MeetingFixture();
      addTearDown(f.dispose);
      f.stop();
      await f.enroll();
      f.age = 10001;
      f.update();
      f.routes.single.succeed();
      await flush();
      final reports = f.calls.where((c) => c.path.endsWith('/guidance-status'));
      expect(reports, isEmpty);
      f.age = 0;
      f.drive(0);
      expect(reports, hasLength(1));
      expect(reports.single.body!['originRef'], SampleRef.of(f.self!).toJson());
      reports.single.pending.completeError(
        const FollowRouteException('NETWORK_ERROR'),
      );
      await flush();
      f.drive(0);
      expect(f.controller.view!.connector, isNotEmpty);
      expect(f.controller.ownRuntime!.phase, 'toJoin');
      expect(reports, hasLength(1));
      expect(f.routes, hasLength(1));
    },
  );

  test('r8 an ETA acknowledgement cannot restore a cleared plan', () async {
    final f = MeetingFixture();
    addTearDown(f.dispose);
    f.stop();
    await f.enroll();
    f.routes.single.succeed();
    await flush();
    final report = f.calls.last;
    expect(report.path, endsWith('/guidance-status'));
    f.controller.planCleared('plan-1', 'leader');
    expect(report.cancellation.isCancelled, isTrue);
    report.complete({'plan': planJson(), 'runtime': runtimeJson()});
    await flush();
    expect(f.controller.active, isNull);
  });

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
