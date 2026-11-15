import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/models.dart';

import 'support/follow_route_fakes.dart';

List<LocationFix> parkedExit({bool spike = false}) {
  final last = spike ? 14 : 12;
  return [
    testFix(160),
    for (var n = 1; n <= 12; n++)
      testFix(n.isOdd ? 162 : 158, seq: n, at: routeEpoch + n * 5000, speed: 0),
    if (spike) ...[
      testFix(160, y: 12, seq: 13, at: routeEpoch + 65000, speed: 0),
      testFix(160, seq: 14, at: routeEpoch + 70000, speed: 0),
    ],
    for (var n = 1; n <= 50; n++)
      testFix(
        160 + n * 10,
        seq: last + n,
        at: routeEpoch + last * 5000 + n * 1000,
        speed: 10,
      ),
  ];
}

Future<RouteFixture> scenario({
  List<LocationFix>? trace,
  List<RoutePoint>? road,
  double x = 0,
  double y = 0,
}) async {
  final f = RouteFixture();
  addTearDown(f.dispose);
  f.self = testFix(x, y: y, handle: 'self', speed: 0);
  f.leader = testFix(160);
  f.trace = [f.leader!];
  f.update();
  f.calls.single.succeed(points: road);
  await flush();
  f.trace =
      trace ?? [for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n)];
  f.leader = f.trace.last;
  f.update();
  return f;
}

void approachP0(RouteFixture f) {
  for (var x = 20.0; x <= 140; x += 20) f.drive(x, speed: 20);
  expect(f.state.anchorReached, isTrue);
  expect(f.joins, isEmpty);
}

