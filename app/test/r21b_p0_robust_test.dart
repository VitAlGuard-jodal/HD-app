import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/net/models.dart';

import 'support/follow_route_fakes.dart';

Future<RouteFixture> p0Approach({
  double x = 0,
  double y = 0,
  bool atAnchor = false,
  List<LocationFix>? seed,
  List<RoutePoint>? road,
}) async {
  final f = RouteFixture();
  addTearDown(f.dispose);
  f.self = testFix(x, y: y, handle: 'self', speed: 0);
  f.trace = seed ?? [testFix(160)];
  f.leader = f.trace.last;
  f.update();
  f.calls.single.succeed(points: road, atAnchor: atAnchor);
  await flush();
  f.update();
  return f;
}

void main() {
  test('R21b.1 parked leader jitter is not the P0 exit direction', () async {
    final f = await p0Approach();
    f.trace = [
      testFix(160),
      testFix(160, y: 2, seq: 1, at: routeEpoch + 5000, speed: 0),
      for (var n = 1; n <= 50; n++)
        testFix(160 + n * 10, seq: n + 1, at: routeEpoch + (9 + n) * 1000),
    ];
    f.leader = f.trace.last;
    f.update();
    for (var x = 20.0; x <= 140; x += 20) f.drive(x, speed: 20);
    expect(f.state.anchorReached, isTrue);
    for (final x in [160.0, 180.0, 186.0, 192.0]) f.drive(x, speed: 20);
    expect(f.state.phase, FollowPhase.onTrace);
    expect(f.departures, isEmpty);
    expect(f.calls, hasLength(1));
  });

  test(
    'R21b.1 following parked jitter cannot confirm a wrong P0 direction',
    () async {
      final f = await p0Approach(x: 160, y: -40);
      f.trace = [
        testFix(160),
        testFix(160, y: 2, seq: 1, at: routeEpoch + 5000, speed: 0),
        for (var n = 1; n <= 50; n++)
          testFix(160 + n * 10, seq: n + 1, at: routeEpoch + (9 + n) * 1000),
      ];
      f.leader = f.trace.last;
      f.update();
      for (final y in [-20.0, 0.0, 6.0, 12.0, 18.0, 24.0, 26.0]) {
        f.drive(160, y: y, speed: 6);
        expect(f.state.anchorReached, isFalse);
      }
      expect(f.joins, isEmpty);
    },
  );

  test(
    'R21b.2 a 20 m/s turn can confirm direction just beyond the P0 radius',
    () async {
      final f = await p0Approach(x: 160, y: 64);
      f.trace = [for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n)];
      f.leader = f.trace.last;
      f.update();
      // A 24 m lateral offset leaves one fix inside P0's 25 m radius. Its
      // measured direction is still the incoming leg of the right-angle turn.
      f.drive(160, y: 44, speed: 20);
      f.drive(160, y: 24, speed: 20);
      expect(f.state.anchorReached, isFalse);
      for (final x in [180.0, 200.0, 220.0]) f.drive(x, y: 24, speed: 20);
      expect(f.state.phase, FollowPhase.onTrace);
      expect(f.rejoinedEvents, [false]);
      expect(f.departures, isEmpty);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'R21b.3 legacy atAnchor arrival needs direction when an exit trace appears',
    () async {
      final f = await p0Approach(
        x: 160,
        atAnchor: true,
        seed: [testFix(150), testFix(160, seq: 1)],
      );
      expect(f.state.anchorReached, isTrue, reason: 'legacy waiting at P0');
      f.trace = [
        testFix(150),
        for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n + 1),
      ];
      f.leader = f.trace.last;
      f.drive(160, speed: 0);
      expect(
        f.state.anchorReached,
        isFalse,
        reason: 'no outgoing direction was measured',
      );
      f.drive(140, speed: 20);
      expect(
        f.state.anchorReached,
        isFalse,
        reason: 'wrong direction remains unconfirmed',
      );
      expect(f.joins, isEmpty);
      for (final x in [150.0, 160.0, 170.0, 180.0]) f.drive(x, speed: 10);
      expect(f.rejoinedEvents, [false]);
    },
  );

  for (final distance in [9.99, 10.0]) {
    test('R21b.1 the exit direction needs 10 m from P0 ($distance)', () async {
      final f = await p0Approach(
        road: [
          testPoint(0),
          testPoint(200),
          testPoint(200, 100),
          testPoint(0, 100),
          testPoint(0),
          testPoint(160),
        ],
      );
      f.trace = [testFix(160), testFix(160 + distance, seq: 1)];
      f.leader = f.trace.last;
      f.update();
      for (var x = 20.0; x <= 140; x += 20) f.drive(x, speed: 20);
      expect(
        f.state.anchorReached,
        isFalse,
        reason: 'one point cannot prove departure',
      );
      f.trace = [...f.trace, testFix(163 + distance, seq: 2)];
      f.leader = f.trace.last;
      f.drive(143, speed: 3);
      expect(f.state.anchorReached, distance == 10);
      expect(f.joins, isEmpty);
    });
  }

  test(
    'R21b.1 accumulated parked jitter is not ten metres of departure',
    () async {
      final f = await p0Approach(
        x: 160,
        y: -40,
        road: [
          testPoint(160, -40),
          testPoint(260, -40),
          testPoint(260, 100),
          testPoint(160, 100),
          testPoint(160),
        ],
      );
      f.trace = [
        testFix(160),
        for (var n = 1; n <= 12; n++)
          testFix(
            160,
            y: n.isOdd ? 2 : -2,
            seq: n,
            at: routeEpoch + n * 5000,
            speed: 0,
          ),
      ];
      f.leader = f.trace.last;
      f.update();
      f.drive(160, y: -20, speed: 20);
      f.drive(160, speed: 20);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
    },
  );

  test(
    'R21b.2 deferred arrival uses the local trace direction after another turn',
    () async {
      final f = await p0Approach(x: 160, y: -44);
      f.trace = [
        testFix(160),
        testFix(170, seq: 1),
        testFix(180, seq: 2),
        for (var n = 1; n <= 50; n++) testFix(180, y: n * 10, seq: n + 2),
      ];
      f.leader = f.trace.last;
      f.update();
      f.drive(160, y: -24, speed: 20);
      expect(f.state.anchorReached, isFalse);
      f.drive(180, y: 20, elapsed: 3000, speed: 20);
      expect(f.state.anchorReached, isTrue);
      f.drive(180, y: 26, speed: 6);
      f.drive(180, y: 32, speed: 6);
      expect(f.rejoinedEvents, [false]);
    },
  );

  for (final along in [60.0, 60.01]) {
    test(
      'R21b.2 deferred direction is bounded to 60 m after P0 ($along)',
      () async {
        final f = await p0Approach(x: 160, y: 64);
        f.trace = [for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n)];
        f.leader = f.trace.last;
        f.update();
        f.drive(160, y: 44, speed: 20);
        f.drive(160, y: 24, speed: 20);
        expect(f.state.anchorReached, isFalse);
        f.drive(160 + along, y: 24, elapsed: 3000, speed: 20);
        expect(f.state.anchorReached, along == 60);
        expect(f.joins, isEmpty);
      },
    );
  }

  for (final distance in [25.0, 25.01]) {
    test(
      'R21b.2 deferred direction stays within 25 m of the trace ($distance)',
      () async {
        final f = await p0Approach(x: 160, y: 64);
        f.trace = [for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n)];
        f.leader = f.trace.last;
        f.update();
        f.drive(160, y: 44, speed: 20);
        f.drive(160, y: 24, speed: 20);
        f.drive(200, y: distance, elapsed: 2000, speed: 20);
        expect(f.state.anchorReached, distance == 25);
        expect(f.joins, isEmpty);
      },
    );
  }

  test(
    'R21b.2 alignment after P0 cannot replace a visit to its radius',
    () async {
      final f = await p0Approach(x: 160, y: 64);
      f.trace = [for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n)];
      f.leader = f.trace.last;
      f.update();
      f.drive(160, y: 44, speed: 20);
      f.drive(180, y: 30, speed: 20);
      f.drive(200, y: 24, speed: 20);
      f.drive(220, y: 24, speed: 20);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
    },
  );

  test(
    'R21b.2 a past P0 visit cannot accept reverse travel in the 60 m window',
    () async {
      final f = await p0Approach(x: 160, y: 64);
      f.trace = [for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n)];
      f.leader = f.trace.last;
      f.update();
      f.drive(160, y: 44, speed: 20);
      f.drive(160, y: 24, speed: 20);
      f.drive(260, y: 24, elapsed: 5000, speed: 20);
      for (final x in [240.0, 220.0, 200.0]) f.drive(x, y: 24, speed: 20);
      expect(f.state.anchorReached, isFalse);
      expect(f.joins, isEmpty);
    },
  );

  for (final hold in [false, true]) {
    test(
      'R21b.2 P0 visit survives ${hold ? 'stale location' : 'a sample gap'} but join evidence restarts',
      () async {
        final f = await p0Approach(x: 160, y: 64);
        f.trace = [for (var n = 0; n <= 50; n++) testFix(160 + n * 10, seq: n)];
        f.leader = f.trace.last;
        f.update();
        f.drive(160, y: 44, speed: 20);
        f.drive(160, y: 24, speed: 20);
        if (hold) {
          f.selfAge = 10001;
          f.update();
          f.selfAge = 0;
        }
        f.drive(180, y: 24, elapsed: hold ? 1000 : 11000, speed: 20);
        expect(f.joins, isEmpty);
        f.drive(200, y: 24, speed: 20);
        expect(f.joins, isEmpty);
        f.drive(220, y: 24, speed: 20);
        expect(f.state.anchorReached, isTrue);
        expect(f.joins, isEmpty);
        f.drive(240, y: 24, speed: 20);
        expect(f.rejoinedEvents, [false]);
      },
    );
  }

  test(
    'R21b.3 unverified legacy arrival cannot bypass connector reverse detection',
    () async {
      final f = await p0Approach(
        x: 120,
        seed: [testFix(160, y: -20), testFix(160, seq: 1)],
      );
      f.drive(140, speed: 0);
      f.drive(160, speed: 0);
      expect(f.state.anchorReached, isTrue);
      f.trace = [
        testFix(160, y: -20),
        for (var n = 0; n <= 50; n++) testFix(160, y: n * 10, seq: n + 1),
      ];
      f.leader = f.trace.last;
      f.update();
      for (var n = 1; n <= 12; n++) {
        f.drive(160 - n * 3, elapsed: 1500, speed: 2);
      }
      expect(f.departures, hasLength(1));
      expect(f.state.rejoining, isTrue);
      expect(f.joins, isEmpty);
    },
  );
}
