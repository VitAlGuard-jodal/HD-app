import 'dart:async';
import 'dart:math' as math;

import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/models.dart';

const routeEpoch = 1794585600000;
const metersPerDegree = 6371000 * math.pi / 180;
RoutePoint testPoint(double x, [double y = 0]) =>
    RoutePoint(y / metersPerDegree, x / metersPerDegree);
LocationFix testFix(
  double x, {
  double y = 0,
  int seq = 0,
  int? at,
  String handle = 'leader',
  String stream = '0123456789abcdef',
  double? acc = 2,
  double? speed,
}) {
  final point = testPoint(x, y);
  return LocationFix(
    handle: handle,
    stream: stream,
    lat: point.lat,
    lng: point.lng,
    acc: acc,
    speed: speed,
    seq: seq,
    at: at ?? routeEpoch + seq * 1000,
    receivedAt: handle == 'self' ? 0 : at ?? routeEpoch + seq * 1000,
  );
}

JsonMap routeJson(
  FollowRouteRequest request,
  RoutePoint origin,
  RoutePoint anchor, {
  List<RoutePoint>? points,
  bool atAnchor = false,
}) {
  JsonMap json(RoutePoint p) => {'lat': p.lat, 'lng': p.lng};
  final shape = points ?? [origin, anchor];
  return {
    ...request.toJson(),
    'result': atAnchor ? 'atAnchor' : 'route',
    'provider': 'naver',
    'routeOption': 'traoptimal',
    'requestedOrigin': json(origin),
    'requestedAnchor': json(anchor),
    'actualStart': atAnchor ? null : json(shape.first),
    'actualEnd': atAnchor ? null : json(shape.last),
    'points': atAnchor ? <JsonMap>[] : shape.map(json).toList(),
    'meters': atAnchor ? 0 : routeLength(shape),
    'seconds': atAnchor ? 0 : 12.345,
    'startGapMeters': atAnchor ? null : 0,
    'endGapMeters': atAnchor ? null : 0,
    'serverNowMs': routeEpoch,
  };
}

class RouteCall {
  RouteCall(
    this.room,
    this.request,
    this.cancellation,
    this.origin,
    this.anchor,
  );
  final String room;
  final FollowRouteRequest request;
  final RouteCancellation cancellation;
  final RoutePoint origin, anchor;
  final pending = Completer<FollowRouteResult>();
  void succeed({bool atAnchor = false, List<RoutePoint>? points}) =>
      pending.complete(
        FollowRouteResult.fromJson(
          routeJson(
            request,
            origin,
            anchor,
            atAnchor: atAnchor,
            points: points,
          ),
          request,
        ),
      );
  void fail(
    String code, {
    bool retryable = false,
    int delay = 0,
    bool accepted = false,
    int? expires,
  }) => pending.completeError(
    FollowRouteException(
      code,
      retryable: retryable,
      retryAfterMs: delay,
      inputAccepted: accepted,
      inputExpiresAtMs: expires,
    ),
  );
}

class RouteFixture {
  RouteFixture({
    void Function(String, int, bool)? onJoined,
    void Function(String, int)? onDeparted,
    void Function()? onInvalidated,
  }) {
    controller = FollowRouteController(
      load: (room, request, cancellation) {
        final state = controller.state!;
        final call = RouteCall(
          room,
          request,
          cancellation,
          state.originPoint!,
          state.anchorPoint!,
        );
        calls.add(call);
        return call.pending.future;
      },
      canChange: () => !locked,
      now: () => time,
      onJoined: (id, round, rejoined) {
        joins.add((id, round));
        rejoinedEvents.add(rejoined);
        onJoined?.call(id, round, rejoined);
      },
      onDeparted: (id, round) {
        departures.add((id, round));
        onDeparted?.call(id, round);
      },
      onInvalidated: () {
        invalidations++;
        onInvalidated?.call();
      },
    );
  }
  late final FollowRouteController controller;
  int time = 0, selfSeq = 0, invalidations = 0;
  bool locked = false, consent = true, connected = true, restored = false;
  bool routingEnabled = true;
  String room = 'ROOM',
      device = 'device',
      relationship = 'follow-1',
      account = 'self';
  LocationFix? self = testFix(-50, handle: 'self');
  LocationFix? leader = testFix(0);
  List<LocationFix> trace = [testFix(0)];
  double selfAge = 0, leaderAge = 0, originAge = 0;
  final calls = <RouteCall>[];
  final joins = <(String, int)>[];
  final departures = <(String, int)>[];
  final rejoinedEvents = <bool>[];
  FollowGuidance get state => controller.state!;
  void update() => controller.update(
    FollowRouteInput(
      room: room,
      account: account,
      device: device,
      relationship: relationship,
      target: 'leader',
      self: self,
      origin: self,
      leader: leader,
      selfAgeMs: selfAge,
      originAgeMs: originAge,
      leaderAgeMs: leaderAge,
      trace: trace,
      consent: consent,
      connected: connected,
      restored: restored,
      serverNowMs: routeEpoch + time,
      routingEnabled: routingEnabled,
    ),
  );
  void grow([int meters = 200]) {
    trace = [for (var i = 0; i <= meters ~/ 10; i++) testFix(i * 10.0, seq: i)];
    leader = trace.last;
    update();
  }

  void drive(
    double x, {
    double y = 0,
    int elapsed = 1000,
    double? acc = 2,
    double? speed,
  }) {
    time += elapsed;
    self = testFix(
      x,
      y: y,
      handle: 'self',
      seq: ++selfSeq,
      at: routeEpoch + time,
      acc: acc,
      speed: speed,
    );
    update();
  }

  Future<void> start() async {
    update();
    calls.last.succeed();
    await flush();
  }

  Future<void> join() async {
    await start();
    grow();
    for (final x in [-20.0, 0.0, 6.0, 12.0, 18.0]) {
      drive(x);
    }
  }

  // Keep distinct, continuous measurements while waiting for the route cooldown.
  void depart({double y = 80}) {
    for (var i = 0; i < 7; i++) {
      drive(30.0 + i * 3, y: y);
    }
  }

  void driveUntil(int until, {double y = 80}) {
    while (time < until) {
      drive(self!.lng * metersPerDegree + 3, y: y);
    }
  }

  Future<void> rejoinRoute() async {
    await join();
    grow(500);
    depart();
    driveUntil(30000);
    calls.last.succeed();
    await flush();
  }

  void dispose() => controller.dispose();
}

Future<void> flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
}
