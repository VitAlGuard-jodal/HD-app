import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/models.dart';

import 'support/follow_route_fakes.dart';

void main() {
  test('only an omitted vehicle accuracy gets the assumed jump allowance', () {
    for (final src in [null, 'vehicle']) {
      for (final acc in <double?>[
        null,
        0,
        25,
        25.01,
        -1,
        double.nan,
        double.infinity,
      ]) {
        final fix = testFix(0, src: src, acc: acc);
        final accepted = acc == null
            ? src == 'vehicle'
            : acc.isFinite && acc >= 0 && acc <= 25;
        expect(routeQuality(fix), accepted, reason: 'src=$src acc=$acc');
        expect(routeAccuracyAllowance(fix), accepted ? acc ?? 25 : null);
        expect(
          fix.acc,
          acc == null
              ? isNull
              : acc.isNaN
              ? isNaN
              : acc,
        );
      }
    }
    expect(routeQuality(testFix(0, src: 'unknown', acc: null)), isFalse);
    expect(
      routeQuality(testFix(0, y: double.infinity, src: 'vehicle', acc: null)),
      isFalse,
    );
  });
  test(
    'vehicle and mixed traces keep jump, sequence, stream and time guards',
    () {
      final start = testFix(0, src: 'vehicle', acc: null);
      // At 1 s: 70 m travel + 25 m assumed allowance for each vehicle fix.
      expect(
        traceContinuous(start, testFix(119, seq: 1, src: 'vehicle', acc: null)),
        isTrue,
      );
      expect(
        traceContinuous(start, testFix(121, seq: 1, src: 'vehicle', acc: null)),
        isFalse,
      );
      // A reported 2 m accuracy keeps its own allowance, even with src=vehicle.
      expect(
        traceContinuous(start, testFix(98, seq: 1, src: 'vehicle', acc: 2)),
        isFalse,
      );
      expect(traceContinuous(start, testFix(96, seq: 1)), isTrue);
      for (final next in [
        testFix(10, seq: 2, src: 'vehicle', acc: null),
        testFix(10, seq: 1, at: routeEpoch, src: 'vehicle', acc: null),
        testFix(
          10,
          seq: 1,
          stream: 'fedcba9876543210',
          src: 'vehicle',
          acc: null,
        ),
        testFix(10, seq: 1, src: 'vehicle', acc: 26),
        testFix(10, seq: 1, acc: null),
      ]) {
        expect(traceContinuous(start, next), isFalse);
        expect(
          splitFollowTrace([
            start,
            next,
          ]).every((path) => path.points.length == 1),
          isTrue,
        );
      }
      final parkedGap = testFix(
        10,
        seq: 1,
        at: routeEpoch + 10001,
        src: 'vehicle',
        acc: null,
      );
      expect(traceContinuous(start, parkedGap), isFalse);
      expect(splitFollowTrace([start, parkedGap]), hasLength(1));
    },
  );
  test(
    'G1 empty, singleton and duplicate coordinates have no direction or B candidate',
    () {
      for (final fixes in <List<LocationFix>>[
        [],
        [testFix(0)],
        [testFix(0), testFix(0, seq: 1)],
      ]) {
        final paths = splitFollowTrace(fixes);
        expect(selectJoinCandidate(testPoint(0), paths), isNull);
        for (final path in paths) {
          expect(projectRoute(testPoint(0), path.points), isNull);
        }
      }
    },
  );
  test('G2 long segment projection and exact 25 m boundary', () {
    final projected = projectRoute(testPoint(50, 25), [
      testPoint(0),
      testPoint(100),
    ])!;
    expect(projected.distance, closeTo(25, .00001));
    expect(projected.along, closeTo(50, .00001));
    expect(projected.fraction, closeTo(.5, .00001));
  });
  test('G4 heading wraps at north and includes sixty degrees', () {
    expect(routeDirectionDifference(359, 1), 2);
    expect(routeDirectionDifference(30, 330), 60);
    expect(routeDirectionDifference(90, 270), 180);
  });
  test(
    'G5 repeated crossing is ambiguous, progress restricts the chosen visit',
    () {
      final points = [
        testPoint(0),
        testPoint(100),
        testPoint(100, 100),
        testPoint(0, 100),
        testPoint(0),
        testPoint(100),
      ];
      expect(projectRoute(testPoint(20), points)!.ambiguous, isTrue);
      final selected = projectRoute(
        testPoint(20),
        points,
        minimum: 400,
        maximum: 500,
      )!;
      expect(selected.ambiguous, isFalse);
      expect(selected.along, closeTo(420, .01));
    },
  );
  test('G5 close parallel visits do not select a convenient branch', () {
    final points = [
      testPoint(0),
      testPoint(100),
      testPoint(100, 8),
      testPoint(0, 8),
    ];
    expect(projectRoute(testPoint(50, 4), points)!.ambiguous, isTrue);
  });
  for (final next in [
    testFix(10, seq: 2),
    testFix(10, seq: 1, at: routeEpoch),
    testFix(10, seq: 1, at: routeEpoch + 10001),
    testFix(500, seq: 1),
    testFix(10, seq: 1, stream: 'fedcba9876543210'),
    testFix(10, seq: 1, acc: null),
    testFix(10, seq: 1, acc: -1),
    testFix(10, seq: 1, acc: 25.01),
  ]) {
    test(
      'G6/G7 discontinuity ${next.seq}/${next.at}/${next.stream}/${next.acc}',
      () {
        final paths = splitFollowTrace([testFix(0), next]);
        expect(paths.every((path) => path.points.length == 1), isTrue);
      },
    );
  }
  test(
    'G8 interpolates sixty metres forward, caps at end, excludes past progress',
    () {
      final paths = splitFollowTrace([
        testFix(0),
        testFix(100, seq: 1, at: routeEpoch + 2000),
        testFix(200, seq: 2, at: routeEpoch + 4000),
      ]);
      final join = selectJoinCandidate(testPoint(20, 30), paths)!;
      expect(join.anchor.end, SampleRef.of(testFix(100, seq: 1)));
      expect(join.anchor.fraction, closeTo(.8, .00001));
      expect(routeDistance(join.point, testPoint(80)), lessThan(.001));
      final end = selectJoinCandidate(testPoint(190), paths)!;
      expect(end.anchor.fraction, 1);
      final ahead = selectJoinCandidate(
        testPoint(0),
        paths,
        progress: RouteAnchor.segment(
          SampleRef.of(testFix(100, seq: 1)),
          SampleRef.of(testFix(200, seq: 2)),
          .5,
        ),
      )!;
      expect(routeDistance(ahead.point, testPoint(200)), lessThan(.001));
    },
  );
  test(
    'C7 reference survives a 7200 point window shift; lost reference is explicit',
    () {
      final all = [
        for (var i = 0; i <= 7200; i++) testFix(i.toDouble(), seq: i),
      ];
      final progress = RouteAnchor.segment(
        SampleRef.of(all[7190]),
        SampleRef.of(all[7191]),
        .5,
      );
      final before = splitFollowTrace(all.take(7200).toList()).single;
      final after = splitFollowTrace(all.skip(1).toList()).single;
      expect(
        before.resolve(progress)! - after.resolve(progress)!,
        closeTo(1, .001),
      );
      expect(
        after.resolve(RouteAnchor.sample(SampleRef.of(all.first))),
        isNull,
      );
    },
  );
  test(
    'L4 remote snapshot age uses server clock; duplicate and repeated at cannot refresh',
    () {
      var now = 0;
      final clock = FollowLocationClock(() => now);
      final fix = testFix(0);
      clock.observe(fix, routeEpoch + 9000);
      expect(clock.age(fix), 9000);
      now = 2000;
      clock.observe(fix, routeEpoch + 11000);
      expect(clock.age(fix), 11000);
      final repeated = testFix(0, seq: 1, at: routeEpoch);
      clock.observe(repeated, routeEpoch + 11000);
      expect(clock.age(repeated), double.infinity);
      clock.observe(testFix(10, seq: 2), routeEpoch + 2000);
      expect(clock.age(testFix(10, seq: 2)), 0);
    },
  );
  test('L4 missing server time and future measurement are held', () {
    final clock = FollowLocationClock(() => 0);
    clock.observe(testFix(0), null);
    expect(clock.age(testFix(0)), double.infinity);
    clock.observe(testFix(1, seq: 1), routeEpoch);
    expect(clock.age(testFix(1, seq: 1)), double.infinity);
  });
}
