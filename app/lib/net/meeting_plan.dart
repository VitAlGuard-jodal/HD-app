import 'dart:math' as math;
import 'follow_route.dart';
import 'models.dart';

enum MeetingPolicy { wait, proceed }

enum MeetingPointField { destination, joinPoint }

enum PlanRouteKind { planJoin, planDestination, traceRejoin }

JsonMap meetingObject(Object? value) {
  if (value is! JsonMap) throw const FormatException('합류 계획 응답 오류');
  return value;
}

int meetingInt(Object? value) {
  if (value is! int || value < 0) throw const FormatException('합류 계획 수치 오류');
  return value;
}

String meetingString(Object? value) {
  if (value is! String || value.isEmpty || value.length > 256) {
    throw const FormatException('합류 계획 식별자 오류');
  }
  return value;
}

class MeetingPoint {
  const MeetingPoint(this.point, this.label, this.source);
  factory MeetingPoint.fromJson(Object? value) {
    final json = meetingObject(value);
    final source = json['source'];
    if (!{'map', 'address', 'recommendation'}.contains(source)) {
      throw const FormatException('합류 지점 출처 오류');
    }
    return MeetingPoint(
      RoutePoint.fromJson(json),
      meetingString(json['label']),
      source as String,
    );
  }
  final RoutePoint point;
  final String label, source;
  JsonMap toJson() => {
    'lat': point.lat,
    'lng': point.lng,
    'label': label,
    'source': source,
  };
}

class MeetingPlan {
  const MeetingPlan({
    required this.planId,
    required this.leaderHandle,
    required this.roomCode,
    required this.revision,
    required this.destination,
    required this.joinPoint,
    required this.policy,
    required this.participantFollowRequestIds,
    required this.waitingPlaceConfirmed,
    required this.status,
    required this.createdAtMs,
    required this.updatedAtMs,
  });
  factory MeetingPlan.fromJson(Object? value) {
    final j = meetingObject(value);
    if (!{'wait', 'proceed'}.contains(j['policy']) ||
        !{'draft', 'ready'}.contains(j['status'])) {
      throw const FormatException('합류 계획 상태 오류');
    }
    final ids = (j['participantFollowRequestIds'] as List)
        .map(meetingString)
        .toList();
    if (ids.toSet().length != ids.length)
      throw const FormatException('합류 참여자 오류');
    return MeetingPlan(
      planId: meetingString(j['planId']),
      leaderHandle: meetingString(j['leaderHandle']),
      roomCode: meetingString(j['roomCode']),
      revision: meetingInt(j['revision']),
      destination: MeetingPoint.fromJson(j['destination']),
      joinPoint: j['joinPoint'] == null
          ? null
          : MeetingPoint.fromJson(j['joinPoint']),
      policy: j['policy'] == 'wait'
          ? MeetingPolicy.wait
          : MeetingPolicy.proceed,
      participantFollowRequestIds: List.unmodifiable(ids),
      waitingPlaceConfirmed: j['waitingPlaceConfirmed'] == true,
      status: j['status'] as String,
      createdAtMs: meetingInt(j['createdAtMs']),
      updatedAtMs: meetingInt(j['updatedAtMs']),
    );
  }
  final String planId, leaderHandle, roomCode, status;
  final int revision, createdAtMs, updatedAtMs;
  final MeetingPoint destination;
  final MeetingPoint? joinPoint;
  final MeetingPolicy policy;
  final List<String> participantFollowRequestIds;
  final bool waitingPlaceConfirmed;
  bool get ready =>
      status == 'ready' &&
      joinPoint != null &&
      (policy != MeetingPolicy.wait || waitingPlaceConfirmed);
  bool get destinationOnly {
    final j = joinPoint?.point, d = destination.point;
    if (j == null) return false;
    final x = (j.lng - d.lng) * math.cos(d.lat * math.pi / 180) * 111195;
    final y = (j.lat - d.lat) * 111195;
    return math.sqrt(x * x + y * y) <= 1;
  }
}

class PlanParticipant {
  const PlanParticipant({
    required this.handle,
    required this.followRequestId,
    required this.displayName,
    required this.sharing,
    required this.locationReady,
    required this.consentReady,
  });
  factory PlanParticipant.fromJson(Object? value) {
    final j = meetingObject(value);
    return PlanParticipant(
      handle: meetingString(j['handle']),
      followRequestId: meetingString(j['followRequestId']),
      displayName: j['displayName'] as String? ?? j['handle'] as String,
      sharing: j['sharing'] == true,
      locationReady: j['locationReady'] == true,
      consentReady: j['consentReady'] == true,
    );
  }
  final String handle, followRequestId, displayName;
  final bool sharing, locationReady, consentReady;
  bool get ready => sharing && locationReady && consentReady;
  String get status => !sharing
      ? '위치 공유 필요'
      : !consentReady
      ? '최신 동의 필요'
      : !locationReady
      ? '위치 확인 필요'
      : '추천 가능';
}

