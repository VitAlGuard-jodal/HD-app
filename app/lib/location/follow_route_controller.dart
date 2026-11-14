import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../net/follow_route.dart';
import '../net/models.dart';
import '../net/meeting_plan.dart';
import 'follow_route_geometry.dart';
import 'follow_route_diagnostics.dart';

export '../net/follow_route.dart' show FollowMode, FollowPhase, RoutePoint;

enum FollowRouteCondition {
  waitingLocation,
  waitingTrace,
  atAnchorWaitingTrace,
  calculating,
  ready,
  locationDelayed,
  poorAccuracy,
  offRoute,
  ambiguousRoute,
  routeMismatch,
  traceBroken,
  noRoute,
  resetRequired,
  consentRequired,
  authorizationBlocked,
  disabled,
  retryWaiting,
}

FollowRouteCondition holdRouteDeparture(
  FollowRouteCondition condition, {
  bool ambiguous = false,
  bool departed = false,
}) => condition == FollowRouteCondition.offRoute && !departed
    ? ambiguous
          ? FollowRouteCondition.ambiguousRoute
          : FollowRouteCondition.routeMismatch
    : condition;

bool canResumeUnacceptedRoute(
  GuidanceRouteProjection? projection,
  FollowRouteCondition condition, {
  required bool departed,
}) =>
    !departed &&
    projection?.usable == true &&
    {
      FollowRouteCondition.ambiguousRoute,
      FollowRouteCondition.routeMismatch,
    }.contains(condition);

class FollowRouteInput {
  const FollowRouteInput({
    required this.room,
    required this.account,
    required this.device,
    required this.relationship,
    required this.target,
    required this.self,
    required this.origin,
    required this.leader,
    required this.selfAgeMs,
    required this.originAgeMs,
    required this.leaderAgeMs,
    required this.trace,
    required this.consent,
    required this.connected,
    this.restored = false,
    this.serverNowMs,
    this.routingEnabled = true,
    this.planTrace,
    this.planCondition,
    this.planApproachRoute,
  });
  final String room, account, device, relationship, target;
  final LocationFix? self, origin, leader;
  final double selfAgeMs, originAgeMs, leaderAgeMs;
  final List<LocationFix> trace;
  final bool consent, connected, restored;
  final num? serverNowMs;
  final bool routingEnabled;
  final PlanTraceContext? planTrace;
  final String? planCondition;
  final FollowRouteResult? planApproachRoute;
  Object get identity =>
      (room, account, device, relationship, target, planTrace?.identity);
}

/// Memory belongs to RoomSession, never to a map or panel widget.
class FollowGuidance {
  FollowGuidance(this.identity, this.relationship);
  final Object identity;
  final String relationship;
  FollowMode mode = FollowMode.a;
  FollowPhase phase = FollowPhase.approaching;
  FollowRouteCondition condition = FollowRouteCondition.waitingLocation;
  RouteAnchor? anchor, progress;
  num? progressAt, anchorAt;
  RoutePoint? anchorPoint, originPoint;
  SampleRef? originRef;
  FollowRouteResult? route;
  int generation = 0, joinRound = 0;
  int? retrySeconds;
  double routeProgress = 0;
  bool anchorConfirmed = false, anchorReached = false;
  bool rejoining = false, aheadOfTrace = false;
  List<List<RoutePoint>> activeTrace = const [];
  List<RoutePoint> get connector =>
      phase == FollowPhase.approaching &&
          !aheadOfTrace &&
          !(rejoining && subdued) &&
          condition != FollowRouteCondition.offRoute &&
          condition != FollowRouteCondition.resetRequired &&
          condition != FollowRouteCondition.traceBroken
      ? route?.points ?? const []
      : const [];
  RoutePoint? get marker =>
      phase == FollowPhase.approaching &&
          !aheadOfTrace &&
          !(rejoining && subdued) &&
          !{
            FollowRouteCondition.offRoute,
            FollowRouteCondition.routeMismatch,
            FollowRouteCondition.noRoute,
            FollowRouteCondition.resetRequired,
            FollowRouteCondition.disabled,
          }.contains(condition)
      ? anchorPoint
      : null;
  bool get subdued => {
    FollowRouteCondition.waitingLocation,
    FollowRouteCondition.locationDelayed,
    FollowRouteCondition.poorAccuracy,
    FollowRouteCondition.consentRequired,
    FollowRouteCondition.authorizationBlocked,
    FollowRouteCondition.traceBroken,
  }.contains(condition);
  String get modeLabel => mode == FollowMode.a ? '따라가기' : '합류 지점 따라가기';
  FollowRouteView? _view;
  FollowRouteView get view {
    final previous = _view;
    final line = connector;
    if (previous != null &&
        previous.mode == mode &&
        previous.phase == phase &&
        previous.condition == condition &&
        identical(previous.connector, line) &&
        identical(previous.trace, activeTrace) &&
        previous.anchor == marker &&
        previous.confirmed == anchorConfirmed &&
        previous.subdued == subdued &&
        previous.rejoining == rejoining &&
        previous.status == status)
      return previous;
    return _view = FollowRouteView(
      mode: mode,
      phase: phase,
      condition: condition,
      connector: line,
      trace: activeTrace,
      anchor: marker,
      confirmed: anchorConfirmed,
      subdued: subdued,
      status: status,
      rejoining: rejoining,
    );
  }

