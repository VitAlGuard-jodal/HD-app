// Request sinks are closed by ApiClient.
// ignore_for_file: close_sinks
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/net/meeting_plan.dart';
import 'package:unavo/net/follow_route.dart';
import 'support/avatar_fakes.dart';
import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';

const planRequest = PlanRouteRequest(
  planId: 'plan-1',
  planRevision: 3,
  followRequestId: null,
  guidanceGeneration: 12,
  calculationId: 'calculation-1',
  requestId: 'request-1',
  routeKind: PlanRouteKind.planJoin,
  originRef: SampleRef('0123456789abcdef', 71),
);

void main() {
  for (final kind in PlanRouteKind.values) {
    test(
      'r11 A1 $kind keeps its endpoint limit and always keeps the 25 m origin limit',
      () {
        final request = PlanRouteRequest(
          planId: 'plan-1',
          planRevision: 1,
          followRequestId: null,
          guidanceGeneration: 1,
          calculationId: 'gap',
          requestId: 'gap',
          routeKind: kind,
          originRef: const SampleRef('0123456789abcdef', 1),
          traceAnchor: const RouteAnchor.segment(
            SampleRef('fedcba9876543210', 1),
            SampleRef('fedcba9876543210', 2),
            .5,
          ),
        );
        final call = PlanRouteCall(
          request,
          RouteCancellation(),
          testPoint(0),
          testPoint(1000),
        );
        for (final gap in [24.9, 25.1, 99.9, 100.1]) {
          final body = call.json..['endGapMeters'] = gap;
          if (gap <= (kind == PlanRouteKind.planDestination ? 100 : 25)) {
            expect(() => request.parseResult(body), returnsNormally);
          } else {
            expect(() => request.parseResult(body), throwsFormatException);
          }
        }
        expect(
          () => request.parseResult(call.json..['startGapMeters'] = 25.1),
          throwsFormatException,
        );
        expect(
          () => FollowRouteResult.fromPayload(call.json..['endGapMeters'] = 60),
          throwsFormatException,
        );
      },
    );
  }
  test(
    'schema 2 owner uses explicit null and reference only; HTTP preserves identity and seconds',
    () async {
      final c = PlanRouteCall(
        planRequest,
        RouteCancellation(),
        testPoint(0),
        testPoint(100),
      );
      final http = AvatarTestHttp()..jsonResponse = (_) => c.json;
      final api = http.api(AvatarTestTokenStore());
      addTearDown(api.close);
      final result = await api.planRoute(
        'ROOM',
        planRequest,
        RouteCancellation(),
      );
      expect(result.seconds, 12.345);
      final sent = http.requests.single;
      final body = jsonDecode(utf8.decode(sent.body)) as JsonMap;
      expect(body, planRequest.toJson());
      expect(body['followRequestId'], isNull);
      expect(body.containsKey('mode'), isFalse);
      expect(body['anchor'], {'kind': 'joinPoint'});
      expect(sent.sentHeaders['x-unavo-device'], api.deviceId);
      expect(sent.sentHeaders[HttpHeaders.cacheControlHeader], 'no-store');
    },
  );
  for (final change in <String, Object?>{
    'planId': 'deleted-plan',
    'planRevision': 2,
    'routeKind': 'planDestination',
    'followRequestId': 'old-relation',
    'schemaVersion': 1,
    'requestId': 'old-request',
    'anchor': {'kind': 'destination'},
    'originRef': {'stream': 'different', 'seq': 71},
  }.entries) {
    test('schema 2 rejects mismatched ${change.key}', () {
      final c = PlanRouteCall(
        planRequest,
        RouteCancellation(),
        testPoint(0),
        testPoint(100),
      );
      expect(
        () => planRequest.parseResult(c.json..[change.key] = change.value),
        throwsFormatException,
      );
    });
  }
  test(
    'schema 2 traceRejoin remains distinct from schema 1 B and echoes real segment',
    () {
      const r = PlanRouteRequest(
        planId: 'plan-1',
        planRevision: 1,
        followRequestId: 'follow-1',
        guidanceGeneration: 2,
        calculationId: 'calc',
        requestId: 'req',
        routeKind: PlanRouteKind.traceRejoin,
        originRef: SampleRef('0123456789abcdef', 4),
        traceAnchor: RouteAnchor.segment(
          SampleRef('fedcba9876543210', 8),
          SampleRef('fedcba9876543210', 9),
          .4,
        ),
      );
      final c = PlanRouteCall(
        r,
        RouteCancellation(),
        testPoint(0),
        testPoint(100),
      );
      expect(r.parseResult(c.json).anchor, testPoint(100));
      expect(r.toJson()['anchor'], r.traceAnchor!.toJson());
    },
  );
  test(
    'hello and positions parse followPlans independently of location revision; old server disables only new capabilities',
    () {
      final j = <String, dynamic>{
        'self': 'self',
        'revision': 9000,
        'followPlans': [
          {'plan': planJson(), 'runtime': runtimeJson()},
        ],
        'followRoute': {
          'enabled': true,
          'provider': 'naver',
          'routeOption': 'traoptimal',
          'schemaVersions': [1, 2],
        },
        'meetingPlan': {'enabled': true},
        'meetingRecommendation': {'enabled': false},
        'geocoding': {'enabled': true},
      };
      final hello = Hello.fromJson(j), positions = LocationSnapshot.fromJson(j);
      expect(hello.plans.single.plan.revision, 1);
      expect(hello.meetingCapabilities.enabled, isTrue);
      expect(hello.meetingCapabilities.recommendation, isFalse);
      expect(positions.meetingCapabilities.geocoding, isTrue);
      j.remove('meetingPlan');
      expect(Hello.fromJson(j).meetingCapabilities.enabled, isFalse);
      expect(Hello.fromJson(j).followRoute!.enabled, isTrue);
    },
  );
  test(
    'plan SSE decodes all three lifecycle events and accepted followers update',
    () async {
      final events = [
        (
          'follow-plan-updated',
          <String, dynamic>{'plan': planJson(), 'runtime': runtimeJson()},
        ),
        (
          'follow-plan-progress',
          <String, dynamic>{'runtime': runtimeJson(runtimeRevision: 2)},
        ),
        (
          'follow-plan-participants',
          <String, dynamic>{'acceptedPlanFollowers': <Object>[]},
        ),
        (
          'follow-plan-cleared',
          <String, dynamic>{
            'planId': 'plan-1',
            'leaderHandle': 'leader',
            'revision': 1,
            'reason': 'cancelled',
          },
        ),
      ];
      final stream = StreamController<List<int>>();
      final http = AvatarTestHttp()..eventStream = stream.stream;
      final api = http.api(AvatarTestTokenStore());
      addTearDown(api.close);
      final future = api
          .subscribeEvents('ROOM')
          .where(
            (e) =>
                e is FollowPlanUpdated ||
                e is FollowPlanProgress ||
                e is FollowPlanParticipants ||
                e is FollowPlanCleared,
          )
          .take(4)
          .toList();
      await flush();
      for (final e in events) {
        stream.add(
          utf8.encode('event: ${e.$1}\ndata: ${jsonEncode(e.$2)}\n\n'),
        );
      }
      final decoded = await future;
      expect((decoded[0] as FollowPlanUpdated).snapshot.plan.planId, 'plan-1');
      expect((decoded[1] as FollowPlanProgress).runtime.runtimeRevision, 2);
      expect((decoded[2] as FollowPlanParticipants).participants, isEmpty);
      expect((decoded[3] as FollowPlanCleared).reason, 'cancelled');
      await stream.close();
    },
  );
  test(
    'address query is explicitly submitted as JSON, normalized lat/lng and no coordinates in URL',
    () async {
      final http = AvatarTestHttp()
        ..jsonResponse = (_) => {
          'requestId': 'search-1',
          'results': [
            {
              'lat': 37.5,
              'lng': 127.1,
              'roadAddress': '서울 시험로 1',
              'jibunAddress': '시험동 1',
            },
          ],
        };
      final api = http.api(AvatarTestTokenStore());
      addTearDown(api.close);
      final json = await api.meetingRequest('ROOM', 'POST', '/geocoding', {
        'requestId': 'search-1',
        'query': '서울 시험로 1',
      }, RouteCancellation());
      expect(http.requests.single.uri.query, isEmpty);
      expect(jsonDecode(utf8.decode(http.requests.single.body)), {
        'requestId': 'search-1',
        'query': '서울 시험로 1',
      });
      expect(
        AddressResult.fromJson((json['results'] as List).single).point,
        const RoutePoint(37.5, 127.1),
      );
    },
  );
  test('network exception never leaks query, address or credentials', () async {
    final http = AvatarTestHttp()
      ..openError = const SocketException('SECRET address query key');
    final api = http.api(AvatarTestTokenStore());
    addTearDown(api.close);
    try {
      await api.meetingRequest('ROOM', 'POST', '/geocoding', {
        'requestId': 'search-1',
        'query': '서울 시험로 1',
      }, RouteCancellation());
      fail('failure required');
    } on FollowRouteException catch (e) {
      expect(e.toString(), isNot(contains('SECRET')));
    }
  });
}