class PlanVehicle {
  const PlanVehicle({
    required this.handle,
    required this.followRequestId,
    required this.phase,
    required this.branch,
    this.condition,
    this.reportedStage,
    this.etaSeconds,
    this.calculatedAtMs,
    this.passedAtMs,
  });
  factory PlanVehicle.fromJson(Object? value) {
    final j = meetingObject(value);
    final branch = j['branch'] as String? ?? 'pending';
    if (!{'pending', 'trace', 'destination'}.contains(branch))
      throw const FormatException('안내 분기 오류');
    return PlanVehicle(
      handle: meetingString(j['handle']),
      followRequestId: j['followRequestId'] as String?,
      phase: meetingString(j['phase']),
      branch: branch,
      condition: j['condition'] as String?,
      reportedStage: j['reportedStage'] as String?,
      etaSeconds: _optionalNumber(j['etaSeconds']),
      passedAtMs: j['passedAtMs'] == null ? null : meetingInt(j['passedAtMs']),
      calculatedAtMs: j['calculatedAtMs'] == null
          ? null
          : meetingInt(j['calculatedAtMs']),
    );
  }
  final String handle, phase, branch;
  final String? followRequestId, condition, reportedStage;
  final double? etaSeconds;
  final int? calculatedAtMs, passedAtMs;
  bool get arrived => {
    'atJoinWaiting',
    'tracePriming',
    'onTrace',
    'toDestination',
    'completed',
  }.contains(phase);
  String get status => passedAtMs != null && branch == 'pending'
      ? '합류 상태 확인 중'
      : branch == 'trace' && reportedStage == 'onTrace'
      ? '앞차 경로 추종 중'
      : branch == 'trace' && reportedStage == 'rejoining'
      ? '다시 합류하는 중'
      : switch (phase) {
          'invited' => '안내 미시작',
          'enrolled' || 'toJoin' || 'approaching' => '합류 지점으로 이동',
          'nearJoin' => '합류 상태 확인 중',
          'atJoinWaiting' || 'waiting' => '합류 지점에서 대기 중',
          'tracePriming' => '앞차 이동 경로 확인 중',
          'onTrace' => '앞차 경로 추종 중',
          'toDestination' => '목적지로 먼저 이동',
          'completed' => '목적지 도착',
          _ => '합류 상태 확인 중',
        };
}

double? _optionalNumber(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < 0)
    throw const FormatException('예상 시간 오류');
  return value.toDouble();
}

RouteAnchor? _traceRef(Object? value) {
  if (value == null) return null;
  final j = meetingObject(value);
  return j['kind'] == null
      ? RouteAnchor.sample(SampleRef.fromJson(j))
      : RouteAnchor.fromJson(j);
}

class MeetingRuntime {
  const MeetingRuntime({
    required this.planId,
    required this.planRevision,
    required this.runtimeRevision,
    required this.phase,
    required this.enrollments,
    required this.vehicles,
    this.traceStartRef,
    this.leaderPassRef,
    this.departureAnnouncedAtMs,
    this.departedAtMs,
  });
  factory MeetingRuntime.fromJson(Object? value) {
    final j = meetingObject(value);
    return MeetingRuntime(
      planId: meetingString(j['planId']),
      planRevision: meetingInt(j['planRevision'] ?? j['revision']),
      runtimeRevision: meetingInt(j['runtimeRevision']),
      phase: meetingString(j['phase']),
      enrollments: List.unmodifiable(
        (j['enrollments'] as List? ?? []).map(
          (e) => e is String
              ? e
              : meetingString(meetingObject(e)['followRequestId']),
        ),
      ),
      vehicles: List.unmodifiable(
        (j['vehicles'] as List? ?? []).map(PlanVehicle.fromJson),
      ),
      traceStartRef: _traceRef(j['traceStartRef']),
      leaderPassRef: _traceRef(j['leaderPassRef']),
      departureAnnouncedAtMs: j['departureAnnouncedAtMs'] == null
          ? null
          : meetingInt(j['departureAnnouncedAtMs']),
      departedAtMs: j['departedAtMs'] == null
          ? null
          : meetingInt(j['departedAtMs']),
    );
  }
  final String planId, phase;
  final int planRevision, runtimeRevision;
  final List<String> enrollments;
  final List<PlanVehicle> vehicles;
  final RouteAnchor? traceStartRef, leaderPassRef;
  final int? departureAnnouncedAtMs, departedAtMs;
  PlanVehicle? vehicle(String handle) {
    for (final v in vehicles) {
      if (v.handle == handle) return v;
    }
    return null;
  }
}

