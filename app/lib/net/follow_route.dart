import 'dart:async';

import 'models.dart';

enum FollowMode { a, meetingPoint }

/// Schema 1 still calls these A/B. They describe the route input, not the
/// user's follow mode: B is now used only for automatic trace rejoining.
enum FollowRouteKind { initial, rejoin }

enum FollowPhase { approaching, onTrace }

// Keep D-only endpoint tolerance in sync with server/route_providers/naver.ts.
const destinationEndpointGapMeters = 100.0;
// Rejoin payloads retain the real point gap. The controller must additionally
// verify the forward trace interval, lateral distance and arrival direction.
const traceRejoinForwardMeters = 120.0;
const traceRejoinEndpointGapMeters = traceRejoinForwardMeters + 25;

class RoutePoint {
  const RoutePoint(this.lat, this.lng);
  factory RoutePoint.fromFix(LocationFix fix) => RoutePoint(fix.lat, fix.lng);
  factory RoutePoint.fromJson(Object? value) {
    if (value is! JsonMap) throw const FormatException('경로 좌표 오류');
    final lat = value['lat'], lng = value['lng'];
    if (lat is! num ||
        lng is! num ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat.abs() > 90 ||
        lng.abs() > 180) {
      throw const FormatException('경로 좌표 오류');
    }
    return RoutePoint(lat.toDouble(), lng.toDouble());
  }
  final double lat, lng;
  @override
  bool operator ==(Object other) =>
      other is RoutePoint && lat == other.lat && lng == other.lng;
  @override
  int get hashCode => Object.hash(lat, lng);
}

class SampleRef {
  const SampleRef(this.stream, this.seq);
  factory SampleRef.of(LocationFix fix) => SampleRef(fix.stream, fix.seq);
  factory SampleRef.fromJson(Object? value) {
    if (value is! JsonMap ||
        value['stream'] is! String ||
        value['seq'] is! int ||
        (value['seq'] as int) < 0)
      throw const FormatException('경로 표본 참조 오류');
    return SampleRef(value['stream'] as String, value['seq'] as int);
  }
  final String stream;
  final int seq;
  JsonMap toJson() => {'stream': stream, 'seq': seq};
  @override
  bool operator ==(Object other) =>
      other is SampleRef && stream == other.stream && seq == other.seq;
  @override
  int get hashCode => Object.hash(stream, seq);
}

class RouteAnchor {
  const RouteAnchor.sample(SampleRef ref)
    : start = ref,
      end = null,
      fraction = 0;
  const RouteAnchor.segment(this.start, SampleRef this.end, this.fraction);
  factory RouteAnchor.fromJson(Object? value) {
    if (value is! JsonMap) throw const FormatException('경로 기준점 오류');
    if (value['kind'] == 'sample')
      return RouteAnchor.sample(SampleRef.fromJson(value['ref']));
    final fraction = value['fraction'];
    if (value['kind'] != 'segment' ||
        fraction is! num ||
        !fraction.isFinite ||
        fraction < 0 ||
        fraction > 1)
      throw const FormatException('경로 기준점 오류');
    return RouteAnchor.segment(
      SampleRef.fromJson(value['startRef']),
      SampleRef.fromJson(value['endRef']),
      fraction.toDouble(),
    );
  }
  final SampleRef start;
  final SampleRef? end;
  final double fraction;
  JsonMap toJson() => end == null
      ? {'kind': 'sample', 'ref': start.toJson()}
      : {
          'kind': 'segment',
          'startRef': start.toJson(),
          'endRef': end!.toJson(),
          'fraction': fraction,
        };
  @override
  bool operator ==(Object other) =>
      other is RouteAnchor &&
      start == other.start &&
      end == other.end &&
      fraction == other.fraction;
  @override
  int get hashCode => Object.hash(start, end, fraction);
}

class FollowRouteRequest {
  const FollowRouteRequest({
    required this.followRequestId,
    required this.guidanceGeneration,
    required this.calculationId,
    required this.requestId,
    required this.mode,
    required this.originRef,
    required this.anchor,
  });
  final String followRequestId, calculationId, requestId;
  final int guidanceGeneration;
  final FollowRouteKind mode;
  final SampleRef originRef;
  final RouteAnchor anchor;
  JsonMap toJson() => {
    'schemaVersion': 1,
    'followRequestId': followRequestId,
    'guidanceGeneration': guidanceGeneration,
    'calculationId': calculationId,
    'requestId': requestId,
    'mode': mode == FollowRouteKind.initial ? 'A' : 'B',
    'originRef': originRef.toJson(),
    'anchor': anchor.toJson(),
  };
  bool matches(JsonMap json) =>
      json['followRequestId'] == followRequestId &&
      json['guidanceGeneration'] == guidanceGeneration &&
      json['calculationId'] == calculationId &&
      json['requestId'] == requestId;
}

