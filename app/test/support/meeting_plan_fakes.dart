import 'dart:async';
import 'package:unavo/location/follow_route_geometry.dart';
import 'package:unavo/location/meeting_plan_controller.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/meeting_plan.dart';
import 'package:unavo/net/models.dart';
import 'follow_route_fakes.dart';

JsonMap pointJson(double x, {String label = '시험 지점', String source = 'map'}) =>
    {
      'lat': testPoint(x).lat,
      'lng': testPoint(x).lng,
      'label': label,
      'source': source,
    };
JsonMap planJson({
  String id = 'plan-1',
  String leader = 'leader',
  int revision = 1,
  double join = 100,
  double destination = 1000,
  String policy = 'wait',
}) => {
  'planId': id,
  'leaderHandle': leader,
  'roomCode': 'ROOM',
  'revision': revision,
  'destination': pointJson(destination),
  'joinPoint': pointJson(join),
  'policy': policy,
  'participantFollowRequestIds': ['follow-1'],
  'waitingPlaceConfirmed': true,
  'status': 'ready',
  'createdAtMs': routeEpoch,
  'updatedAtMs': routeEpoch,
};
JsonMap runtimeJson({
  String id = 'plan-1',
  int revision = 1,
  int runtimeRevision = 1,
  String leader = 'leader',
  String follower = 'self',
  String phase = 'approaching',
  String leaderPhase = 'toJoin',
  String followerPhase = 'toJoin',
  String branch = 'pending',
  bool enrolled = true,
  RouteAnchor? trace,
  int? announced,
  int? passed,
}) => {
  'planId': id,
  'revision': revision,
  'runtimeRevision': runtimeRevision,
  'phase': phase,
  'enrollments': enrolled
      ? [
          {'handle': follower, 'followRequestId': 'follow-1'},
        ]
      : <Object>[],
  'vehicles': [
    {
      'handle': leader,
      'followRequestId': null,
      'phase': leaderPhase,
      'branch': 'pending',
      'condition': null,
    },
    {
      'handle': follower,
      'followRequestId': 'follow-1',
      'phase': followerPhase,
      'branch': branch,
      'condition': null,
      'passedAtMs': passed,
    },
  ],
  'traceStartRef': trace?.toJson(),
  'leaderPassRef': trace?.toJson(),
  'departureAnnouncedAtMs': announced,
  'departedAtMs': null,
};
MeetingPlanSnapshot snapshot({JsonMap? plan, JsonMap? runtime}) =>
    MeetingPlanSnapshot.fromJson({
      'plan': plan ?? planJson(),
      'runtime': runtime ?? runtimeJson(),
      'serverNowMs': routeEpoch,
    });
const planFeatures = MeetingCapabilities(
  enabled: true,
  recommendation: true,
  geocoding: true,
);
const follower = PlanParticipant(
  handle: 'follower',
  followRequestId: 'follow-1',
  displayName: '뒷차',
  sharing: true,
  locationReady: true,
  consentReady: true,
);

class MeetingCall {
  MeetingCall(
    this.method,
    this.path,
    this.body,
    this.cancellation,
    this.timeout,
  );
  final String method, path;
  final JsonMap? body;
  final RouteCancellation cancellation;
  final Duration timeout;
  final pending = Completer<JsonMap>();
  void complete(JsonMap json) => pending.complete(json);
}

class PlanRouteCall {
  PlanRouteCall(this.request, this.cancellation, this.origin, this.goal);
  final PlanRouteRequest request;
  final RouteCancellation cancellation;
  final RoutePoint origin, goal;
  final pending = Completer<FollowRouteResult>();
  JsonMap get json {
    const dummy = FollowRouteRequest(
      followRequestId: 'unused',
      guidanceGeneration: 0,
      calculationId: 'unused',
      requestId: 'unused',
      mode: FollowRouteKind.initial,
      originRef: SampleRef('0123456789abcdef', 0),
      anchor: RouteAnchor.sample(SampleRef('0123456789abcdef', 0)),
    );
    final j = routeJson(dummy, origin, goal)..remove('mode');
    return {...j, ...request.toJson()};
  }

  void succeed({List<RoutePoint>? points}) {
    final j = json;
    if (points != null) {
      j['points'] = points.map((p) => {'lat': p.lat, 'lng': p.lng}).toList();
      j['meters'] = routeLength(points);
    }
    pending.complete(request.parseResult(j));
  }
}

class MeetingFixture {
  MeetingFixture({
    this.account = 'self',
    this.target = 'leader',
    this.relationship = 'follow-1',
  }) {
    controller = MeetingPlanController(
      request:
          (
            room,
            method,
            path,
            body,
            cancellation, {
            timeout = const Duration(seconds: 8),
          }) {
            final c = MeetingCall(method, path, body, cancellation, timeout);
            calls.add(c);
            if (path.endsWith('/participants'))
              c.complete({
                'participants': [
                  {
                    'handle': 'follower',
                    'followRequestId': 'follow-1',
                    'displayName': '뒷차',
                    'sharing': true,
                    'locationReady': true,
                    'consentReady': true,
                  },
                ],
              });
            return c.pending.future;
          },
      loadRoute: (room, request, cancellation) {
        final p = controller.active!.plan;
        final c = PlanRouteCall(
          request,
          cancellation,
          RoutePoint.fromFix(self!),
          request.routeKind == PlanRouteKind.planJoin
              ? p.joinPoint!.point
              : p.destination.point,
        );
        routes.add(c);
        return c.pending.future;
      },
      onInvalidated: () {
        invalidated++;
      },
      onNotice: (key, text) {
        notices.add(key);
      },
      now: () => time,
    );
    update();
    controller.applySnapshot([], [follower], planFeatures);
  }
  late final MeetingPlanController controller;
  final calls = <MeetingCall>[];
  final routes = <PlanRouteCall>[];
  final notices = <String>[];
  String account;
  String? target, relationship;
  String device = 'device';
  int time = 0, seq = 0, invalidated = 0;
  bool restricted = false, consent = true, connected = true, sharing = true;
  double age = 0;
  LocationFix? self = testFix(0, handle: 'self', speed: 0);
  void update() => controller.update(
    MeetingInput(
      room: 'ROOM',
      account: account,
      device: device,
      target: target,
      relationship: relationship,
      connected: connected,
      consent: consent,
      sharing: sharing,
      restricted: restricted,
      self: self,
      selfAgeMs: age,
      leader: testFix(0),
      leaderAgeMs: 0,
      serverNowMs: routeEpoch + time,
    ),
  );
  void drive(
    double x, {
    double y = 0,
    double? speed = 0,
    double? acc = 2,
    String? src,
    int elapsed = 1000,
  }) {
    time += elapsed;
    self = testFix(
      x,
      y: y,
      seq: ++seq,
      at: routeEpoch + time,
      handle: account,
      speed: speed,
      acc: acc,
      src: src,
    );
    update();
  }

  void stop() {
    for (var i = 0; i < 3; i++) {
      drive(0);
    }
  }

  Future<void> enroll({JsonMap? plan, JsonMap? runtime}) async {
    controller.applyPlan(snapshot(plan: plan, runtime: runtime));
    final future = controller.enroll(true);
    calls.last.complete({
      'plan': plan ?? planJson(),
      'runtime': runtime ?? runtimeJson(),
    });
    await future;
    await flush();
  }

  void dispose() => controller.dispose();
}