  String get status =>
      aheadOfTrace &&
          !subdued &&
          {
            FollowRouteCondition.ready,
            FollowRouteCondition.offRoute,
            FollowRouteCondition.calculating,
            FollowRouteCondition.retryWaiting,
            FollowRouteCondition.noRoute,
            FollowRouteCondition.waitingTrace,
          }.contains(condition)
      ? '앞쪽 이동 경로를 기다립니다'
      : switch (condition) {
          FollowRouteCondition.waitingLocation => '위치 확인 중',
          FollowRouteCondition.waitingTrace => '이동 경로 대기',
          FollowRouteCondition.atAnchorWaitingTrace => '기준 지점 근처 · 이동 경로 대기',
          FollowRouteCondition.calculating =>
            rejoining ? '재합류 경로 계산 중' : '추천 경로 계산 중',
          FollowRouteCondition.ready =>
            phase == FollowPhase.onTrace
                ? '앞차가 지나간 경로를 따라갑니다'
                : rejoining
                ? '회색 경로를 따라 다시 합류'
                : mode == FollowMode.meetingPoint
                ? '앞차 이동 경로 확인 중'
                : '추천 경로로 기준 지점까지 이동',
          FollowRouteCondition.locationDelayed => '위치 갱신 대기',
          FollowRouteCondition.poorAccuracy => '위치 정확도 확인 중',
          FollowRouteCondition.offRoute => '경로를 벗어났습니다',
          FollowRouteCondition.ambiguousRoute => '경로가 겹쳐 현재 위치 확인 중',
          FollowRouteCondition.routeMismatch => '현재 위치에서 경로를 확인 중입니다',
          FollowRouteCondition.traceBroken => '이어서 따라갈 이동 경로가 끊겼습니다',
          FollowRouteCondition.noRoute =>
            rejoining ? _rejoinFailureStatus : '추천 경로를 찾지 못했습니다',
          FollowRouteCondition.resetRequired => '정차 후 안내를 다시 설정해 주세요',
          FollowRouteCondition.consentRequired => '나와 앞차의 최신 위치 동의가 필요합니다',
          FollowRouteCondition.authorizationBlocked => '참여 권한 확인이 필요합니다',
          FollowRouteCondition.disabled => '추천 경로 기능을 사용할 수 없습니다',
          FollowRouteCondition.retryWaiting =>
            rejoining ? _rejoinFailureStatus : '추천 경로 다시 시도 대기',
        };

  String get _rejoinFailureStatus => retrySeconds == null
      ? '경로를 벗어났습니다 · 재합류 경로를 찾지 못했습니다'
      : retrySeconds! > 0
      ? '경로를 벗어났습니다 · 재합류 경로 재시도 대기 · ${retrySeconds}초'
      : '경로를 벗어났습니다 · 이동 확인 후 재합류 경로를 다시 찾습니다';
}

class FollowRouteView {
  const FollowRouteView({
    required this.mode,
    required this.phase,
    required this.condition,
    required this.connector,
    required this.trace,
    required this.anchor,
    required this.confirmed,
    required this.subdued,
    required this.status,
    this.rejoining = false,
  });
  final FollowMode mode;
  final FollowPhase phase;
  final FollowRouteCondition condition;
  final List<RoutePoint> connector;
  final List<List<RoutePoint>> trace;
  final RoutePoint? anchor;
  final bool confirmed, subdued, rejoining;
  final String status;
  String get anchorLabel => !rejoining
      ? mode == FollowMode.meetingPoint
            ? '합류 후 이동 경로 시작'
            : '처음 앞차 위치'
      : confirmed
      ? '재합류 지점'
      : '재합류 지점 후보';
}

typedef FollowRouteLoader =
    Future<FollowRouteResult> Function(
      String room,
      FollowRouteRequest request,
      RouteCancellation cancellation,
    );

class FollowRouteController extends ChangeNotifier {
  FollowRouteController({
    required this.load,
    required this.canChange,
    required this.onJoined,
    required this.onDeparted,
    required this.onInvalidated,
    int Function()? now,
    this.onAuthorizationError,
    this.loadPlan,
  }) {
    final clock = Stopwatch()..start();
    _now = now ?? () => clock.elapsedMilliseconds;
  }
  final FollowRouteLoader load;
  final Future<FollowRouteResult> Function(
    String,
    PlanRouteRequest,
    RouteCancellation,
  )?
  loadPlan;
  final bool Function() canChange;
  final void Function(String relationship, int round, bool rejoined) onJoined;
  final void Function(String relationship, int round) onDeparted;
  final VoidCallback onInvalidated;
  final void Function(String code)? onAuthorizationError;
  late final int Function() _now;
  FollowGuidance? _state;
  FollowGuidance? get state => _state;
  FollowRouteInput? _input;
  List<TracePath> _paths = const [];
  List<LocationFix>? _traceSource;
  TracePath? _renderedPath;
  RouteAnchor? _renderedRef;
  RouteCancellation? _cancellation;
  FollowRouteRequest? _request;
  FollowRouteResult? _pendingResult;
  FollowRouteResult? _rejectedRoute;
  bool _rejectedAfterDeparture = false;
  num? _routeObservedAt;
  final _forwardRoute = ForwardRouteEvidence();
  FollowRouteCondition? _beforeHold;
  String? _calculation;
  int _generation = 0, _ids = 0, _retries = 0, _extraCandidates = 0;
  int? _lastAttempt, _nextAttempt, _expires, _inputAt, _offSince, _joinSince;
  int _offSamples = 0, _joinSamples = 0;
  int? _reverseSince;
  int _reverseSamples = 0, _departureRound = 0;
  final _recoveries = <int>[];
  RouteAnchor? _rejoinFloor;
  bool _moving = false;
  double? _joinStart, _joinLast;
  LocationFix? _lastSelf, _directionBase;
  RouteAnchor? _tracking;
  bool _disposed = false,
      _offRoute = false,
      _extraPending = false,
      _retryOnLocation = false;
  bool _hadAnchorInTrace = false;
  bool _selfConsentBlocked = false;
  bool _featureBlocked = false;
  String? _diagnosticState;
  int? _diagnosticAt;
  String? get calculationId => _calculation;
  bool get calculating => _cancellation != null;

  void update(FollowRouteInput? input) {
    if (_disposed) return;
    if (input == null) {
      clear();
      return;
    }
    _input = input;
    if (_state?.identity != input.identity) {
      clear();
      _input = input;
      _state = FollowGuidance(input.identity, input.relationship)
        ..generation = ++_generation;
      if (input.planTrace != null) _state!.mode = FollowMode.meetingPoint;
      if (input.restored)
        _state!.condition = FollowRouteCondition.resetRequired;
    }
    if (!identical(_traceSource, input.trace)) {
      _traceSource = input.trace;
      _paths = splitFollowTrace(input.trace);
    }
    _evaluate();
    _syncRetryStatus();
    if (kDebugMode) _logDiagnostic();
    notifyListeners();
  }

