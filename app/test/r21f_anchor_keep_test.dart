import 'package:flutter_test/flutter_test.dart';

import 'support/follow_route_fakes.dart';

void main() {
  test(
    'R21f a late P0 response and later exit keep the request and marker anchor frozen',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(160);
      f.trace = [f.leader!];
      f.update();
      final anchor = f.state.anchor,
          point = f.state.anchorPoint,
          at = f.state.anchorAt;
      f.trace = [
        testFix(160),
        testFix(162, seq: 1, at: routeEpoch + 5000, speed: 0),
        testFix(158, seq: 2, at: routeEpoch + 10000, speed: 0),
        for (var n = 1; n <= 50; n++)
          testFix(
            160 + n * 10,
            seq: n + 2,
            at: routeEpoch + 10000 + n * 1000,
            speed: 10,
          ),
      ];
      f.leader = f.trace.last;
      f.update();
      f.calls.single.succeed();
      await flush();
      expect(f.state.route, isNotNull);
      expect(f.state.anchor, anchor);
      expect(f.state.anchorPoint, point);
      expect(f.state.anchorAt, at);
      expect(f.state.marker, point);
      expect(f.calls.single.request.anchor, anchor);
      for (var x = 20.0; x <= 180; x += 20) f.drive(x, speed: 20);
      expect(f.rejoinedEvents, [false]);
      expect(f.state.anchor, anchor);
      expect(f.state.anchorPoint, point);
      expect(f.state.anchorAt, at);
      expect(f.calls, hasLength(1));
    },
  );

  test(
    'R21f departure before initial join keeps the already tracked forward floor',
    () async {
      final f = RouteFixture();
      addTearDown(f.dispose);
      f.self = testFix(0, handle: 'self', speed: 0);
      f.leader = testFix(160);
      f.trace = [f.leader!];
      await f.start();
      f.trace = [for (var n = 0; n <= 100; n++) testFix(160 + n * 10, seq: n)];
      f.leader = f.trace.last;
      f.update();
      for (var x = 20.0; x <= 140; x += 20) f.drive(x, speed: 20);
      for (final x in [170.0, 200.0, 230.0])
        f.drive(x, elapsed: 500, speed: 60);
      expect(f.joins, isEmpty);
      f.drive(230, y: 80, elapsed: 2000, speed: 40);
      for (final x in [233.0, 236.0, 239.0])
        f.drive(x, y: 80, elapsed: 2000, speed: 2);
      expect(f.departures, hasLength(1));
      f.drive(180, y: 80, elapsed: 2000, speed: 30);
      var x = 180.0;
      while (f.time < 30000) f.drive(x += 3, y: 80, elapsed: 2000, speed: 2);
      expect(f.calls, hasLength(2));
      expect(
        f.calls.last.anchor.lng * metersPerDegree,
        greaterThanOrEqualTo(289.99),
      );
      expect(f.joins, isEmpty);
    },
  );
}
