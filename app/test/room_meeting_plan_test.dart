import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/map/room_map.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/meeting_plan.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/screens/phone/meeting_plan_panel.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/consent_fakes.dart';
import 'support/follow_route_fakes.dart';
import 'support/icon_bundle.dart';
import 'support/meeting_plan_fakes.dart' as meeting;

const _follower = PlanParticipant(
  handle: 'carol',
  followRequestId: 'follow-1',
  displayName: '뒷차',
  sharing: true,
  locationReady: true,
  consentReady: true,
);

void main() {
  for (final closeFromToolbar in [false, true]) {
    testWidgets(
      'R22b.3 ${closeFromToolbar ? 'toolbar' : 'panel'} close notifies session preview observers',
      (tester) async {
        final f = await _Fixture.create(tester, participants: [_follower]);
        final c = f.services.rooms.meetingPlan;
        MeetingRecommendation? observed;
        var notifications = 0;
        void changed() {
          notifications++;
          observed = c.recommendation;
        }

        try {
          await f.stop();
          final original = f.services.api.http.jsonResponse!;
          f.services.api.http.jsonResponse = (request) {
            if (!request.uri.path.endsWith('/recommend'))
              return original(request);
            final body = jsonDecode(utf8.decode(request.body)) as JsonMap;
            return {
              'requestId': body['requestId'],
              'draftGeneration': body['draftGeneration'],
              'result': 'candidate',
              'joinPoint': meeting.pointJson(163, source: 'recommendation'),
              'calculatedAtMs': f.now,
              'serverNowMs': f.now,
              'etaQuality': 'rough',
              'arrivals': [
                {'handle': 'bob', 'etaToJoinSeconds': 10, 'waitSeconds': 5},
                {'handle': 'carol', 'etaToJoinSeconds': 15, 'waitSeconds': 0},
              ],
              'remainingToDestinationMeters': 837,
              'remainingToDestinationSeconds': 60,
            };
          };
          await f.tap('합류 계획 보기');
          await f.tap('내 그룹 합류 계획 편집');
          c.pickPoint(testPoint(1000));
          c.confirmPoint();
          await completeConsentFuture(tester, c.recommend());
          await tester.pump();
          expect(c.recommendation, isNotNull);
          expect(f.map.meetingPins.any((pin) => pin.id == 'pending'), isTrue);
          observed = c.recommendation;
          f.services.rooms.addListener(changed);
          // Invoke the real UI callback without advancing the periodic timer,
          // which could otherwise conceal the missing close notification.
          if (closeFromToolbar) {
            f.map.onMeetingPlan!();
          } else {
            _panelButton(tester, '합류 계획 닫기').onPressed!();
          }
          expect(c.editing, isFalse);
          expect(c.recommendation, isNull);
          expect(notifications, 1);
          expect(observed, isNull);
          await tester.pump();
          expect(f.map.meetingPins.any((pin) => pin.id == 'pending'), isFalse);
          expect(f.map.pauseAutoCamera, isFalse);
          expect(tester.takeException(), isNull);
        } finally {
          f.services.rooms.removeListener(changed);
          await f.dispose();
        }
      },
    );
  }
  for (final car in [false, true]) {
    testWidgets('r9 차량 $car: 입장·공유만으로는 팔로워와 계획 없는 지도가 열리지 않는다', (tester) async {
      final f = await _Fixture.create(tester, car: car, sharing: false);
      try {
        expect(find.byType(RoomMap), findsNothing);
        await f.startSharing();
        await f.hello();
        await f.stop();
        expect(f.services.rooms.canEditMeetingPlan, isTrue);
        expect(find.byType(RoomMap), findsNothing);
        expect(find.byTooltip('합류 계획 보기'), findsNothing);
      } finally {
        await f.dispose();
      }
    });

    testWidgets('r9 차량 $car: 수락 SSE → 7:3 지도·계획 패널·전체 화면 → 해제 SSE', (
      tester,
    ) async {
      final f = await _Fixture.create(tester, car: car);
      final semantics = tester.ensureSemantics();
      try {
        await f.stop();
        expect(find.byType(RoomMap), findsNothing);
        await f.followers([_follower]);
        final map = f.map;
        expect(map.targetHandle, isNull);
        expect(map.following, isFalse);
        expect(map.trail, isEmpty);
        expect(map.guidance, isNull);
        expect(map.onModeChanged, isNull);
        expect(map.onResetGuidance, isNull);
        expect(map.onMeetingPlan, isNotNull);
        expect(f.services.rooms.meetingPlan.selected, isFalse);
        expect(f.map.pauseAutoCamera, isFalse);
        expect(f.routeRequests, isEmpty);
        _expectSplit(tester, car);
        expect(find.bySemanticsLabel('합류 계획 보기'), findsOneWidget);
        final button = find.byWidgetPredicate(
          (w) => w is RoomMapButton && w.label == '합류 계획 보기',
        );
        expect(
          find.descendant(of: button, matching: find.byType(Text)),
          findsNothing,
        );

        await f.tap('합류 계획 보기');
        expect(find.byType(MeetingPlanPanel), findsOneWidget);
        expect(_panelButton(tester, '내 그룹 합류 계획 편집').onPressed, isNotNull);
        await f.tap('내 그룹 합류 계획 편집');
        expect(f.services.rooms.meetingPlan.editing, isTrue);
        expect(f.map.onPointSelected, isNotNull);
        expect(f.map.pauseAutoCamera, isTrue);
        f.map.onPointSelected!(testPoint(500));
        await tester.pump();
        expect(f.services.rooms.meetingPlan.pendingPoint, isNotNull);
        expect(f.map.pauseAutoCamera, isTrue);
        await f.tap('합류 계획 보기');
        expect(f.services.rooms.meetingPlan.editing, isFalse);
        expect(f.map.pauseAutoCamera, isFalse);
        await f.tap('합류 계획 보기');
        await f.tap('내 그룹 합류 계획 편집');
        await f.tap('합류 계획 닫기');
        expect(f.map.pauseAutoCamera, isFalse);
        await f.tap('지도 전체 화면');
        expect(f.map.fullscreen, isTrue);
        // A session rebuild must not collapse a leader's full-screen map.
        await f.followers([_follower]);
        expect(f.map.fullscreen, isTrue);
        expect(
          find.byKey(const ValueKey('room-fullscreen-map')),
          findsOneWidget,
        );
        await f.tap('지도 축소');
        _expectSplit(tester, car);

        await f.tap('지도 전체 화면');
        await f.followers([]);
        expect(f.services.rooms.meetingPlan.ownPlan, isNull);
        expect(find.byType(RoomMap), findsNothing);
        expect(find.byType(MeetingPlanPanel), findsNothing);
        expect(f.services.locationShare.sharing, isTrue);
        await f.followers([_follower]);
        expect(f.map.fullscreen, isFalse);
        _expectSplit(tester, car);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await f.dispose();
      }
    });

    testWidgets('r9 차량 $car: hello의 내 계획은 팔로워 0명에도 지도를 유지하고 삭제 시 닫힌다', (
      tester,
    ) async {
      final f = await _Fixture.create(
        tester,
        car: car,
        plans: [_plan(enrolled: false)],
      );
      try {
        expect(f.services.rooms.leaderHandle, 'alice');
        expect(f.services.store.handle, 'bob');
        expect(f.services.rooms.meetingPlan.participants, isEmpty);
        expect(find.byType(RoomMap), findsOneWidget);
        expect(f.map.onMeetingPlan, isNotNull);
        expect(f.map.guidance, isNull);
        expect(f.routeRequests, isEmpty);
        await f.followers([_follower]);
        await f.followers([]);
        expect(find.byType(RoomMap), findsOneWidget);
        await f.event(
          const FollowPlanCleared('own-plan', 'bob', 1, 'cancelled'),
        );
        expect(find.byType(RoomMap), findsNothing);
      } finally {
        await f.dispose();
      }
    });

    testWidgets('r9 차량 $car: 새 화면·재접속 hello가 팔로워 지도를 복원하고 빈 hello는 닫는다', (
      tester,
    ) async {
      final f = await _Fixture.create(
        tester,
        car: car,
        participants: [_follower],
      );
      try {
        expect(find.byType(RoomMap), findsOneWidget);
        expect(f.map.targetHandle, isNull);
        await f.event(const Reconnected());
        await f.hello(participants: [_follower]);
        expect(find.byType(RoomMap), findsOneWidget);
        expect(f.services.rooms.meetingPlan.selected, isFalse);
        expect(f.routeRequests, isEmpty);
        await f.event(const Reconnected());
        await f.hello();
        expect(find.byType(RoomMap), findsNothing);
        expect(f.services.locationShare.sharing, isTrue);
      } finally {
        await f.dispose();
      }
    });

    for (final policy in ['wait', 'proceed']) {
      testWidgets('r9 차량 $car/$policy: 방에서 그룹장 안내 선택 → X→J → 출발 후 현재 X→D', (
        tester,
      ) async {
        final f = await _Fixture.create(
          tester,
          car: car,
          participants: [_follower],
        );
        try {
          await f.stop();
          await f.event(FollowPlanUpdated(_plan(policy: policy)));
          expect(f.map.guidance, isNull);
          expect(f.routeRequests, isEmpty, reason: '계획 수신만으로 안내를 시작하지 않는다');
          await f.tap('합류 계획 보기');
          await f.tap('내 그룹장 안내 선택');
          expect(f.services.rooms.meetingPlan.owner, isTrue);
          expect(f.services.rooms.followRoute.state, isNull);
          expect(f.map.targetHandle, isNull);
          expect(f.map.following, isFalse);
          expect(f.map.trail, isEmpty);
          expect(f.map.onModeChanged, isNull);
          expect(f.map.onResetGuidance, isNotNull);
          _expectOwnRoute(
            tester,
            f,
            PlanRouteKind.planJoin,
            testPoint(0),
            testPoint(100),
          );
          await f.tap('합류 계획 닫기');

          await f.sample(
            x: 120,
            speed: 10,
            elapsed: const Duration(seconds: 2),
          );
          final runtime = meeting.runtimeJson(
            id: 'own-plan',
            leader: 'bob',
            follower: 'carol',
            runtimeRevision: 2,
            phase: 'departed',
            leaderPhase: 'toDestination',
            announced: policy == 'wait' ? f.now : null,
            trace: RouteAnchor.sample(
              SampleRef.of(f.services.locationShare.lastSent!),
            ),
          )..['departedAtMs'] = f.now;
          await f.event(FollowPlanProgress(MeetingRuntime.fromJson(runtime)));
          expect(f.services.rooms.canEditMeetingPlan, isFalse);
          expect(f.map.onResetGuidance, isNull);
          _expectOwnRoute(
            tester,
            f,
            PlanRouteKind.planDestination,
            testPoint(120),
            testPoint(1000),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await f.dispose();
        }
      });
    }
  }

  for (final sharing in [false, true]) {
    testWidgets('r9 위치 공유 $sharing: 공유 또는 capability가 없으면 그룹장 지도 없음', (
      tester,
    ) async {
      final f = await _Fixture.create(
        tester,
        sharing: sharing,
        enabled: !sharing,
        participants: [_follower],
        plans: [_plan(enrolled: false)],
      );
      try {
        expect(find.byType(RoomMap), findsNothing);
      } finally {
        await f.dispose();
      }
    });
  }

  testWidgets('r9 그룹장 지도는 위치 공유 종료 시 닫힌다', (tester) async {
    final f = await _Fixture.create(tester, participants: [_follower]);
    try {
      expect(find.byType(RoomMap), findsOneWidget);
      await completeConsentFuture(tester, f.services.locationShare.stop());
      await pumpConsentUi(tester);
      expect(find.byType(RoomMap), findsNothing);
    } finally {
      await f.dispose();
    }
  });

  for (final enabled in [false, true]) {
    testWidgets('r9 capability $enabled: 뒷차의 대상·궤적·안내·전체 화면·중지 동작 유지', (
      tester,
    ) async {
      final f = await _Fixture.create(
        tester,
        target: 'alice',
        enabled: enabled,
      );
      try {
        await f.stop();
        expect(f.map.targetHandle, 'alice');
        expect(f.map.following, isTrue);
        expect(f.map.trail, f.services.rooms.trailOf('alice'));
        expect(f.map.trail, isNotEmpty);
        expect(f.map.guidance!.mode, FollowMode.a);
        expect(f.map.onResetGuidance, isNotNull);
        expect(f.map.onMeetingPlan != null, enabled);
        await f.tap('지도 전체 화면');
        expect(f.map.fullscreen, isTrue);
        await f.tap('지도 축소');
        await f.stopFollowingViaCard();
        expect(f.services.rooms.followTarget, isNull);
        expect(f.services.locationShare.sharing, isTrue);
        expect(find.byType(RoomMap), findsNothing);
      } finally {
        await f.dispose();
      }
    });
  }

  for (final meetingMode in [false, true]) {
    testWidgets(
      'r9 다른 차 ${meetingMode ? '②' : '①'}도 따르는 그룹장은 정차 중 명시 전환한 한 역할만 표시',
      (tester) async {
        final f = await _Fixture.create(
          tester,
          target: 'alice',
          participants: [_follower],
          plans: [
            _plan(),
            _plan(leader: 'alice', enrolled: false),
          ],
        );
        try {
          await f.stop();
          if (meetingMode) await f.tap('합류 지점 따라가기');
          expect(f.map.targetHandle, 'alice');
          expect(f.map.following, isTrue);
          expect(
            f.map.guidance!.mode,
            meetingMode ? FollowMode.meetingPoint : FollowMode.a,
          );
          expect(f.services.rooms.meetingPlan.owner, isFalse);
          final followsBefore = f.services.api.follows.length;
          final unfollowsBefore = f.services.api.unfollows;
          await f.tap('합류 계획 보기');
          await f.sample(speed: 3);
          expect(_panelButton(tester, '내 그룹장 안내 선택').onPressed, isNull);
          expect(f.map.onModeChanged, isNull);
          expect(f.map.targetHandle, 'alice');

          await f.stop();
          await f.tap('내 그룹장 안내 선택');
          expect(f.services.rooms.followTarget, 'alice');
          expect(f.services.rooms.meetingPlan.owner, isTrue);
          expect(f.services.rooms.followRoute.state, isNull);
          expect(f.map.targetHandle, isNull);
          expect(f.map.following, isFalse);
          expect(f.map.trail, isEmpty);
          _expectOwnRoute(
            tester,
            f,
            PlanRouteKind.planJoin,
            testPoint(0),
            testPoint(100),
          );
          if (meetingMode) {
            expect(f.participationWrites.map((b) => b['enabled']), [
              true,
              false,
            ]);
          } else {
            expect(f.participationWrites, isEmpty);
          }
          await f.tap('합류 계획 닫기');
          await f.sample(speed: 3);
          expect(f.map.onModeChanged, isNull);
          expect(f.map.onResetGuidance, isNull);
          await f.stop();
          await f.tap('따라가기');
          expect(f.map.targetHandle, 'alice');
          expect(f.map.following, isTrue);
          expect(f.map.trail, isNotEmpty);
          expect(f.map.guidance!.mode, FollowMode.a);
          expect(f.services.rooms.meetingPlan.selected, isFalse);
          expect(f.services.api.follows.length, followsBefore);
          expect(f.services.api.unfollows, unfollowsBefore);

          await f.stopFollowingViaCard();
          expect(f.services.rooms.followTarget, isNull);
          expect(f.services.locationShare.sharing, isTrue);
          expect(find.byType(RoomMap), findsOneWidget);
          expect(f.map.following, isFalse);
          expect(f.map.targetHandle, isNull);
          expect(f.map.guidance, isNull);
          expect(f.map.onMeetingPlan, isNotNull);
          expect(tester.takeException(), isNull);
        } finally {
          await f.dispose();
        }
      },
    );
  }
}

PanelButton _panelButton(WidgetTester tester, String label) => tester.widget(
  find.byWidgetPredicate((w) => w is PanelButton && w.label == label),
);

void _expectSplit(WidgetTester tester, bool car) {
  final map = tester.getSize(find.byType(RoomMap));
  final panel = tester.getSize(find.byKey(const ValueKey('room-call-panel')));
  expect(
    car ? map.width / panel.width : map.height / panel.height,
    closeTo(7 / 3, .001),
  );
}

void _expectOwnRoute(
  WidgetTester tester,
  _Fixture f,
  PlanRouteKind kind,
  RoutePoint origin,
  RoutePoint goal,
) {
  final request = f.routeRequests.last;
  expect(request['schemaVersion'], 2);
  expect(request['planId'], 'own-plan');
  expect(request['followRequestId'], isNull);
  expect(request['routeKind'], kind.name);
  final expected = [(origin.lat, origin.lng), (goal.lat, goal.lng)];
  expect(f.map.guidance!.connector.map((p) => (p.lat, p.lng)), expected);
  // Verify the actual VWorld overlay as well as the RoomScreen -> RoomMap input.
  final lines = tester
      .widget<PolylineLayer>(find.byType(PolylineLayer))
      .polylines;
  expect(lines, hasLength(1), reason: '다른 역할의 궤적을 함께 그리지 않는다');
  expect(lines.single.points.map((p) => (p.latitude, p.longitude)), expected);
}

JsonMap _planJson({
  String leader = 'bob',
  bool enrolled = true,
  String policy = 'wait',
}) {
  final own = leader == 'bob';
  final id = own ? 'own-plan' : 'target-plan';
  final relationship = own ? 'follow-1' : 'alice-request';
  final plan =
      meeting.planJson(
          id: id,
          leader: leader,
          join: own ? 100 : 200,
          policy: policy,
        )
        ..['roomCode'] = 'ABC123'
        ..['participantFollowRequestIds'] = [relationship];
  final runtime = meeting.runtimeJson(
    id: id,
    leader: leader,
    follower: own ? 'carol' : 'bob',
    enrolled: enrolled,
  );
  runtime['enrollments'] = enrolled
      ? [
          {'handle': own ? 'carol' : 'bob', 'followRequestId': relationship},
        ]
      : <Object>[];
  (runtime['vehicles'] as List)[1]['followRequestId'] = relationship;
  return {'plan': plan, 'runtime': runtime};
}

MeetingPlanSnapshot _plan({
  String leader = 'bob',
  bool enrolled = true,
  String policy = 'wait',
}) => MeetingPlanSnapshot.fromJson(
  _planJson(leader: leader, enrolled: enrolled, policy: policy),
);

class _Fixture {
  _Fixture(this.tester, this.services, this.mode);
  final WidgetTester tester;
  final ConsentTestServices services;
  final DeviceMode mode;
  final appearance = AppearanceController();
  final routeRequests = <JsonMap>[];
  final participationWrites = <JsonMap>[];
  List<PlanParticipant> participants = [];
  int revision = 0;
  double x = 0;
  int get now => tester.binding.clock.now().millisecondsSinceEpoch;
  RoomMap get map => tester.widget(find.byType(RoomMap));

  static Future<_Fixture> create(
    WidgetTester tester, {
    bool car = false,
    bool sharing = true,
    bool enabled = true,
    String? target,
    List<PlanParticipant> participants = const [],
    List<MeetingPlanSnapshot> plans = const [],
  }) async {
    tester.view.physicalSize = car
        ? const Size(1320, 940)
        : const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final mode = car ? DeviceMode.car : DeviceMode.phone;
    final epoch = tester.binding.clock.now().millisecondsSinceEpoch;
    final services = await ConsentTestServices.create(
      tester,
      mode: mode,
      monotonicNow: () =>
          tester.binding.clock.now().millisecondsSinceEpoch - epoch,
    );
    services.api.consent = testConsent();
    services.store.updateConsent(
      testConsent(),
      sessionRevision: services.store.sessionRevision,
    );
    services.api.members = const [
      Member('alice', '앞차', '1'),
      Member('bob', '그룹장', '2'),
      Member('carol', '뒷차', '3'),
    ];
    final f = _Fixture(tester, services, mode);
    final consentResponse = services.api.http.jsonResponse!;
    services.api.http.jsonResponse = (request) {
      final path = request.uri.path;
      if (path.endsWith('/participants')) {
        return {
          'participants': [
            for (final p in f.participants)
              {
                'handle': p.handle,
                'followRequestId': p.followRequestId,
                'displayName': p.displayName,
                'sharing': p.sharing,
                'locationReady': p.locationReady,
                'consentReady': p.consentReady,
              },
          ],
        };
      }
      if (path.endsWith('/participation')) {
        final body = jsonDecode(utf8.decode(request.body)) as JsonMap;
        f.participationWrites.add(body);
        final response = _planJson(
          leader: 'alice',
          enrolled: body['enabled'] == true,
        );
        (response['runtime'] as JsonMap)['runtimeRevision'] =
            f.participationWrites.length + 1;
        return response;
      }
      if (path.endsWith('/follow-route')) {
        final body = jsonDecode(utf8.decode(request.body)) as JsonMap;
        f.routeRequests.add(body);
        final origin = RoutePoint.fromFix(services.locationShare.lastSent!);
        final plan = services.rooms.meetingPlan.active?.plan;
        final goal = body['schemaVersion'] == 2
            ? body['routeKind'] == 'planJoin'
                  ? plan!.joinPoint!.point
                  : plan!.destination.point
            : testPoint(50);
        const dummy = FollowRouteRequest(
          followRequestId: 'unused',
          guidanceGeneration: 0,
          calculationId: 'unused',
          requestId: 'unused',
          mode: FollowRouteKind.initial,
          originRef: SampleRef('0123456789abcdef', 0),
          anchor: RouteAnchor.sample(SampleRef('0123456789abcdef', 0)),
        );
        final response = routeJson(dummy, origin, goal)..remove('mode');
        return {...response, ...body, 'serverNowMs': f.now};
      }
      if (path.endsWith('/guidance-status') || path.endsWith('/pass-evidence'))
        return <String, dynamic>{};
      return consentResponse(request);
    };
    await services.openRoom(tester);
    if (sharing) await f.startSharing();
    await f.hello(
      target: target,
      participants: participants,
      plans: plans,
      enabled: enabled,
    );
    await tester.pumpWidget(
      UnavoAppearance(
        controller: f.appearance,
        child: MaterialApp(
          builder: testIconBuilder,
          theme: unavoTheme(Brightness.light),
          home: RoomScreen(services: services, mode: mode),
        ),
      ),
    );
    await pumpConsentUi(tester);
    return f;
  }

  Future<void> startSharing() => completeConsentFuture(
    tester,
    services.locationShare.start(token: Object(), stillValid: () => true),
  );

  Future<void> event(RoomEvent value) async {
    services.api.events.add(value);
    await pumpConsentUi(tester);
    await pumpConsentUi(tester);
  }

  Future<void> hello({
    String? target,
    List<PlanParticipant> participants = const [],
    List<MeetingPlanSnapshot> plans = const [],
    bool enabled = true,
  }) async {
    this.participants = participants;
    final leader = testFix(50, handle: 'alice', at: now, speed: 0);
    await event(
      Hello(
        'bob',
        services.api.members,
        'alice',
        [leader],
        target == null
            ? const {}
            : {
                'alice': [leader],
              },
        target,
        const [],
        ++revision,
        null,
        target == null ? null : 'alice-request',
        now,
        const FollowRouteFeature(enabled: true),
        plans,
        participants,
        enabled ? meeting.planFeatures : const MeetingCapabilities(),
      ),
    );
  }

  Future<void> followers(List<PlanParticipant> values) async {
    participants = values;
    await event(FollowPlanParticipants(values));
  }

  Future<void> sample({
    double? x,
    double speed = .5,
    Duration elapsed = const Duration(seconds: 1),
  }) async {
    await tester.pump(elapsed);
    this.x = x ?? this.x;
    final point = testPoint(this.x);
    services.locationSource.add(
      LocationSample(
        lat: point.lat,
        lng: point.lng,
        accuracy: 2,
        speed: speed,
        at: tester.binding.clock.now(),
      ),
    );
    await pumpConsentUi(tester);
  }

  Future<void> stop() async {
    // 0.5 m/s is below the edit threshold and keeps the existing 1 s send cadence.
    for (var i = 0; i < 3; i++) {
      await sample();
    }
    expect(
      services.rooms.canEditMeetingPlan,
      services.rooms.meetingPlan.capabilities.enabled,
    );
  }

  Future<void> tap(String label) async {
    final button = find.byTooltip(label);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await pumpConsentUi(tester);
    await pumpConsentUi(tester);
  }

  Future<void> stopFollowingViaCard() async {
    final card = find.byKey(const ValueKey('member-alice'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    await pumpConsentUi(tester);
    expect(find.text('따라가기 안내는 종료되고 내 위치 공유는 계속됩니다'), findsOneWidget);
    expect(find.text('지도는 닫히고 내 위치 공유는 계속됩니다'), findsNothing);
    await tap('동의');
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await services.finish(tester);
    appearance.dispose();
  }
}