  void _logDiagnostic() {
    String age(double value) => value.isFinite ? '${value.round()}' : 'unknown';
    final s = _state!, path = _activePath();
    final state =
        '${s.phase.name}/${s.condition.name}/${_paths.length}/${path != null}';
    if (_diagnosticState == state &&
        (s.phase == FollowPhase.onTrace ||
            _diagnosticAt != null && _now() - _diagnosticAt! < 5000))
      return;
    _diagnosticState = state;
    _diagnosticAt = _now();
    final index = path == null ? -1 : _paths.indexOf(path);
    final next = index >= 0 && index + 1 < _paths.length
        ? _paths[index + 1].fixes.first
        : null;
    final tail = path?.fixes.last;
    // Debug builds only. No coordinates, account IDs or provider geometry.
    // Distinguish a missing seed, a broken P0 branch, and join-evidence delay.
    debugPrint(
      'follow-guidance: $state '
      'trace=${_input!.trace.length} active=${path?.fixes.length ?? 0} '
      'anchorSeq=${s.anchor?.start.seq} selfSeq=${_input!.self?.seq} '
      'anchorReached=${s.anchorReached} joins=$_joinSamples '
      'selfAge=${age(_input!.selfAgeMs)} leaderAge=${age(_input!.leaderAgeMs)} '
      'badQuality=${_input!.trace.where((f) => !routeQuality(f)).length}'
      '${tail == null || next == null ? '' : ' gapSeq=${next.seq - tail.seq} gapMs=${next.at - tail.at} sameStream=${next.stream == tail.stream}'}',
    );
  }

  bool changeMode(FollowMode mode) {
    // Meeting-point following is reserved for the next design round.
    return false;
  }

  bool reset() {
    final s = _state;
    if (s == null || !canChange()) return false;
    _invalidate();
    _clearCalculation();
    s.phase = FollowPhase.approaching;
    s.anchor = s.progress = null;
    s.progressAt = null;
    s.anchorPoint = null;
    s.condition = FollowRouteCondition.waitingLocation;
    _tracking = null;
    _offRoute = false;
    s.rejoining = s.aheadOfTrace = false;
    _rejoinFloor = null;
    _evaluate();
    _syncRetryStatus();
    notifyListeners();
    return true;
  }

  bool get _fresh {
    final i = _input!;
    return i.connected &&
        i.planCondition == null &&
        i.self != null &&
        i.leader != null &&
        i.selfAgeMs <= 10000 &&
        i.leaderAgeMs <= 10000 &&
        routeQuality(i.self!) &&
        routeQuality(i.leader!);
  }

  void _evaluate() {
    final s = _state!, i = _input!;
    if (!i.routingEnabled) {
      if (!_featureBlocked) _invalidate();
      _featureBlocked = true;
      s.route = null;
      _updateTrace();
      if (s.anchor == null)
        s.activeTrace = _paths.map((path) => path.points).toList();
      s.condition = FollowRouteCondition.disabled;
      return;
    }
    if (_featureBlocked) {
      _featureBlocked = false;
      s.condition = s.anchor == null && !i.restored
          ? FollowRouteCondition.waitingLocation
          : FollowRouteCondition.resetRequired;
    }
    if (!i.consent) {
      _selfConsentBlocked = true;
      if (s.condition != FollowRouteCondition.consentRequired) {
        _invalidate();
        s.route = null;
      }
      s.condition = FollowRouteCondition.consentRequired;
      return;
    }
    if (_selfConsentBlocked) {
      _selfConsentBlocked = false;
      s.condition = s.anchor == null
          ? FollowRouteCondition.waitingLocation
          : FollowRouteCondition.resetRequired;
    }
    _updateTrace();
    if (i.planCondition != null) {
      final hold = switch (i.planCondition) {
        'poorAccuracy' => FollowRouteCondition.poorAccuracy,
        'consentRequired' => FollowRouteCondition.consentRequired,
        'traceUnavailable' => FollowRouteCondition.traceBroken,
        _ => FollowRouteCondition.locationDelayed,
      };
      if ((hold == FollowRouteCondition.consentRequired ||
              hold == FollowRouteCondition.traceBroken) &&
          s.condition != hold) {
        _invalidate();
        s.route = null;
      }
      _hold(hold);
      return;
    }
    if (i.self == null || i.leader == null) {
      _hold(FollowRouteCondition.waitingLocation);
      return;
    }
    if (!i.connected || i.selfAgeMs > 10000 || i.leaderAgeMs > 10000) {
      _hold(FollowRouteCondition.locationDelayed);
      return;
    }
    if (!routeQuality(i.self!) || !routeQuality(i.leader!)) {
      _hold(FollowRouteCondition.poorAccuracy);
      return;
    }
    if (_beforeHold != null) {
      s.condition = _beforeHold!;
      _beforeHold = null;
    }
    _updateTrace();
    if (_pendingResult != null) {
      final result = _pendingResult!;
      _pendingResult = null;
      _applyResult(result);
    }
    if (s.anchor == null &&
        {
          FollowRouteCondition.waitingLocation,
          FollowRouteCondition.waitingTrace,
        }.contains(s.condition)) {
      if (i.planTrace != null) {
        _primePlanTrace(i.planTrace!);
      } else {
        _start();
      }
      return;
    }
    if ({
      FollowRouteCondition.resetRequired,
      FollowRouteCondition.consentRequired,
      FollowRouteCondition.authorizationBlocked,
      FollowRouteCondition.disabled,
      FollowRouteCondition.traceBroken,
    }.contains(s.condition))
      return;
    if (s.condition == FollowRouteCondition.noRoute && !s.rejoining) return;

    final fix = i.self!, previous = _lastSelf;
    final newSample =
        previous == null || SampleRef.of(previous) != SampleRef.of(fix);
    if (newSample) {
      _lastSelf = fix;
      if (_retryOnLocation &&
          !s.rejoining &&
          previous != null &&
          fix.at > previous.at &&
          !calculating) {
        _retryOnLocation = false;
        _send();
      }
      double? direction;
      var moved = 0.0;
      _moving = false;
      if (previous != null) {
        moved = routeDistance(
          RoutePoint.fromFix(previous),
          RoutePoint.fromFix(fix),
        );
        final dt = (fix.at - previous.at) / 1000;
        if (previous.stream != fix.stream ||
            fix.seq <= previous.seq ||
            dt <= 0 ||
            dt > 10 ||
            moved >
                70 * dt +
                    routeAccuracyAllowance(previous)! +
                    routeAccuracyAllowance(fix)!) {
          _resetEvidence();
          if (!s.rejoining) _offRoute = false;
          _directionBase = fix;
          s.anchorReached = false;
          s.condition = holdRouteDeparture(s.condition, departed: s.rejoining);
          // Resume geometry after a gap, with no motion or join evidence.
          // Reordered refs and implausible jumps still cannot advance it.
          if (previous.stream == fix.stream &&
              fix.seq > previous.seq &&
              dt > 10 &&
              moved <=
                  70 * dt +
                      routeAccuracyAllowance(previous)! +
                      routeAccuracyAllowance(fix)!) {
            _judge(fix, moved, null);
          }
          return;
        }
        final base =
            moved >= 2.999999 ||
                _directionBase == null ||
                (fix.at - _directionBase!.at) > 10000
            ? previous
            : _directionBase!;
        final displacement = routeDistance(
          RoutePoint.fromFix(base),
          RoutePoint.fromFix(fix),
        );
        final seconds = (fix.at - base.at) / 1000;
        final speed = fix.speed;
        _moving = speed != null
            ? speed.isFinite && speed >= 2
            : displacement >= 2.999999 && displacement / seconds >= 1.999999;
        if (_moving && displacement >= 2.999999) {
          direction = routeBearing(
            RoutePoint.fromFix(base),
            RoutePoint.fromFix(fix),
          );
          _directionBase = previous;
        } else {
          _directionBase = speed != null && speed < 2 ? fix : base;
        }
      }
      if (!_moving) {
        // A stop/unknown movement breaks the continuous evidence. It must not
        // turn a parked car or GPS jitter into a delayed automatic request.
        _resetEvidence();
        if (!s.rejoining) _offRoute = false;
        s.condition = holdRouteDeparture(s.condition, departed: s.rejoining);
      }
      _judge(fix, moved, direction);
      if (_retryOnLocation &&
          previous != null &&
          fix.at > previous.at &&
          !calculating &&
          (!s.rejoining || _moving)) {
        _retryOnLocation = false;
        _send();
      }
    }
    _recoverIfNeeded();
    _runScheduled();
  }