class MeetingPlanSnapshot {
  const MeetingPlanSnapshot(this.plan, this.runtime);
  factory MeetingPlanSnapshot.fromJson(Object? value) {
    final j = meetingObject(value);
    final plan = MeetingPlan.fromJson(j['plan']);
    final runtime = j['runtime'] == null
        ? null
        : MeetingRuntime.fromJson(j['runtime']);
    if (runtime != null &&
        (runtime.planId != plan.planId ||
            runtime.planRevision != plan.revision)) {
      throw const FormatException('합류 진행 버전 오류');
    }
    return MeetingPlanSnapshot(plan, runtime);
  }
  final MeetingPlan plan;
  final MeetingRuntime? runtime;
}

class MeetingCapabilities {
  const MeetingCapabilities({
    this.enabled = false,
    this.recommendation = false,
    this.geocoding = false,
  });
  factory MeetingCapabilities.fromJson(JsonMap j) {
    final route = j['followRoute'];
    final enabled =
        route is JsonMap &&
        route['enabled'] == true &&
        route['provider'] == 'naver' &&
        route['routeOption'] == 'traoptimal' &&
        (route['schemaVersions'] as List? ?? []).contains(2) &&
        j['meetingPlan'] is JsonMap &&
        (j['meetingPlan'] as JsonMap)['enabled'] == true;
    return MeetingCapabilities(
      enabled: enabled,
      recommendation:
          enabled &&
          j['meetingRecommendation'] is JsonMap &&
          (j['meetingRecommendation'] as JsonMap)['enabled'] == true,
      geocoding:
          enabled &&
          j['geocoding'] is JsonMap &&
          (j['geocoding'] as JsonMap)['enabled'] == true,
    );
  }
  final bool enabled, recommendation, geocoding;
}

class PlanRouteRequest {
  const PlanRouteRequest({
    required this.planId,
    required this.planRevision,
    required this.followRequestId,
    required this.guidanceGeneration,
    required this.calculationId,
    required this.requestId,
    required this.routeKind,
    required this.originRef,
    this.traceAnchor,
  });
  final String planId, calculationId, requestId;
  final String? followRequestId;
  final int planRevision, guidanceGeneration;
  final PlanRouteKind routeKind;
  final SampleRef originRef;
  final RouteAnchor? traceAnchor;
  JsonMap get anchor => switch (routeKind) {
    PlanRouteKind.planJoin => {'kind': 'joinPoint'},
    PlanRouteKind.planDestination => {'kind': 'destination'},
    PlanRouteKind.traceRejoin => traceAnchor!.toJson(),
  };
  JsonMap toJson() => {
    'schemaVersion': 2,
    'planId': planId,
    'planRevision': planRevision,
    'followRequestId': followRequestId,
    'guidanceGeneration': guidanceGeneration,
    'calculationId': calculationId,
    'requestId': requestId,
    'routeKind': routeKind.name,
    'originRef': originRef.toJson(),
    'anchor': anchor,
  };
  bool matches(JsonMap j) =>
      j['schemaVersion'] == 2 &&
      j['routeKind'] == routeKind.name &&
      j['planId'] == planId &&
      j['planRevision'] == planRevision &&
      j['followRequestId'] == followRequestId &&
      j['guidanceGeneration'] == guidanceGeneration &&
      j['calculationId'] == calculationId &&
      j['requestId'] == requestId;
  FollowRouteResult parseResult(JsonMap j) {
    if (!matches(j) ||
        j['schemaVersion'] != 2 ||
        j['routeKind'] != routeKind.name ||
        SampleRef.fromJson(j['originRef']) != originRef)
      throw const FormatException('계획 경로 문맥 오류');
    final a = meetingObject(j['anchor']);
    if (routeKind == PlanRouteKind.traceRejoin
        ? RouteAnchor.fromJson(a) != traceAnchor
        : a.length != 1 || a['kind'] != anchor['kind'])
      throw const FormatException('계획 경로 목표 오류');
    return FollowRouteResult.fromPayload(
      j,
      destinationEndpoint: routeKind == PlanRouteKind.planDestination,
      rejoinEndpoint: routeKind == PlanRouteKind.traceRejoin,
    );
  }
}

class PlanTraceContext {
  const PlanTraceContext(this.planId, this.revision, this.start);
  final String planId;
  final int revision;
  final RouteAnchor start;
  Object get identity => (planId, revision, start);
}