class FollowRouteResult {
  FollowRouteResult.fromJson(JsonMap json, FollowRouteRequest request)
    : this.fromPayload(
        _validate(json, request),
        rejoinEndpoint: request.mode == FollowRouteKind.rejoin,
      );

  static JsonMap _validate(JsonMap json, FollowRouteRequest request) {
    if (!request.matches(json) ||
        json['schemaVersion'] != 1 ||
        json['mode'] != (request.mode == FollowRouteKind.initial ? 'A' : 'B') ||
        SampleRef.fromJson(json['originRef']) != request.originRef ||
        RouteAnchor.fromJson(json['anchor']) != request.anchor ||
        json['provider'] != 'naver' ||
        json['routeOption'] != 'traoptimal') {
      throw const FormatException('경로 응답 문맥 오류');
    }
    return json;
  }

  /// Shared geometry parser. Schema-specific callers validate their own identity.
  FollowRouteResult.fromPayload(
    JsonMap json, {
    bool destinationEndpoint = false,
    bool rejoinEndpoint = false,
  }) {
    if (json['provider'] != 'naver' || json['routeOption'] != 'traoptimal') {
      throw const FormatException('경로 제공처 오류');
    }
    double number(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite || value < 0)
        throw const FormatException('경로 수치 오류');
      return value.toDouble();
    }

    origin = RoutePoint.fromJson(json['requestedOrigin']);
    anchor = RoutePoint.fromJson(json['requestedAnchor']);
    meters = number('meters');
    seconds = number('seconds');
    serverNowMs = number('serverNowMs');
    atAnchor = json['result'] == 'atAnchor';
    final raw = json['points'];
    if (raw is! List || raw.length > 50000)
      throw const FormatException('경로 형상 오류');
    points = List.unmodifiable(raw.map(RoutePoint.fromJson));
    if (atAnchor) {
      if (points.isNotEmpty ||
          meters != 0 ||
          seconds != 0 ||
          json['actualStart'] != null ||
          json['actualEnd'] != null ||
          json['startGapMeters'] != null ||
          json['endGapMeters'] != null) {
        throw const FormatException('기준점 응답 오류');
      }
      actualStart = actualEnd = null;
    } else {
      if (json['result'] != 'route' ||
          points.toSet().length < 2 ||
          meters <= 0 ||
          number('startGapMeters') > 25 ||
          number('endGapMeters') >
              (rejoinEndpoint
                  ? traceRejoinEndpointGapMeters
                  : destinationEndpoint
                  ? destinationEndpointGapMeters
                  : 25)) {
        throw const FormatException('경로 형상 오류');
      }
      actualStart = RoutePoint.fromJson(json['actualStart']);
      actualEnd = RoutePoint.fromJson(json['actualEnd']);
    }
  }
  late final RoutePoint origin, anchor;
  late final RoutePoint? actualStart, actualEnd;
  late final List<RoutePoint> points;
  late final double meters, seconds, serverNowMs;
  late final bool atAnchor;
}

class FollowRouteException implements Exception {
  const FollowRouteException(
    this.code, {
    this.retryable = false,
    this.retryAfterMs = 0,
    this.inputAccepted = false,
    this.inputExpiresAtMs,
    this.identity,
  });
  factory FollowRouteException.fromJson(JsonMap json) {
    final error = json['error'];
    if (error is! JsonMap || error['code'] is! String) {
      return const FollowRouteException('INVALID_PROVIDER_RESPONSE');
    }
    return FollowRouteException(
      error['code'] as String,
      retryable: error['retryable'] == true,
      retryAfterMs: error['retryAfterMs'] is num
          ? (error['retryAfterMs'] as num).toInt().clamp(0, 3600000)
          : 0,
      inputAccepted: json['inputAccepted'] == true,
      inputExpiresAtMs: (json['inputExpiresAtMs'] as num?)?.toInt(),
      identity: json,
    );
  }
  final String code;
  final bool retryable, inputAccepted;
  final int retryAfterMs;
  final int? inputExpiresAtMs;
  final JsonMap? identity;
  @override
  String toString() => '추천 경로 요청을 처리하지 못했습니다';
}

/// Each route owns its connection; cancellation never closes location/SSE HTTP.
class RouteCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}