  TracePath? _recoveryPath() {
    final ref = _rejoinFloor;
    if (ref == null) return null;
    for (final path in _paths) {
      if (path.resolve(ref) != null) return path;
    }
    return null;
  }

  void _judge(LocationFix fix, double moved, double? direction) {
    final s = _state!;
    final path = s.rejoining ? _recoveryPath() : _activePath();
    final ref = s.rejoining ? _rejoinFloor : s.progress ?? s.anchor;
    final floor = ref == null ? null : path?.resolve(ref);
    final tracking = _tracking == null ? null : path?.resolve(_tracking!);
    final projection = path == null || floor == null
        ? null
        : projectRoute(
            RoutePoint.fromFix(fix),
            path.points,
            // Look behind only to observe reverse travel on the same local branch.
            // Stored progress and all new anchors still have a forward-only floor.
            minimum: s.phase == FollowPhase.onTrace && !s.rejoining
                ? math.max(0, (tracking ?? floor) - 120)
                : math.max(floor, (tracking ?? floor) - 3),
            maximum: math.max(
              (tracking ?? floor) + math.max(120, moved + 50),
              s.rejoining ? (path.resolve(s.anchor!) ?? floor) + 120 : 0,
            ),
          );
    final judgingRoute = s.route ?? _rejectedRoute;
    final advance = s.route == null
        ? math.max(120.0, moved + 50)
        : routeReachableAdvance(fix.at - (_routeObservedAt ?? fix.at));
    var connector = judgingRoute == null
        ? null
        : projectGuidanceRoute(
            RoutePoint.fromFix(fix),
            judgingRoute,
            progress: s.routeProgress,
            advance: advance,
            fallbackAdvance:
                s.route == null && !_rejectedAfterDeparture && moved > 0
                ? routeReachableAdvance(_now() - _inputAt!)
                : null,
          );
    if (s.route != null &&
        s.phase == FollowPhase.approaching &&
        !s.rejoining &&
        connector != null &&
        projection?.ambiguous != true) {
      final recovered = _forwardRoute.observe(
        s.route!,
        fix,
        connector,
        maximum: s.routeProgress + advance,
        moving: _moving,
        direction: direction,
      );
      if (recovered != null) {
        connector = GuidanceRouteProjection(
          connector.full,
          recovered,
          connector.distance,
          recovered.along,
          true,
        );
      }
    } else {
      _forwardRoute.reset();
    }
    _routeObservedAt = fix.at;
    final connectorProjection = connector?.window;
    if (connector != null) s.routeProgress = connector.progress;

    if (direction != null) {
      s.aheadOfTrace =
          path != null &&
          SampleRef.of(path.fixes.last) == SampleRef.of(_input!.leader!) &&
          isBeyondTraceEnd(RoutePoint.fromFix(fix), path.points, direction);
    }
    if (s.aheadOfTrace) {
      _resetEvidence();
      _offRoute = false;
      return;
    }
    if (projection?.ambiguous == true ||
        connectorProjection?.ambiguous == true) {
      _resetEvidence();
      if (!s.rejoining) _offRoute = false;
      _moving = false;
      s.anchorReached = false;
      s.condition = holdRouteDeparture(
        s.condition,
        ambiguous: true,
        departed: s.rejoining,
      );
      return;
    }
    final traceDistance = projection?.distance ?? double.infinity;
    // A progress window identifies the current visit; it is not the road.
    // After a tunnel or slow progress, a later part can still be under the car.
    final fullTraceDistance = path == null
        ? double.infinity
        : projectRoute(RoutePoint.fromFix(fix), path.points)?.distance ??
              double.infinity;
    final connectorDistance =
        judgingRoute?.atAnchor == true && s.anchorPoint != null
        ? routeDistance(RoutePoint.fromFix(fix), s.anchorPoint!)
        : connectorProjection?.distance ?? double.infinity;
    if (s.phase == FollowPhase.approaching &&
        s.route == null &&
        judgingRoute != null &&
        canResumeUnacceptedRoute(
          connector,
          s.condition,
          departed: _rejectedAfterDeparture,
        )) {
      _acceptResult(judgingRoute, connectorProjection);
    }
    final outside =
        fullTraceDistance > 60.000001 &&
        (s.phase == FollowPhase.onTrace ||
            judgingRoute != null && connector!.distance > 60.000001);
    if (_moving) {
      if (outside) {
        _offSince ??= _now();
        _offSamples++;
        _resetJoin();
        s.anchorReached = false;
      } else {
        _offSince = null;
        _offSamples = 0;
        if (!s.rejoining) _offRoute = false;
      }
      // During approach, use the connector tangent when it is the road being
      // followed. Trace direction alone would misclassify a valid approach.
      final tangent =
          s.phase == FollowPhase.approaching && connectorDistance <= 25.000001
          ? connectorProjection
          : traceDistance <= 25.000001
          ? projection
          : null;
      final reversed =
          direction != null &&
          tangent != null &&
          routeDirectionDifference(direction, tangent.bearing) >= 120;
      if (reversed) {
        _reverseSince ??= _now();
        _reverseSamples++;
      } else {
        _reverseSince = null;
        _reverseSamples = 0;
      }
      if (_offSince != null &&
              _now() - _offSince! >= 5000 &&
              _offSamples >= 3 ||
          _reverseSince != null &&
              _now() - _reverseSince! >= 10000 &&
              _reverseSamples >= 3) {
        _confirmDeparture();
      }
    }
    if (s.phase == FollowPhase.onTrace && !s.rejoining) {
      if (projection != null && projection.distance <= 25.000001) {
        // Tracking may resume after a gap, but authoritative progress still
        // requires a new measured direction on this branch.
        _tracking = path!.at(projection.along);
        if (direction != null &&
            routeDirectionDifference(direction, projection.bearing) <=
                60.000001 &&
            projection.along >= (floor ?? 0)) {
          s.progress = _tracking;
          s.progressAt = path.fixes[projection.index].at;
          _updateTrace();
        }
      }
      return;
    }
    if (!s.rejoining && _input!.planTrace == null) {
      if (s.route == null || s.anchorPoint == null) return;
      if (!s.anchorReached &&
          routeDistance(RoutePoint.fromFix(fix), s.anchorPoint!) <= 25.000001) {
        s.anchorReached =
            s.route!.atAnchor ||
            connectorProjection != null &&
                connectorProjection.distance <= 25.000001 &&
                connectorProjection.along >= routeLength(s.route!.points) - 25;
      }
    }
    // A return to the already selected branch can complete while a rejoin
    // request is pending/failed, even before its newly proposed anchor.
    if (projection == null || projection.distance > 25.000001) {
      _resetJoin();
      s.anchorReached = false;
      return;
    }
    if (_input!.planTrace != null && !s.rejoining) s.anchorReached = true;
    if ((!s.rejoining && !s.anchorReached) ||
        direction == null ||
        routeDirectionDifference(direction, projection.bearing) > 60.000001 ||
        projection.along < (floor ?? 0) ||
        _joinLast != null && projection.along < _joinLast!) {
      _resetJoin();
      return;
    }
    _joinSince ??= _now();
    _joinStart ??= projection.along;
    _joinLast = projection.along;
    _tracking = path!.at(projection.along);
    _joinSamples++;
    if (_joinSamples >= 3 &&
        _now() - _joinSince! >= 2000 &&
        projection.along - _joinStart! >= 10) {
      _finishJoin(path, projection);
    }
  }