class AddressResult {
  const AddressResult(this.point, this.roadAddress, this.jibunAddress);
  factory AddressResult.fromJson(Object? value) {
    final j = meetingObject(value);
    return AddressResult(
      RoutePoint.fromJson(j),
      j['roadAddress'] as String? ?? '',
      j['jibunAddress'] as String? ?? '',
    );
  }
  final RoutePoint point;
  final String roadAddress, jibunAddress;
  String get label => roadAddress.isNotEmpty ? roadAddress : jibunAddress;
}

class MeetingRecommendation {
  MeetingRecommendation.fromJson(JsonMap j) {
    if (!{'candidate', 'destinationOnly'}.contains(j['result']))
      throw const FormatException('합류 추천 결과 오류');
    destinationOnly = j['result'] == 'destinationOnly';
    joinPoint = MeetingPoint.fromJson(j['joinPoint']);
    calculatedAtMs = meetingInt(j['calculatedAtMs']);
    etaQuality = meetingString(j['etaQuality']);
    vehicles = List.unmodifiable(
      (j['arrivals'] as List).map((v) {
        final e = meetingObject(v);
        return (
          handle: meetingString(e['handle']),
          seconds: _optionalNumber(e['etaToJoinSeconds'])!,
          waitSeconds: _optionalNumber(e['waitSeconds'])!,
        );
      }),
    );
    remainingMeters = _optionalNumber(j['remainingToDestinationMeters'])!;
    remainingSeconds = _optionalNumber(j['remainingToDestinationSeconds'])!;
  }
  late final MeetingPoint joinPoint;
  late final bool destinationOnly;
  late final int calculatedAtMs;
  late final String etaQuality;
  late final double remainingMeters, remainingSeconds;
  late final List<({String handle, double seconds, double waitSeconds})>
  vehicles;
}

String meetingErrorText(String code) => switch (code) {
  'NO_ROUTE' => '경로를 찾을 수 없습니다. 지도에서 목적지와 합류 지점을 확인해 주세요',
  'ENDPOINT_MISMATCH' => '요청 지점이 도로에서 멀어 경로를 만들 수 없습니다. 지도에서 도로 쪽으로 옮겨 주세요',
  'STOP_REQUIRED' => '정차가 확인된 뒤 설정할 수 있습니다',
  'LOCATION_NOT_READY' => '위치와 정차 상태를 확인하고 있습니다',
  'PLAN_LOCKED' => '참여한 차량이 있어 수정할 수 없습니다. 정차 후 계획을 취소해 주세요',
  'PLAN_CHANGED' || 'RUNTIME_CHANGED' => '합류 계획이 변경되었습니다. 최신 상태를 확인해 주세요',
  'PLAN_NOT_READY' => '그룹장이 목적지와 합류 지점을 확정해야 합니다',
  'PLAN_DEPARTED' => '이미 출발한 계획에는 새로 참여할 수 없습니다',
  'DEPARTURE_NOT_READY' => '그룹장과 참여 차량 모두의 도착을 기다립니다',
  'CONSENT_REQUIRED_SELF' ||
  'CONSENT_REQUIRED_TARGET' ||
  'CONSENT_REQUIRED_PARTICIPANT' => '추천 대상 모두의 최신 개인정보·위치 동의가 필요합니다',
  'NO_PARTICIPANTS' => '수락된 따라오기 차량을 선택해 주세요',
  'TOO_MANY_PARTICIPANTS' => '그룹장을 포함해 최대 8대까지 추천할 수 있습니다',
  'RECOMMENDATION_STALE' => '위치가 달라졌습니다. 정차 후 다시 추천해 주세요',
  'RECOMMENDATION_TOO_LARGE' => '경로가 길어 추천할 수 없습니다. 합류 지점을 직접 선택해 주세요',
  'GEOCODING_DISABLED' => '주소 검색을 사용할 수 없습니다. 지도에서 선택해 주세요',
  'SEARCH_TIMEOUT' || 'SEARCH_UNAVAILABLE' => '주소 검색에 실패했습니다. 다시 검색해 주세요',
  'PLAN_NOT_OWNER' ||
  'PLAN_NOT_PARTICIPANT' ||
  'NOT_ACTIVE_SENDER' => '합류 계획 참여 권한을 확인해 주세요',
  'TRACE_UNAVAILABLE' => '이어서 따라갈 이동 경로가 없습니다',
  'RATE_LIMITED' || 'ROUTE_IN_PROGRESS' => '요청 가능 시각까지 기다려 주세요',
  'PASS_NOT_CONFIRMED' => '합류 상태 확인 중',
  _ => '합류 계획 요청을 처리하지 못했습니다. 다시 확인해 주세요',
};
