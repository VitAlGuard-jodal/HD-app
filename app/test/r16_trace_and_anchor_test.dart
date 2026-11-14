import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/meeting_plan.dart';

import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

void acceptAtAnchor(PlanRouteCall call) {
  final json = call.json
    ..addAll({
      'result': 'atAnchor',
      'points': <Object>[],
      'meters': 0,
      'seconds': 0,
      'actualStart': null,
      'actualEnd': null,
      'startGapMeters': null,
      'endGapMeters': null,
    });
  call.pending.complete(call.request.parseResult(json));
}

void main() {
  for (final gap in [20000, 120000]) {
    test(
      'R16.1 parked $gap ms gap keeps the recorded trace but not motion evidence',
      () {
        final before = testFix(100, seq: 1);
        final after = testFix(104, seq: 2, at: before.at.toInt() + gap);
        final paths = splitFollowTrace([testFix(90), before, after]);
        expect(paths, hasLength(1));
        expect(paths.single.fixes, hasLength(3));
        expect(traceContinuous(before, after), isFalse);
      },
    );
  }

  test(
    'R16.1 moving gaps, missing refs and bad quality still split traces',
    () {
      final before = testFix(100, seq: 1);
      for (final after in [
        testFix(104.1, seq: 2, at: routeEpoch + 21000),
        testFix(100, seq: 2, at: routeEpoch + 121001),
        testFix(100, seq: 3, at: routeEpoch + 21000),
        testFix(100, seq: 2, at: routeEpoch + 21000, stream: 'f' * 16),
        testFix(100, seq: 2, at: routeEpoch + 21000, acc: 26),
        testFix(100, seq: 2, at: routeEpoch + 21000, acc: null),
      ]) {
        expect(
          splitFollowTrace([before, after]).every((p) => p.fixes.length == 1),
          isTrue,
        );
      }
    },
  );

  for (final policy in ['wait', 'proceed']) {
    test(
      'R16.4 $policy atAnchor shows near J without claiming a pass while parked',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll(
          plan: planJson(join: 0, destination: 1000, policy: policy),
        );
        acceptAtAnchor(f.routes.single);
        await flush();
        expect(f.controller.status, contains('합류 지점 근처'));
        for (var n = 0; n < 4; n++) f.drive(0, speed: 0);
        expect(
          f.calls.where((c) => c.path.endsWith('/pass-evidence')),
          isEmpty,
        );
        expect(f.routes, hasLength(1));
      },
    );
  }

  for (final speed in [2.0, 3.0, 10.0]) {
    test(
      'R16.4 atAnchor departure reports only after leaving J with moving evidence ($speed)',
      () async {
        final f = MeetingFixture();
        addTearDown(f.dispose);
        f.stop();
        await f.enroll(
          plan: planJson(join: 0, destination: 1000, policy: 'proceed'),
        );
        acceptAtAnchor(f.routes.single);
        await flush();
        final start = f.self!;
        final passes = f.calls.where((c) => c.path.endsWith('/pass-evidence'));
        for (var x = speed; x <= 30; x += speed) {
          f.drive(x, speed: speed);
          if (x <= 25) expect(passes, isEmpty);
        }
        expect(passes, hasLength(1));
        final refs = passes.single.body!['ownRefs'] as List;
        expect(refs.first['stream'], start.stream);
        expect(refs.first['seq'], greaterThanOrEqualTo(start.seq));
        final first = f.controller.ownSamples.firstWhere(
          (s) => s.seq == refs.first['seq'],
        );
        expect(
          routeDistance(RoutePoint.fromFix(first), testPoint(0)),
          lessThanOrEqualTo(25),
        );
        expect(refs.last['seq'], greaterThanOrEqualTo(start.seq + 3));
        passes.single.complete({
          'runtime': runtimeJson(
            runtimeRevision: 2,
            followerPhase: 'toDestination',
            branch: 'destination',
          ),
        });
        await flush();
        expect(f.routes, hasLength(2));
        expect(f.routes.last.request.routeKind, PlanRouteKind.planDestination);
      },
    );
  }

  test(
    'R16.4 P0 atAnchor already waits near the reference without a false join',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(10);
      f.trace = [f.leader!];
      f.update();
      f.calls.single.succeed(atAnchor: true);
      await flush();
      expect(f.state.condition, FollowRouteCondition.atAnchorWaitingTrace);
      expect(f.state.status, contains('기준 지점 근처'));
      expect(f.joins, isEmpty);
    },
  );
}