  void _confirmDeparture() {
    final s = _state!;
    if (_offRoute) return;
    final first = !s.rejoining;
    final rejected = s.route ?? _rejectedRoute;
    final self = _lastSelf;
    if (first) _rejoinFloor = s.progress ?? s.anchor;
    _invalidate(clearVoice: first);
    _lastSelf = self;
    _moving = true;
    _rejectedRoute = rejected;
    _rejectedAfterDeparture = true;
    s.route = null;
    s.rejoining = true;
    s.condition = FollowRouteCondition.offRoute;
    _offRoute = true;
    if (first) onDeparted(s.relationship, ++_departureRound);
  }

  void _finishJoin(TracePath path, RouteProjection projection) {
    final s = _state!, rejoined = s.rejoining;
    _invalidate();
    _clearCalculation();
    s.phase = FollowPhase.onTrace;
    s.progress = _tracking = path.at(projection.along);
    s.progressAt = path.fixes[projection.index].at;
    s.condition = FollowRouteCondition.ready;
    s.rejoining = s.aheadOfTrace = false;
    _rejoinFloor = null;
    _offRoute = false;
    s.joinRound++;
    _updateTrace();
    onJoined(s.relationship, s.joinRound, rejoined);
  }

  void _runScheduled() {
    final s = _state!;
    if (s.phase != FollowPhase.approaching ||
        calculating ||
        (s.rejoining && (!_moving || s.aheadOfTrace)) ||
        s.condition == FollowRouteCondition.traceBroken)
      return;
    if (_expires != null &&
        _now() >= _expires! &&
        s.route == null &&
        (_nextAttempt != null || _retryOnLocation)) {
      _nextAttempt = null;
      s.condition = FollowRouteCondition.resetRequired;
      return;
    }
    if (_nextAttempt == null || _now() < _nextAttempt!) return;
    _nextAttempt = null;
    if (_extraPending) {
      _extraPending = false;
      _additionalCandidate();
    } else {
      _send();
    }
  }