void main() {
  for (final loop in [true, false]) {
    test(
      'R21e.1 measured P0 passage joins despite ${loop ? 'a loop' : 'opposite arrival'}',
      () async {
        final f = await scenario(
          road: loop
              ? [
                  testPoint(0),
                  testPoint(200),
                  testPoint(200, 100),
                  testPoint(0, 100),
                  testPoint(0),
                  testPoint(160),
                ]
              : [
                  testPoint(0),
                  testPoint(0, 100),
                  testPoint(300, 100),
                  testPoint(300),
                  testPoint(160),
                ],
        );
        approachP0(f);
        f.drive(160, speed: 20);
        expect(f.joins, isEmpty);
        f.drive(180, speed: 20);
        expect(f.rejoinedEvents, [false]);
        expect(f.departures, isEmpty);
        expect(f.calls, hasLength(1));
      },
    );
  }

  for (final spike in [false, true]) {
    test(
      'R21e.2 parked jitter and a right-angle pass use an internal exit (spike=$spike)',
      () async {
        final trace = parkedExit(spike: spike);
        final f = await scenario(trace: trace, x: 160, y: 64);
        expect(f.state.anchor, RouteAnchor.sample(SampleRef.of(trace.first)));
        expect(
          f.state.activeTrace.single.first,
          RoutePoint.fromFix(trace[spike ? 14 : 12]),
        );
        f.drive(160, y: 44, speed: 20);
        f.drive(160, y: 24, speed: 20);
        expect(f.joins, isEmpty);
        for (final x in [180.0, 200.0, 220.0]) f.drive(x, y: 24, speed: 20);
        expect(f.rejoinedEvents, [false]);
        expect(f.departures, isEmpty);
      },
    );
  }

  for (final resume in [240.0, 340.0]) {
    test(
      'R21e.3 confirmed passage survives a location hold and resumes at $resume',
      () async {
        final f = await scenario();
        approachP0(f);
        f.time += 11000;
        f.selfAge = 11000;
        f.update();
        expect(f.state.condition, FollowRouteCondition.locationDelayed);
        f.selfAge = 0;
        f.drive(resume, speed: 20);
        for (final delta in [6.0, 12.0]) {
          f.drive(resume + delta, speed: 6);
          expect(
            f.joins,
            isEmpty,
            reason: 'hold clears fresh join samples, not passage',
          );
        }
        f.drive(resume + 18, speed: 6);
        expect(f.rejoinedEvents, [false]);
        expect(f.departures, isEmpty);
        expect(f.calls, hasLength(1));
      },
    );
  }

  for (final jump in [false, true]) {
    test(
      'R21e.3 confirmed passage survives one ${jump ? 'implausible jump' : '30 m offset'} beyond the initial window',
      () async {
        final f = await scenario();
        approachP0(f);
        for (final x in [170.0, 200.0, 230.0])
          f.drive(x, elapsed: 500, speed: 60);
        expect(f.joins, isEmpty);
        f.drive(jump ? 500 : 230, y: jump ? 400 : 30, elapsed: 500, speed: 60);
        expect(f.joins, isEmpty);
        f.drive(236, speed: 30);
        for (final x in [242.0, 248.0]) {
          f.drive(x, speed: 6);
          expect(f.joins, isEmpty);
        }
        f.drive(254, speed: 6);
        expect(f.rejoinedEvents, [false]);
        expect(f.departures, isEmpty);
      },
    );
  }

  for (final curved in [false, true]) {
    test(
      'R21e.4 a 1.4 m/s ${curved ? 'curved' : 'straight'} departure starts at the real P0',
      () async {
        final offsets = curved
            ? [
                testPoint(0),
                testPoint(1.4),
                testPoint(2.8),
                testPoint(4.2),
                testPoint(5.6),
                testPoint(5.6, 1.4),
                testPoint(4.2, 2.8),
                testPoint(4.2, 4.2),
                testPoint(4.2, 5.6),
                for (var n = 1; n <= 80; n++)
                  testPoint(4.2 + n * 1.4, 5.6 + n * 1.4),
              ]
            : [for (var n = 0; n <= 108; n++) testPoint(n * 1.4)];
        final trace = [
          for (var n = 0; n < offsets.length; n++)
            testFix(
              160 + offsets[n].lng * metersPerDegree,
              y: offsets[n].lat * metersPerDegree,
              seq: n,
              speed: 1.4,
            ),
        ];
        final f = await scenario(trace: trace);
        f.drive(140, speed: 20);
        f.drive(160, speed: 20);
        for (var n = 3; n <= 24; n += 3) {
          f.drive(
            160 + offsets[n].lng * metersPerDegree,
            y: offsets[n].lat * metersPerDegree,
            speed: 6,
          );
        }
        expect(f.state.anchor, RouteAnchor.sample(SampleRef.of(trace.first)));
        expect(f.rejoinedEvents, [false]);
        expect(f.departures, isEmpty);
        expect(f.calls, hasLength(1));
      },
    );
  }

  test(
    'R21e.3 one 30 m offset cannot consume the whole recovery window',
    () async {
      final f = await scenario();
      approachP0(f);
      // Only this sample is off the trace. Its later timestamp must not erase
      // the reachability interval since the last valid trace projection.
      f.drive(340, y: 30, elapsed: 10000, speed: 20);
      f.drive(346, speed: 30);
      for (final x in [352.0, 358.0]) {
        f.drive(x, speed: 6);
        expect(f.joins, isEmpty);
      }
      f.drive(364, speed: 6);
      expect(f.rejoinedEvents, [false]);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'R21e.3 one ambiguous trace projection does not erase confirmed passage',
    () async {
      final points = [
        for (var x = 160.0; x <= 300; x += 20) testPoint(x),
        testPoint(300, 8),
        for (var x = 280.0; x >= 200; x -= 20) testPoint(x, 8),
        for (var y = 28.0; y <= 108; y += 20) testPoint(200, y),
      ];
      final f = await scenario(
        trace: [
          for (var n = 0; n < points.length; n++)
            testFix(
              points[n].lng * metersPerDegree,
              y: points[n].lat * metersPerDegree,
              seq: n,
            ),
        ],
      );
      approachP0(f);
      f.drive(210, y: 4, elapsed: 3000, speed: 24);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
      f.drive(240, speed: 30);
      f.drive(246, speed: 6);
      expect(f.joins, isEmpty);
      f.drive(252, speed: 6);
      expect(f.rejoinedEvents, [false]);
      expect(f.departures, isEmpty);
    },
  );

  test(
    'R21e.5 reverse trace travel before visiting P0 still confirms departure',
    () async {
      final f = await scenario(
        x: 300,
        y: 80,
        road: [testPoint(300, 80), testPoint(160, 80), testPoint(160)],
      );
      f.drive(300, elapsed: 2000, speed: 40);
      for (var n = 1; n <= 12; n++) f.drive(300 - n * 6, speed: 6);
      expect(f.departures, hasLength(1));
      expect(f.state.rejoining, isTrue);
      expect(f.joins, isEmpty);
    },
  );

  test('R21e.6 reverse P0 passage is not arrival', () async {
    final f = await scenario(x: 220);
    for (final x in [200.0, 180.0, 160.0, 140.0]) f.drive(x, speed: 20);
    expect(f.state.anchorReached, isFalse);
    expect(f.joins, isEmpty);
  });

  test(
    'R21e.6 matching trace direction without visiting P0 is not arrival',
    () async {
      final f = await scenario(x: 220, y: 24);
      for (final x in [240.0, 260.0, 280.0, 300.0])
        f.drive(x, y: 24, speed: 20);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
    },
  );

  test(
    'R21e.7 exit judgement is cached while the request and marker stay at P0',
    () async {
      final trace = parkedExit();
      final f = await scenario(trace: trace);
      final anchor = RouteAnchor.sample(SampleRef.of(trace.first));
      expect(
        f.calls.single.request.anchor,
        RouteAnchor.sample(SampleRef.of(trace.first)),
      );
      expect(f.state.anchor, anchor);
      expect(f.state.activeTrace.single.first, testPoint(158));
      final rendered = f.state.activeTrace;
      for (var n = 0; n < 5; n++) f.drive(0, speed: 0);
      expect(f.state.activeTrace, same(rendered));
      f.trace = [
        ...trace,
        testFix(
          670,
          seq: trace.last.seq + 1,
          at: trace.last.at.toInt() + 1000,
          speed: 10,
        ),
      ];
      f.leader = f.trace.last;
      f.update();
      expect(f.state.anchor, anchor);
      expect(f.state.anchorPoint, testPoint(160));
      expect(f.state.activeTrace.single.first, testPoint(158));
      expect(f.calls, hasLength(1));
    },
  );
}