  void _hold(FollowRouteCondition condition) {
    final s = _state!;
    _beforeHold ??= s.condition;
    s.condition = condition;
    _resetEvidence();
    if (!s.rejoining) _offRoute = false;
    _lastSelf = null;
    _directionBase = null;
    _moving = false;
  }

  TracePath? _activePath() {
    final s = _state!;
    final ref = s.phase == FollowPhase.onTrace
        ? s.progress ?? s.anchor
        : s.anchor;
    if (ref == null) return null;
    for (final path in _paths) {
      if (path.resolve(ref) != null) return path;
    }
    return null;
  }

  void _updateTrace() {
    final s = _state!;
    final path = _activePath();
    if (path == null || s.rejoining && _recoveryPath() == null) {
      _renderedPath = null;
      _renderedRef = null;
      s.activeTrace = const [];
      if (s.anchor != null &&
          (_hadAnchorInTrace ||
              s.anchorAt != null &&
                  _paths.any((p) => p.fixes.first.at > s.anchorAt!)) &&
          !{
            FollowRouteCondition.disabled,
            FollowRouteCondition.consentRequired,
            FollowRouteCondition.authorizationBlocked,
            FollowRouteCondition.resetRequired,
            FollowRouteCondition.noRoute,
          }.contains(s.condition)) {
        if (s.condition != FollowRouteCondition.traceBroken) _invalidate();
        s.route = null;
        s.condition = FollowRouteCondition.traceBroken;
        _resetEvidence();
      }
      return;
    }
    _hadAnchorInTrace = true;
    if (s.condition == FollowRouteCondition.waitingTrace &&
        s.route != null &&
        path.cumulative.last > (path.resolve(s.anchor!) ?? 0)) {
      s.condition = s.route!.atAnchor
          ? FollowRouteCondition.atAnchorWaitingTrace
          : FollowRouteCondition.ready;
    }
    final ref = s.phase == FollowPhase.onTrace
        ? s.progress ?? s.anchor!
        : s.anchor!;
    if (identical(_renderedPath, path) && _renderedRef == ref) return;
    _renderedPath = path;
    _renderedRef = ref;
    s.activeTrace = [path.after(path.resolve(ref)!)];
    // Preserve separate later sections for display, but never judge a join on
    // a straight line across the missing portion.
    final index = _paths.indexOf(path);
    s.activeTrace = List.unmodifiable([
      ...s.activeTrace,
      for (final later in _paths.skip(index + 1)) later.points,
    ]);
  }

  void _start({JoinCandidate? candidate, bool rejoin = false}) {
    final s = _state!, i = _input!;
    if (!_fresh || !i.consent) return;
    final origin = i.origin;
    if (origin == null || i.originAgeMs > 10000 || !routeQuality(origin)) {
      _hold(FollowRouteCondition.waitingLocation);
      return;
    }
    if (rejoin) {
      if (candidate == null || !_allowRecovery()) return;
      _recoveries.add(_now());
    }
    _invalidate(clearVoice: !rejoin);
    _offRoute = false;
    s.originRef = SampleRef.of(origin);
    s.originPoint = RoutePoint.fromFix(origin);
    s.anchor = candidate?.anchor ?? RouteAnchor.sample(SampleRef.of(i.leader!));
    s.anchorPoint = candidate?.point ?? RoutePoint.fromFix(i.leader!);
    s.anchorAt = candidate == null
        ? i.leader!.at
        : candidate.path.fixes
              .firstWhere((fix) => SampleRef.of(fix) == candidate.anchor.start)
              .at;
    s.anchorConfirmed = false;
    s.anchorReached = false;
    s.route = null;
    _rejectedRoute = null;
    s.routeProgress = 0;
    s.phase = FollowPhase.approaching;
    _tracking = null;
    _hadAnchorInTrace = false;
    _calculation = _id('calc');
    _inputAt = _now();
    _expires = _inputAt! + 120000;
    _retries = 0;
    _updateTrace();
    // Initial input validation goes to the server immediately even during its
    // provider cooldown. RATE_LIMITED must say whether it pinned these refs.
    _send();
  }

  void _primePlanTrace(PlanTraceContext plan) {
    final s = _state!;
    for (final path in _paths) {
      final along = path.resolve(plan.start);
      if (along == null) continue;
      s.anchor = plan.start;
      s.anchorPoint = path.pointAt(along);
      s.anchorAt = path.fixes
          .firstWhere((f) => SampleRef.of(f) == plan.start.start)
          .at;
      s.anchorConfirmed = true;
      s.route = _input!.planApproachRoute;
      // This retained connector has already reached J. Do not restart its
      // projection at the origin when entering the actual trace controller.
      s.routeProgress = s.route == null ? 0 : routeLength(s.route!.points);
      // Server already verified this round's J passage/departure. This only
      // opens the trace gate; direction + 3 samples / 2 s / 10 m still apply.
      s.anchorReached = true;
      s.condition = FollowRouteCondition.ready;
      _updateTrace();
      return;
    }
    s.condition =
        _paths.any(
          (p) =>
              p.fixes.first.stream != plan.start.start.stream ||
              p.fixes.first.seq > plan.start.start.seq,
        )
        ? FollowRouteCondition.traceBroken
        : FollowRouteCondition.waitingTrace;
  }

  void _recoverIfNeeded() {
    final s = _state!;
    if (!s.rejoining ||
        !_moving ||
        s.aheadOfTrace ||
        !_offRoute ||
        !_fresh ||
        calculating ||
        s.condition != FollowRouteCondition.offRoute ||
        _lastAttempt != null && _now() - _lastAttempt! < 30000)
      return;
    final path = _recoveryPath();
    if (path == null) {
      s.condition = FollowRouteCondition.traceBroken;
      return;
    }
    final candidate = selectJoinCandidate(RoutePoint.fromFix(_input!.self!), [
      path,
    ], progress: _rejoinFloor);
    if (candidate == null) return;
    _extraCandidates = 0;
    _start(candidate: candidate, rejoin: true);
  }

  bool _allowRecovery() {
    _recoveries.removeWhere((at) => _now() - at >= 300000);
    if (_recoveries.length < 3) return true;
    _invalidate();
    _state!.route = null;
    _state!.condition = FollowRouteCondition.resetRequired;
    return false;
  }

  String _id(String prefix) => '$prefix-${_now()}-${++_ids}';

  void _send() {
    final s = _state!, i = _input!;
    if (calculating ||
        !_fresh ||
        !i.consent ||
        s.anchor == null ||
        s.originRef == null ||
        _calculation == null)
      return;
    if (_expires != null && _now() >= _expires!) {
      s.condition = FollowRouteCondition.resetRequired;
      return;
    }
    final cancellation = RouteCancellation();
    _cancellation = cancellation;
    final request = FollowRouteRequest(
      followRequestId: s.relationship,
      guidanceGeneration: s.generation,
      calculationId: _calculation!,
      requestId: _id('req'),
      mode: s.rejoining ? FollowRouteKind.rejoin : FollowRouteKind.initial,
      originRef: s.originRef!,
      anchor: s.anchor!,
    );
    _request = request;
    _lastAttempt = _now();
    s.condition = FollowRouteCondition.calculating;
    unawaited(_perform(i, request, cancellation));
  }

  bool _current(
    FollowRouteInput input,
    FollowRouteRequest request,
    RouteCancellation cancellation,
  ) =>
      !_disposed &&
      !cancellation.isCancelled &&
      identical(_request, request) &&
      _state?.identity == input.identity &&
      _input?.identity == input.identity &&
      _state?.generation == request.guidanceGeneration &&
      (_state!.rejoining ? FollowRouteKind.rejoin : FollowRouteKind.initial) ==
          request.mode &&
      _state?.anchor == request.anchor &&
      _calculation == request.calculationId &&
      _input!.consent;

  Future<void> _perform(
    FollowRouteInput input,
    FollowRouteRequest request,
    RouteCancellation cancellation,
  ) async {
    try {
      final plan = input.planTrace;
      final result = plan == null
          ? await load(input.room, request, cancellation)
          : await loadPlan!(
              input.room,
              PlanRouteRequest(
                planId: plan.planId,
                planRevision: plan.revision,
                followRequestId: request.followRequestId,
                guidanceGeneration: request.guidanceGeneration,
                calculationId: request.calculationId,
                requestId: request.requestId,
                routeKind: PlanRouteKind.traceRejoin,
                originRef: request.originRef,
                traceAnchor: request.anchor,
              ),
              cancellation,
            );
      if (!_current(input, request, cancellation)) return;
      _cancellation = null;
      if (!_fresh) {
        _pendingResult = result;
        _hold(FollowRouteCondition.locationDelayed);
      } else {
        _applyResult(result);
      }
    } catch (error) {
      if (!_current(input, request, cancellation)) return;
      _cancellation = null;
      final failure = error is FollowRouteException
          ? error
          : const FollowRouteException('INVALID_PROVIDER_RESPONSE');
      if (failure.identity != null && !request.matches(failure.identity!)) {
        _state!.condition = FollowRouteCondition.resetRequired;
      } else {
        _failed(failure);
      }
    }
    if (!_disposed &&
        _state?.identity == input.identity &&
        identical(_request, request)) {
      _syncRetryStatus();
      notifyListeners();
    }
  }

  void _syncRetryStatus() {
    _state?.retrySeconds = _nextAttempt == null
        ? null
        : math.max(0, ((_nextAttempt! - _now()) / 1000).ceil());
  }

  RouteProjection? _rejoinEndpoint(FollowRouteResult result, RoutePoint point) {
    final path = _recoveryPath(), anchor = _state!.anchor;
    if (path == null || anchor == null) return null;
    return projectTraceRejoinEndpoint(point, result.points, path, anchor);
  }

  void _applyResult(FollowRouteResult result) {
    final s = _state!;
    final endMatches =
        result.atAnchor ||
        (s.rejoining
            ? _rejoinEndpoint(result, result.points.last) != null &&
                  _rejoinEndpoint(result, result.actualEnd!) != null
            : routeDistance(result.points.last, result.anchor) <= 25.000001 &&
                  routeDistance(result.actualEnd!, result.anchor) <= 25.000001);
    if (routeDistance(result.origin, s.originPoint!) > 1 ||
        routeDistance(result.anchor, s.anchorPoint!) > 1 ||
        result.atAnchor &&
            routeDistance(result.origin, result.anchor) > 25.000001 ||
        !result.atAnchor &&
            (routeDistance(result.points.first, result.origin) > 25.000001 ||
                routeDistance(result.actualStart!, result.origin) > 25.000001 ||
                !endMatches)) {
      _failed(const FollowRouteException('ENDPOINT_MISMATCH'));
      return;
    }
    final current = RoutePoint.fromFix(_input!.self!);
    final judgement = projectGuidanceRoute(
      current,
      result,
      advance: routeReachableAdvance(_now() - _inputAt!),
    );
    final projection = judgement.window;
    debugGuidanceProjection(s.rejoining ? 'rejoin' : 'initial', judgement);
    if (!judgement.usable) {
      s.route = null;
      _rejectedRoute = result;
      _rejectedAfterDeparture = false;
      _resetEvidence();
      _offRoute = false;
      s.condition = projection?.ambiguous == true
          ? FollowRouteCondition.ambiguousRoute
          : FollowRouteCondition.routeMismatch;
      return;
    }
    _acceptResult(result, projection);
  }

  void _acceptResult(FollowRouteResult result, RouteProjection? projection) {
    final s = _state!;
    if (s.rejoining && !result.atAnchor) {
      final endpoint = _rejoinEndpoint(result, result.points.last);
      final path = _recoveryPath();
      if (endpoint == null || path == null) {
        _failed(const FollowRouteException('ENDPOINT_MISMATCH'));
        return;
      }
      final acceptedAnchor = RouteAnchor.segment(
        SampleRef.of(path.fixes[endpoint.index]),
        SampleRef.of(path.fixes[endpoint.index + 1]),
        endpoint.fraction,
      );
      // A short backward endpoint allowance must not lower the requested
      // anchor floor or accumulate across subsequent endpoint validations.
      if (path.resolve(acceptedAnchor)! > path.resolve(s.anchor!)!) {
        s.anchor = acceptedAnchor;
        s.anchorPoint = endpoint.point;
        s.anchorAt = path.fixes[endpoint.index].at;
      }
    }
    s.route = result;
    _rejectedRoute = null;
    _rejectedAfterDeparture = false;
    s.anchorConfirmed = true;
    s.routeProgress = math.max(s.routeProgress, projection?.along ?? 0);
    _routeObservedAt = _input!.self!.at;
    s.condition = result.atAnchor
        ? FollowRouteCondition.atAnchorWaitingTrace
        : (_activePath()?.points.length ?? 0) < 2
        ? FollowRouteCondition.waitingTrace
        : FollowRouteCondition.ready;
    _beforeHold = null;
    _nextAttempt = null;
    _updateTrace();
  }

  void _failed(FollowRouteException error) {
    final s = _state!;
    s.route = null;
    _beforeHold = null;
    _nextAttempt = null;
    switch (error.code) {
      case 'CONSENT_REQUIRED_SELF':
      case 'CONSENT_REQUIRED_TARGET':
        s.condition = FollowRouteCondition.consentRequired;
        onInvalidated();
      case 'UNAUTHENTICATED':
      case 'NOT_ROOM_MEMBER':
      case 'NOT_ACTIVE_SENDER':
      case 'FOLLOW_NOT_ACTIVE':
        s.condition = FollowRouteCondition.authorizationBlocked;
        onInvalidated();
        onAuthorizationError?.call(error.code);
      case 'ROUTING_DISABLED':
      case 'PROVIDER_AUTH_FAILED':
        s.condition = FollowRouteCondition.disabled;
      case 'LOCATION_NOT_READY':
        s.condition = FollowRouteCondition.locationDelayed;
        _retryOnLocation = true;
      case 'REFERENCE_EXPIRED':
      case 'CONTEXT_MISMATCH':
        s.condition = FollowRouteCondition.resetRequired;
      case 'TRACE_DISCONTINUITY':
        s.condition = FollowRouteCondition.traceBroken;
      case 'NO_ROUTE':
      case 'ENDPOINT_MISMATCH':
        s.condition = FollowRouteCondition.noRoute;
        if (s.rejoining && _extraCandidates == 0) {
          _extraCandidates++;
          _extraPending = true;
          _nextAttempt = _now() + 30000;
        }
      case 'RATE_LIMITED':
      case 'ROUTE_IN_PROGRESS':
        if (!error.inputAccepted || error.inputExpiresAtMs == null) {
          s.condition = FollowRouteCondition.resetRequired;
        } else {
          final serverNow = _input!.serverNowMs;
          if (serverNow == null) {
            s.condition = FollowRouteCondition.resetRequired;
            break;
          }
          _expires = math.min(
            _expires ?? _now() + 120000,
            _now() + (error.inputExpiresAtMs! - serverNow).toInt(),
          );
          _scheduleRetry(error.retryAfterMs);
        }
      case 'PROVIDER_UNAVAILABLE':
      case 'ROUTE_TIMEOUT':
      case 'PROVIDER_RATE_LIMITED':
        if (error.retryable && _retries < 2) {
          _retries++;
          _scheduleRetry(error.retryAfterMs);
        } else {
          s.condition = FollowRouteCondition.noRoute;
        }
      default:
        s.condition = FollowRouteCondition.noRoute;
    }
  }

  void _scheduleRetry(int delay) {
    _nextAttempt = _now() + math.max(30000, delay);
    if (_expires != null && _nextAttempt! >= _expires!) {
      _nextAttempt = null;
      _state!.condition = FollowRouteCondition.resetRequired;
    } else {
      _state!.condition = FollowRouteCondition.retryWaiting;
    }
  }

  void _additionalCandidate() {
    final s = _state!, path = _activePath();
    if (path == null) {
      s.condition = FollowRouteCondition.noRoute;
      return;
    }
    final along = path.resolve(s.anchor!)!;
    final next = math.min(along + 60, path.cumulative.last);
    final anchor = path.at(next);
    if (next <= along || anchor == s.anchor || anchor.end == null) {
      s.condition = FollowRouteCondition.noRoute;
      _nextAttempt = null;
      return;
    }
    _start(
      candidate: JoinCandidate(anchor, path.pointAt(next), path),
      rejoin: true,
    );
  }

  void _resetJoin() {
    _joinSince = null;
    _joinSamples = 0;
    _joinStart = _joinLast = null;
  }

  void _resetEvidence() {
    _forwardRoute.reset();
    _resetJoin();
    _offSince = null;
    _offSamples = 0;
    _reverseSince = null;
    _reverseSamples = 0;
  }

  void _invalidate({bool clearVoice = true}) {
    _rejectedRoute = null;
    _rejectedAfterDeparture = false;
    _routeObservedAt = null;
    _cancellation?.cancel();
    _cancellation = null;
    _request = null;
    _pendingResult = null;
    _nextAttempt = null;
    _extraPending = _retryOnLocation = false;
    _beforeHold = null;
    _resetEvidence();
    _lastSelf = null;
    _directionBase = null;
    _moving = false;
    if (_state != null) _state!.generation = ++_generation;
    if (clearVoice) onInvalidated();
  }

  void _clearCalculation() {
    _rejectedRoute = null;
    _state?.route = null;
    _state?.anchorReached = false;
    _calculation = null;
    _expires = _inputAt = null;
    _retries = _extraCandidates = 0;
  }

  void clear() {
    if (_state == null) return;
    _diagnosticState = null;
    _diagnosticAt = null;
    _invalidate();
    _clearCalculation();
    _state = null;
    _input = null;
    _paths = const [];
    _traceSource = null;
    _renderedPath = null;
    _renderedRef = null;
    _selfConsentBlocked = false;
    _featureBlocked = false;
    _tracking = null;
    _offRoute = false;
    _rejoinFloor = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
