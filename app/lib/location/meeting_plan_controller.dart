import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

import '../net/follow_route.dart';
import '../net/meeting_plan.dart';
import '../net/models.dart';
import 'follow_route_controller.dart';
import 'follow_route_geometry.dart';
import 'meeting_stop_evidence.dart';

typedef MeetingRequest =
    Future<JsonMap> Function(
      String room,
      String method,
      String path,
      JsonMap? body,
      RouteCancellation cancellation, {
      Duration timeout,
    });
typedef PlanRouteLoader =
    Future<FollowRouteResult> Function(
      String room,
      PlanRouteRequest request,
      RouteCancellation cancellation,
    );

class MeetingInput {
  const MeetingInput({
    required this.room,
    required this.account,
    required this.device,
    required this.connected,
    required this.consent,
    required this.sharing,
    required this.restricted,
    required this.self,
    required this.selfAgeMs,
    this.target,
    this.relationship,
    this.leader,
    this.leaderAgeMs = double.infinity,
    this.serverNowMs,
  });
  final String room, account, device;
  final String? target, relationship;
  final bool connected, consent, sharing, restricted;
  final LocationFix? self, leader;
  final double selfAgeMs, leaderAgeMs;
  final num? serverNowMs;
  Object get identity => (room, account, device);
}

class MeetingPin {
  const MeetingPin(this.id, this.point, this.label, {this.draft = false});
  final String id, label;
  final RoutePoint point;
  final bool draft;
}

/// Server owns arrival/departure/branch. This controller owns editing and the
/// one active fixed J/D route. Actual trace judgement remains in r4's controller.
class MeetingPlanController extends ChangeNotifier {
  MeetingPlanController({
    required this.request,
    required this.loadRoute,
    required this.onInvalidated,
    required this.onNotice,
    this.onAuthorizationError,
    int Function()? now,
  }) {
    final clock = Stopwatch()..start();
    _now = now ?? () => clock.elapsedMilliseconds;
  }
  final MeetingRequest request;
  final PlanRouteLoader loadRoute;
  final VoidCallback onInvalidated;
  final void Function(String key, String text) onNotice;
  final void Function(String code)? onAuthorizationError;
  late final int Function() _now;
  final _nonce = math.Random.secure().nextInt(0x100000000).toRadixString(16);
  MeetingInput? _input;
  MeetingCapabilities capabilities = const MeetingCapabilities();
  final _plans = <String, MeetingPlanSnapshot>{};
  final _retired = <String>{};
  List<PlanParticipant> participants = const [];
  final _samples = <LocationFix>[];
  final _sampleReceipts = <num>[];
  List<LocationFix> get ownSamples => List.unmodifiable(_samples);
  String? selectedLeader;
  String? _selectedPlanId;
  String? _selectedRelationship;
  bool restored = false, _disposed = false;
  int _epoch = 0, _ids = 0, _editGeneration = 0, _routeGeneration = 0;
  final _pending = <RouteCancellation>{};
  RouteCancellation? _search, _recommend, _routeCancel;
  bool busy = false, searching = false, recommending = false, editing = false;
  MeetingPointField field = MeetingPointField.destination;
  MeetingPoint? destination, joinPoint, pendingPoint;
  MeetingPolicy policy = MeetingPolicy.wait;
  bool waitingPlaceConfirmed = false;
  final selectedParticipants = <String>{};
  MeetingRecommendation? recommendation;
  int? _previewUntil;
  List<AddressResult> addresses = const [];
  String? error, searchMessage;
  int? _errorUntil;
  String? _draftPlanId;
  int _draftRevision = 0;
  FollowRouteResult? _route, _rejectedRoute;
  FollowRouteResult? _reportedRoute;
  RouteCancellation? _etaReport;
  FollowRouteResult? _approachRoute;
  Object? _approachIdentity;
  RoutePoint? _originPoint;
  PlanRouteRequest? _routeRequest;
  Object? _routeKey;
  FollowRouteCondition _condition = FollowRouteCondition.waitingLocation;
  int? _nextAttempt, _expires, _lastAttempt, _offSince, _calculatedAt;
  int _retries = 0, _offSamples = 0;
  final _recoveries = <int>[];
  SampleRef? _judgedRef;
  bool _rejoining = false, _destinationBranch = false;
  bool _passPending = false;
  bool _retryOnLocation = false;
  int _lastPassAt = -10000;
  final _announced = <String>{};

  MeetingPlanSnapshot? get ownPlan => _plans[_input?.account];
  MeetingPlanSnapshot? get targetPlan => _plans[_input?.target];
  MeetingPlanSnapshot? get active {
    final value = _plans[selectedLeader];
    return value?.plan.planId == _selectedPlanId ? value : null;
  }

  PlanVehicle? get ownRuntime =>
      active?.runtime?.vehicle(_input?.account ?? '');
  bool get selected => selectedLeader != null;
  bool get owner => selectedLeader == _input?.account;
  Object? get _activeIdentity => active == null
      ? null
      : (active!.plan.planId, active!.plan.revision, _selectedRelationship);
  FollowRouteResult? get approachRoute =>
      _approachIdentity == _activeIdentity &&
          {'atJoinWaiting', 'tracePriming'}.contains(ownRuntime?.phase) &&
          ownRuntime?.branch != 'destination'
      ? _approachRoute
      : null;
  void releaseApproach() {
    _approachRoute = null;
    _approachIdentity = null;
  }

  bool get _freshSelf =>
      _input != null &&
      _input!.self != null &&
      _input!.selfAgeMs.isFinite &&
      _input!.selfAgeMs >= 0 &&
      _input!.selfAgeMs <= meetingStopLocationAgeMs &&
      routeQuality(_input!.self!);
  bool get _fresh =>
      _freshSelf &&
      ownRuntime?.condition == null &&
      _input!.connected &&
      (owner ||
          _input!.leader != null &&
              _input!.leaderAgeMs <= 10000 &&
              routeQuality(_input!.leader!));
  bool get canEditMeetingPlan {
    final i = _input;
    if (i == null ||
        !capabilities.enabled ||
        !i.connected ||
        !i.consent ||
        !i.sharing ||
        i.restricted ||
        !_freshSelf)
      return false;
    return meetingStopped(
      _samples,
      latestAgeMs: i.selfAgeMs,
      receivedAtMs: _sampleReceipts,
    );
  }

  bool get canEnroll =>
      canEditMeetingPlan &&
      !busy &&
      targetPlan?.plan.ready == true &&
      targetPlan!.plan.participantFollowRequestIds.contains(
        _input?.relationship,
      ) &&
      targetPlan!.runtime?.departedAtMs == null &&
      targetPlan!.runtime?.departureAnnouncedAtMs == null &&
      !(selected &&
          !owner &&
          !restored &&
          active?.plan.planId == targetPlan!.plan.planId &&
          active?.runtime?.enrollments.contains(_input?.relationship) == true);
  bool get canDepart {
    final a = active, r = a?.runtime;
    if (!owner ||
        !canEditMeetingPlan ||
        busy ||
        a == null ||
        a.plan.destinationOnly ||
        a.plan.policy != MeetingPolicy.wait ||
        r == null ||
        r.enrollments.isEmpty ||
        r.departureAnnouncedAtMs != null ||
        r.departedAtMs != null ||
        ownRuntime?.phase != 'atJoinWaiting')
      return false;
    return r.enrollments.every(
      (id) => r.vehicles.any(
        (v) =>
            v.followRequestId == id &&
            v.phase == 'atJoinWaiting' &&
            v.condition == null,
      ),
    );
  }

  PlanTraceContext? get traceContext {
    final a = active, r = a?.runtime, v = ownRuntime;
    if (!capabilities.enabled ||
        _input?.consent != true ||
        owner ||
        restored ||
        a == null ||
        r == null ||
        v == null ||
        _destinationBranch ||
        v.branch != 'trace' ||
        r.traceStartRef == null ||
        !{'tracePriming', 'onTrace', 'rejoining'}.contains(v.phase))
      return null;
    return PlanTraceContext(a.plan.planId, a.plan.revision, r.traceStartRef!);
  }

  PlanRouteKind? get routeKind {
    final a = active, r = a?.runtime, v = ownRuntime;
    if (a == null ||
        !a.plan.ready ||
        r == null ||
        r.enrollments.isEmpty ||
        restored ||
        {'completed', 'cancelled', 'suspended'}.contains(r.phase) ||
        v?.phase == 'completed')
      return null;
    if (!owner &&
        (!r.enrollments.contains(_input?.relationship) ||
            v?.followRequestId != _input?.relationship))
      return null;
    if (a.plan.destinationOnly ||
        _destinationBranch ||
        v?.branch == 'destination' ||
        owner &&
            (r.departureAnnouncedAtMs != null ||
                r.departedAtMs != null ||
                r.leaderPassRef != null))
      return PlanRouteKind.planDestination;
    if (v?.passedAtMs != null && v?.branch == 'pending' ||
        v?.branch == 'trace' ||
        {
          'atJoinWaiting',
          'nearJoin',
          'tracePriming',
          'onTrace',
        }.contains(v?.phase))
      return null;
    return PlanRouteKind.planJoin;
  }

  void update(MeetingInput? input) {
    if (_disposed) return;
    if (input == null) {
      clear();
      return;
    }
    if (_input != null && _input!.identity != input.identity) clear();
    _input = input;
    final self = input.self;
    if (self != null &&
        _freshSelf &&
        (_samples.isEmpty ||
            SampleRef.of(_samples.last) != SampleRef.of(self))) {
      if (_samples.isNotEmpty && !traceContinuous(_samples.last, self)) {
        _samples.clear();
        _sampleReceipts.clear();
      }
      _samples.add(self);
      // Own fixes have receivedAt=0. Remember the first successful upload
      // acknowledgement; duplicate updates never refresh this evidence.
      _sampleReceipts.add(
        self.receivedAt > 0 ? self.receivedAt : self.at + input.selfAgeMs,
      );
      if (_samples.length > meetingEvidenceSampleLimit) {
        _samples.removeAt(0);
        _sampleReceipts.removeAt(0);
      }
    }
    if (!_freshSelf) {
      _samples.clear();
      _sampleReceipts.clear();
    }
    if (!input.consent || !input.sharing) {
      final feature = capabilities;
      final selection = selectedLeader,
          relation = _selectedRelationship,
          selectedId = _selectedPlanId;
      clear();
      _input = input;
      capabilities = feature;
      if (!input.consent) {
        selectedLeader = selection;
        _selectedPlanId = selectedId;
        _selectedRelationship = relation;
      }
      return;
    }
    if (editing && !canEditMeetingPlan) {
      closeEditor();
      notifyListeners();
    }
    if (selected &&
        !owner &&
        (_selectedRelationship != input.relationship ||
            selectedLeader != input.target)) {
      _cancelRoute();
      onInvalidated();
      // Remain stopped in mode ② until a deliberate choice; never auto-start ①.
      _plans.remove(selectedLeader);
    }
    if (_previewUntil != null && _now() >= _previewUntil!) {
      _dropPreview();
      pendingPoint = null;
    }
    if (ownRuntime?.branch == 'destination' && !owner)
      _destinationBranch = true;
    _evaluateRoute();
    _announce();
  }

  void applySnapshot(
    List<MeetingPlanSnapshot> plans,
    List<PlanParticipant> followers,
    MeetingCapabilities feature, {
    bool authoritative = false,
  }) {
    if (_disposed) return;
    if (authoritative) {
      ++_epoch;
      _cancelOperations();
      closeEditor();
      final ids = plans.map((s) => s.plan.planId).toSet();
      _retired.addAll(
        _plans.values
            .where((s) => !ids.contains(s.plan.planId))
            .map((s) => s.plan.planId),
      );
      if (active != null && !ids.contains(active!.plan.planId)) onInvalidated();
      _plans.removeWhere((_, s) => !ids.contains(s.plan.planId));
    }
    capabilities = feature;
    participants = List.unmodifiable(followers);
    for (final p in plans) {
      applyPlan(p, notify: false);
    }
    if (!feature.enabled) {
      _cancelRoute();
      closeEditor();
    }
    final i = _input;
    if (authoritative &&
        !selected &&
        i != null &&
        targetPlan?.runtime?.enrollments.contains(i.relationship) == true) {
      selectedLeader = i.target;
      _selectedPlanId = targetPlan!.plan.planId;
      _selectedRelationship = i.relationship;
      restored = true;
    }
    _evaluateRoute();
    notifyListeners();
  }

  void applyPlan(MeetingPlanSnapshot snapshot, {bool notify = true}) {
    if (_disposed || _retired.contains(snapshot.plan.planId)) return;
    final p = snapshot.plan, old = _plans[p.leaderHandle];
    if (_input != null &&
        (p.roomCode != _input!.room ||
            p.leaderHandle != _input!.account &&
                p.leaderHandle != _input!.target))
      return;
    if (old != null) {
      if (old.plan.planId != p.planId) _retired.add(old.plan.planId);
      if (old.plan.planId == p.planId &&
          (p.revision < old.plan.revision ||
              p.revision == old.plan.revision &&
                  (snapshot.runtime?.runtimeRevision ?? 0) <
                      (old.runtime?.runtimeRevision ?? 0)))
        return;
    }
    _plans[p.leaderHandle] = snapshot;
    if (p.planId == _selectedPlanId &&
        p.leaderHandle == selectedLeader &&
        !owner &&
        snapshot.runtime?.vehicle(_input?.account ?? '')?.branch ==
            'destination')
      _destinationBranch = true;
    if (p.ready &&
        p.leaderHandle == _input?.target &&
        _announced.add('${p.planId}:${p.revision}:ready')) {
      onNotice(
        '${p.planId}:${p.revision}:ready',
        '앞차가 합류 계획을 확정했습니다. 정차 후 확인해 주세요',
      );
    }
    if (notify) {
      _evaluateRoute();
      _announce();
      notifyListeners();
    }
  }

  void setParticipants(List<PlanParticipant> values) {
    participants = List.unmodifiable(values);
    notifyListeners();
  }

  void applyRuntime(MeetingRuntime runtime) {
    for (final p in _plans.values.toList()) {
      if (p.plan.planId == runtime.planId &&
          p.plan.revision == runtime.planRevision)
        applyPlan(MeetingPlanSnapshot(p.plan, runtime));
    }
  }

  void planCleared(String id, String leader) {
    _retired.add(id);
    if (_plans[leader]?.plan.planId == id) _plans.remove(leader);
    if (_selectedPlanId == id && selectedLeader == leader) {
      _cancelRoute();
      releaseApproach();
      onInvalidated();
    }
    if (_draftPlanId == id) closeEditor();
    notifyListeners();
  }

  bool beginEditing() {
    if (!canEditMeetingPlan || busy) return false;
    closeEditor();
    final p = ownPlan?.plan;
    if (ownPlan?.runtime?.enrollments.isNotEmpty == true) {
      error = meetingErrorText('PLAN_LOCKED');
      notifyListeners();
      return false;
    }
    editing = true;
    field = MeetingPointField.destination;
    _draftPlanId = p?.planId;
    _draftRevision = p?.revision ?? 0;
    destination = p?.destination;
    joinPoint = p?.joinPoint;
    policy = p?.policy ?? MeetingPolicy.wait;
    waitingPlaceConfirmed = p?.waitingPlaceConfirmed ?? false;
    selectedParticipants.addAll(
      p?.participantFollowRequestIds ??
          participants.map((p) => p.followRequestId),
    );
    error = null;
    notifyListeners();
    unawaited(refreshParticipants());
    return true;
  }

  Future<void> refreshParticipants() async {
    final i = _input;
    if (i == null || !capabilities.enabled || !i.connected) return;
    final epoch = _epoch, context = i.identity, edit = _editGeneration;
    final c = _operation();
    try {
      final j = await request(
        i.room,
        'GET',
        '/follow-plans/self/participants',
        null,
        c,
      );
      if (!_current(c, epoch, context)) return;
      final oldIds = participants.map((p) => p.followRequestId).toSet();
      participants = List.unmodifiable(
        (j['participants'] as List).map(PlanParticipant.fromJson),
      );
      // A fresh editor initially selects every accepted direct follower. An old
      // relation is never silently replaced with a new ID for the same handle.
      if (editing &&
          edit == _editGeneration &&
          _draftPlanId == null &&
          oldIds.isEmpty &&
          selectedParticipants.isEmpty) {
        selectedParticipants.addAll(participants.map((p) => p.followRequestId));
      }
    } catch (e) {
      if (_current(c, epoch, context)) _fail(e);
    } finally {
      _pending.remove(c);
      if (!_disposed) notifyListeners();
    }
  }

  bool _editAllowed() => editing && canEditMeetingPlan && !busy;
  void selectField(MeetingPointField value) {
    if (!_editAllowed()) return;
    _invalidateSearch();
    field = value;
    pendingPoint = null;
    _dropPreview();
    notifyListeners();
  }

  void pickPoint(RoutePoint point) {
    if (!_editAllowed()) return;
    _invalidateSearch();
    _dropPreview();
    pendingPoint = MeetingPoint(
      point,
      field == MeetingPointField.destination
          ? '지도에서 선택한 목적지'
          : '지도에서 선택한 합류 지점',
      'map',
    );
    notifyListeners();
  }

  void selectAddress(AddressResult result) {
    if (!_editAllowed() || !addresses.contains(result)) return;
    _dropPreview();
    pendingPoint = MeetingPoint(result.point, result.label, 'address');
    notifyListeners();
  }

  void confirmPoint() {
    if (!_editAllowed() || pendingPoint == null) return;
    if (field == MeetingPointField.destination) {
      destination = pendingPoint;
      joinPoint = null;
    } else {
      joinPoint = pendingPoint;
    }
    waitingPlaceConfirmed = false;
    pendingPoint = null;
    _invalidateSearch();
    _dropPreview();
    notifyListeners();
  }

  void cancelPoint() {
    if (!_editAllowed()) return;
    pendingPoint = null;
    _dropPreview();
    notifyListeners();
  }

  void setPolicy(MeetingPolicy value) {
    if (!_editAllowed()) return;
    policy = value;
    waitingPlaceConfirmed = false;
    notifyListeners();
  }

  void confirmWaitingPlace() {
    if (!_editAllowed() || joinPoint == null) return;
    waitingPlaceConfirmed = !waitingPlaceConfirmed;
    notifyListeners();
  }

  void toggleParticipant(String id) {
    if (!_editAllowed()) return;
    if (!selectedParticipants.remove(id)) selectedParticipants.add(id);
    _dropPreview();
    _editGeneration++;
    notifyListeners();
  }

  Future<void> save() async {
    if (!_editAllowed() || destination == null || pendingPoint != null) return;
    if (joinPoint != null &&
        policy == MeetingPolicy.wait &&
        !waitingPlaceConfirmed) {
      error = '정차 가능한 지점인지 확인해 주세요';
      notifyListeners();
      return;
    }
    final body = <String, dynamic>{
      'operationId': _id('save'),
      'expectedPlanId': _draftPlanId,
      'expectedRevision': _draftRevision,
      'destination': destination!.toJson(),
      'joinPoint': joinPoint?.toJson(),
      'policy': policy.name,
      'participantFollowRequestIds': selectedParticipants.toList(),
      'waitingPlaceConfirmed': waitingPlaceConfirmed,
    };
    final j = await _change('PUT', '/follow-plans/self', body);
    if (j == null) return;
    final snapshot = MeetingPlanSnapshot.fromJson(j);
    applyPlan(snapshot);
    closeEditor();
    // Saving is the explicit choice to guide one's own group, not room ownership.
    if (!selected || owner) {
      selectedLeader = _input!.account;
      _selectedPlanId = snapshot.plan.planId;
      _selectedRelationship = null;
      restored = false;
      _destinationBranch = false;
      _cancelRoute();
    }
    onInvalidated();
    _evaluateRoute();
    notifyListeners();
  }

  Future<void> cancelPlan() async {
    final p = ownPlan?.plan;
    if (!canEditMeetingPlan || p == null) return;
    final j = await _change('DELETE', '/follow-plans/self', {
      'operationId': _id('delete'),
      'planId': p.planId,
      'expectedRevision': p.revision,
    });
    if (j != null) {
      planCleared(p.planId, p.leaderHandle);
      closeEditor();
    }
  }

  Future<bool> enroll(bool enabled) async {
    if (!canEditMeetingPlan || busy) return false;
    final a = enabled ? targetPlan : active;
    final i = _input!;
    if (a == null || owner && !enabled) {
      if (!enabled) {
        deselect();
        return true;
      }
      return false;
    }
    if (enabled && !canEnroll) return false;
    final p = a.plan;
    final j = await _change(
      'PUT',
      '/follow-plans/${Uri.encodeComponent(p.leaderHandle)}/participation',
      {
        'operationId': _id('participate'),
        'planId': p.planId,
        'planRevision': p.revision,
        'followRequestId': i.relationship,
        'enabled': enabled,
      },
    );
    if (j == null) return false;
    if (_input?.relationship != i.relationship || _input?.target != i.target)
      return false;
    if (j['runtime'] != null)
      applyRuntime(MeetingRuntime.fromJson(j['runtime']));
    if (enabled) {
      selectedLeader = p.leaderHandle;
      _selectedPlanId = p.planId;
      _selectedRelationship = i.relationship;
      restored = false;
      _destinationBranch = false;
      _cancelRoute();
      onInvalidated();
      _evaluateRoute();
    } else {
      deselect();
    }
    notifyListeners();
    return true;
  }

  Future<bool> selectOwnGuidance() async {
    if (!canEditMeetingPlan || ownPlan == null) return false;
    if (owner && active != null && !restored) return true;
    if (selected && !owner && !await enroll(false)) return false;
    if (!canEditMeetingPlan || ownPlan == null) return false;
    selectedLeader = _input!.account;
    _selectedPlanId = ownPlan!.plan.planId;
    _selectedRelationship = null;
    restored = false;
    _destinationBranch = false;
    _cancelRoute();
    onInvalidated();
    _evaluateRoute();
    notifyListeners();
    return true;
  }

  void deselect() {
    selectedLeader = null;
    _selectedPlanId = null;
    _selectedRelationship = null;
    restored = false;
    _destinationBranch = false;
    _cancelRoute();
    releaseApproach();
    onInvalidated();
    notifyListeners();
  }

  Future<void> depart() async {
    if (!canDepart) return;
    final a = active!;
    final j = await _change('POST', '/follow-plans/self/depart', {
      'operationId': _id('depart'),
      'planId': a.plan.planId,
      'planRevision': a.plan.revision,
      'expectedRuntimeRevision': a.runtime!.runtimeRevision,
    });
    if (j?['runtime'] != null)
      applyRuntime(MeetingRuntime.fromJson(j!['runtime']));
  }

  Future<JsonMap?> _change(String method, String path, JsonMap body) async {
    if (!canEditMeetingPlan || busy) return null;
    busy = true;
    error = null;
    notifyListeners();
    final i = _input!, epoch = _epoch, edit = _editGeneration;
    final c = _operation();
    try {
      final j = await request(i.room, method, path, body, c);
      if (!_current(c, epoch, i.identity) ||
          !canEditMeetingPlan ||
          edit != _editGeneration)
        return null;
      if (j['plan'] != null) {
        final snapshot = MeetingPlanSnapshot.fromJson(j);
        final leader = path.startsWith('/follow-plans/self')
            ? i.account
            : Uri.decodeComponent(path.split('/')[2]);
        if (snapshot.plan.roomCode != i.room ||
            snapshot.plan.leaderHandle != leader ||
            body['planId'] != null && body['planId'] != snapshot.plan.planId ||
            body['expectedPlanId'] != null &&
                body['expectedPlanId'] != snapshot.plan.planId ||
            body['planRevision'] != null &&
                body['planRevision'] != snapshot.plan.revision) {
          throw const FormatException('계획 변경 응답 문맥 오류');
        }
      } else if (j['runtime'] != null) {
        final runtime = MeetingRuntime.fromJson(j['runtime']);
        if (runtime.planId != body['planId'] ||
            runtime.planRevision != body['planRevision']) {
          throw const FormatException('계획 진행 응답 문맥 오류');
        }
      }
      return j;
    } catch (e) {
      if (_current(c, epoch, i.identity)) {
        _fail(e);
        if (e is FollowRouteException &&
            {'PLAN_CHANGED', 'RUNTIME_CHANGED', 'PLAN_LOCKED'}.contains(e.code))
          unawaited(
            refreshPlan(path.contains('/self') ? i.account : i.target!),
          );
      }
      return null;
    } finally {
      _pending.remove(c);
      if (epoch == _epoch) busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refreshPlan(String leader) async {
    final i = _input;
    if (i == null || !i.connected) return;
    final c = _operation(), epoch = _epoch;
    try {
      final j = await request(
        i.room,
        'GET',
        '/follow-plans/${Uri.encodeComponent(leader)}',
        null,
        c,
      );
      if (!_current(c, epoch, i.identity)) return;
      if (j['plan'] == null) {
        final old = _plans[leader];
        if (old != null) planCleared(old.plan.planId, leader);
      } else {
        applyPlan(MeetingPlanSnapshot.fromJson(j));
      }
    } catch (e) {
      if (_current(c, epoch, i.identity)) _fail(e);
    } finally {
      _pending.remove(c);
    }
  }

  Future<void> search(String query) async {
    if (!_editAllowed() || !capabilities.geocoding) return;
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(query)) {
      searchMessage = '도로명 또는 지번 주소를 입력해 주세요';
      notifyListeners();
      return;
    }
    query = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (query.runes.length < 2 || query.runes.length > 200) {
      searchMessage = '주소를 2~200자로 입력해 주세요';
      notifyListeners();
      return;
    }
    _invalidateSearch();
    final edit = _editGeneration,
        selectedField = field,
        i = _input!,
        epoch = _epoch;
    final c = _operation();
    _search = c;
    searching = true;
    notifyListeners();
    try {
      final id = _id('address');
      final j = await request(i.room, 'POST', '/geocoding', {
        'requestId': id,
        'query': query,
      }, c);
      if (!_current(c, epoch, i.identity) ||
          !_editAllowed() ||
          edit != _editGeneration ||
          field != selectedField ||
          j['requestId'] != id)
        return;
      final results = (j['results'] as List)
          .map(AddressResult.fromJson)
          .toList();
      if (results.length > 5 || results.any((r) => r.label.isEmpty))
        throw const FormatException();
      addresses = List.unmodifiable(results);
      searchMessage = results.isEmpty
          ? '주소를 찾지 못했습니다. 도로명·건물 번호 또는 지번을 확인해 주세요'
          : null;
    } catch (e) {
      if (_current(c, epoch, i.identity) && edit == _editGeneration) _fail(e);
    } finally {
      _pending.remove(c);
      if (identical(_search, c)) {
        _search = null;
        searching = false;
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> recommend() async {
    if (!_editAllowed() ||
        !capabilities.recommendation ||
        destination == null ||
        recommending)
      return;
    _dropPreview();
    final i = _input!, epoch = _epoch, edit = _editGeneration;
    final c = _operation();
    _recommend = c;
    recommending = true;
    error = null;
    notifyListeners();
    try {
      final id = _id('recommend');
      final j = await request(
        i.room,
        'POST',
        '/follow-plans/self/recommend',
        {
          'requestId': id,
          'draftGeneration': edit,
          'planId': _draftPlanId,
          'expectedRevision': _draftRevision,
          'destination': destination!.toJson(),
          'participantFollowRequestIds': selectedParticipants.toList(),
        },
        c,
        timeout: const Duration(seconds: 18),
      );
      if (!_current(c, epoch, i.identity) ||
          !_editAllowed() ||
          edit != _editGeneration ||
          j['requestId'] != id ||
          j['draftGeneration'] != edit)
        return;
      recommendation = MeetingRecommendation.fromJson(j);
      _previewUntil =
          _now() +
          math.max(
            0,
            60000 -
                ((j['serverNowMs'] as num? ?? recommendation!.calculatedAtMs) -
                        recommendation!.calculatedAtMs)
                    .toInt(),
          );
      _invalidateSearch();
      field = MeetingPointField.joinPoint;
      pendingPoint = recommendation!.joinPoint;
    } catch (e) {
      if (_current(c, epoch, i.identity) && edit == _editGeneration) _fail(e);
    } finally {
      _pending.remove(c);
      if (identical(_recommend, c)) {
        _recommend = null;
        recommending = false;
      }
      if (!_disposed) notifyListeners();
    }
  }

  void closeEditor() {
    editing = false;
    destination = joinPoint = pendingPoint = null;
    selectedParticipants.clear();
    waitingPlaceConfirmed = false;
    _invalidateSearch();
    _dropPreview();
  }

  void _invalidateSearch() {
    ++_editGeneration;
    _search?.cancel();
    _search = null;
    searching = false;
    addresses = const [];
    searchMessage = null;
  }

  void _dropPreview() {
    _recommend?.cancel();
    _recommend = null;
    recommending = false;
    recommendation = null;
    _previewUntil = null;
    if (pendingPoint?.source == 'recommendation') pendingPoint = null;
  }

  RouteCancellation _operation() {
    final c = RouteCancellation();
    _pending.add(c);
    return c;
  }

  bool _current(RouteCancellation c, int epoch, Object identity) =>
      !_disposed &&
      !c.isCancelled &&
      epoch == _epoch &&
      identity == _input?.identity;
  String _id(String prefix) => 'plan-$prefix-$_nonce-${_now()}-${++_ids}';
  void _fail(Object e) {
    final f = e is FollowRouteException
        ? e
        : const FollowRouteException('INVALID_PROVIDER_RESPONSE');
    error = meetingErrorText(f.code);
    final ids = f.identity?['participantFollowRequestIds'];
    if (f.code == 'CONSENT_REQUIRED_PARTICIPANT' && ids is List) {
      final names = participants
          .where((p) => ids.contains(p.followRequestId))
          .map((p) => p.displayName)
          .toList();
      if (names.isNotEmpty)
        error = '${names.join(', ')} · 최신 개인정보·위치 동의가 필요합니다';
    }
    if ({
      'NOT_ACTIVE_SENDER',
      'NOT_ROOM_MEMBER',
      'UNAUTHENTICATED',
      'FOLLOW_NOT_ACTIVE',
    }.contains(f.code)) {
      _cancelRoute();
      onInvalidated();
      onAuthorizationError?.call(f.code);
    }
    _errorUntil = f.retryAfterMs > 0 ? _now() + f.retryAfterMs : null;
  }

  int? get retrySeconds => _errorUntil == null
      ? null
      : math.max(0, ((_errorUntil! - _now()) / 1000).ceil());

  void _evaluateRoute() {
    if (!selected) return;
    if (_approachIdentity != _activeIdentity ||
        ownRuntime?.branch == 'destination')
      releaseApproach();
    final a = active, kind = routeKind;
    final key = a == null || kind == null
        ? null
        : (
            a.plan.planId,
            a.plan.revision,
            selectedLeader,
            _selectedRelationship,
            kind,
          );
    if (key != _routeKey) {
      _cancelRoute();
      _routeKey = key;
    }
    if (a == null || !capabilities.enabled || !_input!.consent) {
      _cancelRoute();
      releaseApproach();
      return;
    }
    if (!_fresh) {
      _offSince = null;
      _offSamples = 0;
      return;
    }
    if (kind == null) return;
    if (_routeRequest == null) {
      _startRoute(kind);
      return;
    }
    if (_retryOnLocation &&
        _routeCancel == null &&
        _input!.self != null &&
        _judgedRef != SampleRef.of(_input!.self!)) {
      _retryOnLocation = false;
      if (_expires != null && _now() >= _expires!)
        _condition = FollowRouteCondition.resetRequired;
      else
        _sendRoute();
    }
    if (_nextAttempt != null &&
        _now() >= _nextAttempt! &&
        _routeCancel == null) {
      _nextAttempt = null;
      if (_expires != null && _now() >= _expires!)
        _condition = FollowRouteCondition.resetRequired;
      else
        _sendRoute();
    }
    _judgeFixedRoute();
    _reportRouteEta();
  }

  void _startRoute(PlanRouteKind kind) {
    if (!_fresh || _routeCancel != null) return;
    releaseApproach();
    final a = active!, fix = _input!.self!;
    _routeRequest = PlanRouteRequest(
      planId: a.plan.planId,
      planRevision: a.plan.revision,
      followRequestId: owner ? null : _input!.relationship,
      guidanceGeneration: ++_routeGeneration,
      calculationId: _id('calc'),
      requestId: _id('route'),
      routeKind: kind,
      originRef: SampleRef.of(fix),
    );
    _originPoint = RoutePoint.fromFix(fix);
    _expires = _now() + 120000;
    _retries = 0;
    _sendRoute();
  }

  void _sendRoute() {
    final old = _routeRequest;
    if (old == null || _routeCancel != null || !_fresh) return;
    final r = PlanRouteRequest(
      planId: old.planId,
      planRevision: old.planRevision,
      followRequestId: old.followRequestId,
      guidanceGeneration: old.guidanceGeneration,
      calculationId: old.calculationId,
      requestId: _id('route'),
      routeKind: old.routeKind,
      originRef: old.originRef,
    );
    _routeRequest = r;
    final c = RouteCancellation();
    _routeCancel = c;
    _condition = FollowRouteCondition.calculating;
    _lastAttempt = _now();
    unawaited(_performRoute(r, c, _input!.identity, _epoch));
  }

  bool _currentRoute(
    PlanRouteRequest r,
    RouteCancellation c,
    Object identity,
    int epoch,
  ) =>
      !_disposed &&
      !c.isCancelled &&
      identity == _input?.identity &&
      identical(_routeRequest, r) &&
      active?.plan.planId == r.planId &&
      active?.plan.revision == r.planRevision &&
      routeKind == r.routeKind &&
      _input!.consent &&
      capabilities.enabled;
  Future<void> _performRoute(
    PlanRouteRequest r,
    RouteCancellation c,
    Object identity,
    int epoch,
  ) async {
    try {
      final result = await loadRoute(_input!.room, r, c);
      if (!_currentRoute(r, c, identity, epoch)) return;
      final goal = r.routeKind == PlanRouteKind.planJoin
          ? active!.plan.joinPoint!.point
          : active!.plan.destination.point;
      if (routeDistance(result.origin, _originPoint!) > 1 ||
          routeDistance(result.anchor, goal) > 1 ||
          (result.atAnchor
              ? routeDistance(result.origin, goal) > 25.000001
              : routeDistance(result.points.first, result.origin) > 25.000001 ||
                    routeDistance(result.points.last, goal) > 25.000001 ||
                    routeDistance(result.actualStart!, result.origin) >
                        25.000001 ||
                    routeDistance(result.actualEnd!, goal) > 25.000001)) {
        throw const FollowRouteException('ENDPOINT_MISMATCH');
      }
      final p = projectRoute(RoutePoint.fromFix(_input!.self!), result.points);
      final usable = result.atAnchor
          ? routeDistance(RoutePoint.fromFix(_input!.self!), goal) <= 60
          : p != null && !p.ambiguous && p.distance <= 60;
      _route = usable ? result : null;
      _rejectedRoute = usable ? null : result;
      if (usable && r.routeKind == PlanRouteKind.planJoin) {
        _approachRoute = result;
        _approachIdentity = _activeIdentity;
      }
      _condition = usable
          ? FollowRouteCondition.ready
          : FollowRouteCondition.offRoute;
      _calculatedAt = _now();
      _nextAttempt = null;
      _reportRouteEta();
    } catch (e) {
      if (!_currentRoute(r, c, identity, epoch)) return;
      final f = e is FollowRouteException
          ? e
          : const FollowRouteException('INVALID_PROVIDER_RESPONSE');
      _route = null;
      if ({
        'NOT_ACTIVE_SENDER',
        'NOT_ROOM_MEMBER',
        'UNAUTHENTICATED',
        'FOLLOW_NOT_ACTIVE',
      }.contains(f.code)) {
        _condition = FollowRouteCondition.authorizationBlocked;
        onInvalidated();
        onAuthorizationError?.call(f.code);
      } else if (f.identity != null && !r.matches(f.identity!)) {
        _condition = FollowRouteCondition.resetRequired;
      } else if ({'RATE_LIMITED', 'ROUTE_IN_PROGRESS'}.contains(f.code) &&
          f.inputAccepted &&
          f.inputExpiresAtMs != null &&
          _input!.serverNowMs != null) {
        _expires = math.min(
          _expires!,
          _now() + (f.inputExpiresAtMs! - _input!.serverNowMs!).toInt(),
        );
        _scheduleRoute(f.retryAfterMs);
      } else if ({
            'PROVIDER_UNAVAILABLE',
            'ROUTE_TIMEOUT',
            'PROVIDER_RATE_LIMITED',
          }.contains(f.code) &&
          f.retryable &&
          _retries < 2) {
        _retries++;
        _scheduleRoute(f.retryAfterMs);
      } else {
        _condition = switch (f.code) {
          'CONSENT_REQUIRED_SELF' ||
          'CONSENT_REQUIRED_TARGET' => FollowRouteCondition.consentRequired,
          'PLAN_CHANGED' ||
          'REFERENCE_EXPIRED' ||
          'CONTEXT_MISMATCH' => FollowRouteCondition.resetRequired,
          'ROUTING_DISABLED' ||
          'PROVIDER_AUTH_FAILED' => FollowRouteCondition.disabled,
          'LOCATION_NOT_READY' => FollowRouteCondition.locationDelayed,
          _ => FollowRouteCondition.noRoute,
        };
        if (f.code == 'PLAN_CHANGED') unawaited(refreshPlan(selectedLeader!));
        if (f.code == 'LOCATION_NOT_READY') {
          _retryOnLocation = true;
          _judgedRef = SampleRef.of(_input!.self!);
        }
      }
    } finally {
      if (identical(_routeCancel, c)) _routeCancel = null;
      if (!_disposed) notifyListeners();
    }
  }

  void _scheduleRoute(int delay) {
    _nextAttempt = _now() + math.max(30000, delay);
    if (_nextAttempt! >= _expires!) {
      _nextAttempt = null;
      _condition = FollowRouteCondition.resetRequired;
    } else {
      _condition = FollowRouteCondition.retryWaiting;
    }
  }

  void _judgeFixedRoute() {
    final result = _route ?? _rejectedRoute, fix = _input?.self;
    if (result == null ||
        fix == null ||
        !_fresh ||
        _judgedRef == SampleRef.of(fix))
      return;
    _judgedRef = SampleRef.of(fix);
    final p = projectRoute(RoutePoint.fromFix(fix), result.points);
    if (p?.ambiguous == true) {
      _offSince = null;
      _offSamples = 0;
      return;
    }
    final distance = result.atAnchor
        ? routeDistance(RoutePoint.fromFix(fix), result.anchor)
        : p?.distance ?? double.infinity;
    final previous = _samples.length >= 2
        ? _samples[_samples.length - 2]
        : null;
    final moving =
        previous != null &&
        (fix.speed != null
            ? fix.speed!.isFinite && fix.speed! >= 2
            : routeDistance(
                        RoutePoint.fromFix(previous),
                        RoutePoint.fromFix(fix),
                      ) /
                      ((fix.at - previous.at) / 1000) >=
                  2);
    if (moving && distance > 60.000001) {
      _offSince ??= _now();
      _offSamples++;
    } else {
      _offSince = null;
      _offSamples = 0;
    }
    if (_offSince != null &&
        _now() - _offSince! >= 5000 &&
        _offSamples >= 3 &&
        _routeCancel == null) {
      _route = null;
      _rejectedRoute = result;
      releaseApproach();
      _condition = FollowRouteCondition.offRoute;
      if (_lastAttempt == null || _now() - _lastAttempt! >= 30000) {
        _recoveries.removeWhere((t) => _now() - t >= 300000);
        if (_recoveries.length >= 3) {
          _condition = FollowRouteCondition.resetRequired;
          return;
        }
        _recoveries.add(_now());
        _rejoining = true;
        _startRoute(routeKind!);
        _offSince = null;
        _offSamples = 0;
      }
    }
    if (_route != null &&
        (active!.plan.policy == MeetingPolicy.proceed ||
            active!.plan.destinationOnly ||
            routeKind == PlanRouteKind.planDestination))
      _maybePass(result);
  }

  void _maybePass(FollowRouteResult route) {
    if (_passPending || _now() - _lastPassAt < 1000 || _samples.length < 3)
      return;
    final samples = _samples.sublist(_samples.length - 3);
    if (samples.last.at - samples.first.at < 2000) return;
    final points = samples.map(RoutePoint.fromFix).toList();
    final crossing = projectRoute(route.anchor, points);
    if (crossing == null ||
        crossing.ambiguous ||
        crossing.distance > 25 ||
        routeDistance(points.first, points.last) < 3)
      return;
    if (!route.atAnchor) {
      final projections = points
          .map((p) => projectRoute(p, route.points))
          .toList();
      final bearing = routeBearing(points.first, points.last);
      for (var n = 0; n < points.length; n++) {
        final p = projections[n];
        if (p == null ||
            p.ambiguous ||
            p.distance > 25 &&
                !isBeyondTraceEnd(points[n], route.points, bearing))
          return;
      }
      if (projections.last!.along < routeLength(route.points) - 25 ||
          projections[1]!.along < projections[0]!.along ||
          projections[2]!.along < projections[1]!.along ||
          routeDirectionDifference(
                routeBearing(points.first, points.last),
                projections.last!.bearing,
              ) >
              60)
        return;
    }
    final a = active!, i = _input!, epoch = _epoch, kind = routeKind;
    final c = _operation();
    _passPending = true;
    _lastPassAt = _now();
    unawaited(() async {
      try {
        final j = await request(
          i.room,
          'POST',
          '/follow-plans/${Uri.encodeComponent(a.plan.leaderHandle)}/pass-evidence',
          {
            'planId': a.plan.planId,
            'revision': a.plan.revision,
            'followRequestId': owner ? null : i.relationship,
            'requestId': _id('pass'),
            'ownRefs': samples.map((f) => SampleRef.of(f).toJson()).toList(),
            'pointKind': kind == PlanRouteKind.planJoin
                ? 'joinPoint'
                : 'destination',
          },
          c,
        );
        if (_current(c, epoch, i.identity) &&
            active?.plan.planId == a.plan.planId &&
            j['runtime'] != null)
          applyRuntime(MeetingRuntime.fromJson(j['runtime']));
      } catch (_) {
        /* PASS_NOT_CONFIRMED is a hold, never a local arrival. */
      } finally {
        _pending.remove(c);
        _passPending = false;
      }
    }());
  }

  Future<void> reportTraceStage(String stage) async {
    final a = active, i = _input;
    if (a == null || i?.self == null || traceContext == null || !_fresh) return;
    final c = _operation();
    try {
      await request(
        i!.room,
        'PUT',
        '/follow-plans/${Uri.encodeComponent(a.plan.leaderHandle)}/guidance-status',
        {
          'planId': a.plan.planId,
          'revision': a.plan.revision,
          'followRequestId': i.relationship,
          'originRef': SampleRef.of(i.self!).toJson(),
          'stage': stage,
        },
        c,
      );
    } catch (_) {
    } finally {
      _pending.remove(c);
    }
  }

  void _reportRouteEta() {
    final result = _route, r = _routeRequest, a = active, i = _input;
    if (result == null ||
        r == null ||
        a == null ||
        i?.self == null ||
        !_fresh ||
        identical(_reportedRoute, result) ||
        _condition != FollowRouteCondition.ready ||
        routeKind != r.routeKind ||
        _etaExpired)
      return;
    // One advisory report per usable calculation, with the server's calculation
    // clock and a currently acknowledged sample. Never count down while parked.
    _reportedRoute = result;
    _etaReport?.cancel();
    final c = _etaReport = _operation();
    unawaited(() async {
      try {
        await request(
          i!.room,
          'PUT',
          '/follow-plans/${Uri.encodeComponent(a.plan.leaderHandle)}/guidance-status',
          {
            'planId': a.plan.planId,
            'revision': a.plan.revision,
            'followRequestId': owner ? null : i.relationship,
            'originRef': SampleRef.of(i.self!).toJson(),
            'stage': r.routeKind == PlanRouteKind.planJoin
                ? 'toJoin'
                : 'toDestination',
            'etaSeconds': result.seconds,
            'calculatedAtMs': result.serverNowMs.toInt(),
          },
          c,
        );
        // Progress arrives through the revision-checked SSE stream. An advisory
        // acknowledgement must not restore an old plan or change a branch.
      } catch (_) {
        // Reporting failure does not stop local guidance or trigger routing.
      } finally {
        _pending.remove(c);
        if (identical(_etaReport, c)) _etaReport = null;
      }
    }());
  }

  bool resetGuidance() {
    if (!canEditMeetingPlan || !selected || active == null) return false;
    restored = false;
    _cancelRoute();
    releaseApproach();
    onInvalidated();
    _evaluateRoute();
    notifyListeners();
    return true;
  }

  void _cancelRoute() {
    _etaReport?.cancel();
    _etaReport = null;
    _reportedRoute = null;
    _routeCancel?.cancel();
    _routeCancel = null;
    _routeRequest = null;
    _route = _rejectedRoute = null;
    _originPoint = null;
    _routeKey = null;
    _nextAttempt = _expires = _offSince = _calculatedAt = null;
    _offSamples = 0;
    _judgedRef = null;
    _rejoining = false;
    _condition = FollowRouteCondition.waitingLocation;
    ++_routeGeneration;
    _retryOnLocation = false;
  }

  String get status {
    if (!capabilities.enabled) return '합류 지점 안내를 사용할 수 없습니다';
    if (active == null) return '합류 계획이 종료되었습니다';
    if (restored) return '정차 후 안내를 다시 설정해 주세요';
    final condition = ownRuntime?.condition;
    if (condition == 'traceUnavailable') return '이어서 따라갈 이동 경로가 없습니다';
    if (condition == 'poorAccuracy') return '위치 정확도 확인 중';
    if (condition == 'consentRequired') return '나와 앞차의 최신 동의가 필요합니다';
    if (!_fresh) return _freshSelf ? '앞차 위치 갱신 대기' : '위치와 정차 상태 확인 중';
    if (active!.runtime?.phase == 'leftEarly') return '그룹장이 합류 지점을 떠났습니다';
    if (active!.runtime?.phase == 'traceUnavailable' && routeKind == null)
      return '이어서 따라갈 이동 경로가 없습니다';
    if (active!.runtime?.departureAnnouncedAtMs != null &&
        active!.runtime?.departedAtMs == null)
      return '출발 준비';
    if (active!.runtime == null || active!.runtime!.enrollments.isEmpty)
      return '합류 안내 참여를 기다립니다';
    if (routeKind == null) return ownRuntime?.status ?? '합류 상태 확인 중';
    return switch (_condition) {
      FollowRouteCondition.calculating => '추천 경로 계산 중',
      FollowRouteCondition.retryWaiting =>
        '추천 경로 대기 · ${math.max(0, ((_nextAttempt! - _now()) / 1000).ceil())}초',
      FollowRouteCondition.noRoute => '추천 경로를 찾지 못했습니다',
      FollowRouteCondition.resetRequired => '정차 후 안내를 다시 설정해 주세요',
      FollowRouteCondition.consentRequired => '나와 앞차의 최신 동의가 필요합니다',
      FollowRouteCondition.disabled => '추천 경로 기능을 사용할 수 없습니다',
      FollowRouteCondition.authorizationBlocked => '합류 계획 참여 권한 확인이 필요합니다',
      FollowRouteCondition.locationDelayed => '위치 갱신 대기',
      FollowRouteCondition.offRoute => '경로를 벗어났습니다',
      _ =>
        routeKind == PlanRouteKind.planDestination
            ? (owner ? '목적지로 이동' : '목적지로 먼저 이동')
            : '합류 지점으로 이동',
    };
  }

  bool get _etaExpired =>
      _calculatedAt == null ||
      _now() - _calculatedAt! >= 60000 ||
      _route != null &&
          _input?.serverNowMs != null &&
          _input!.serverNowMs! - _route!.serverNowMs >= 60000;

  String? get etaText => !_fresh || _route == null
      ? null
      : _etaExpired
      ? '예상 시간 갱신 필요'
      : '계산 당시 약 ${(_route!.seconds / 60).ceil()}분 · 실시간 남은 시간 아님';
  String? vehicleEtaText(PlanVehicle vehicle) {
    final now = _input?.serverNowMs;
    if (_input?.connected != true ||
        vehicle.condition != null ||
        now == null ||
        vehicle.calculatedAtMs == null ||
        vehicle.reportedStage == 'toJoin' && vehicle.phase != 'toJoin' ||
        vehicle.phase == 'completed')
      return null;
    if (now - vehicle.calculatedAtMs! >= 60000) return '예상 시간 갱신 필요';
    if (vehicle.etaSeconds == null || now < vehicle.calculatedAtMs!)
      return null;
    return '계산 당시 약 ${(vehicle.etaSeconds! / 60).ceil()}분';
  }

  FollowRouteView? get view => !selected
      ? null
      : FollowRouteView(
          mode: FollowMode.meetingPoint,
          phase: FollowPhase.approaching,
          condition: !_fresh
              ? FollowRouteCondition.locationDelayed
              : _condition,
          connector: routeKind == null
              ? approachRoute?.points ?? const []
              : _condition == FollowRouteCondition.offRoute ||
                    _condition == FollowRouteCondition.resetRequired
              ? const []
              : _route?.points ?? const [],
          trace: const [],
          anchor: null,
          confirmed: true,
          subdued: !_fresh,
          status: status,
          rejoining: _rejoining,
        );
  List<MeetingPin> get pins {
    final p = active?.plan ?? targetPlan?.plan ?? ownPlan?.plan;
    return [
      if (p != null)
        MeetingPin(
          'destination',
          p.destination.point,
          '목적지 · ${p.destination.label}',
        ),
      if (p?.joinPoint != null)
        MeetingPin(
          'joinPoint',
          p!.joinPoint!.point,
          '합류 · ${p.joinPoint!.label}',
        ),
      if (editing && destination != null)
        MeetingPin(
          'draft-destination',
          destination!.point,
          '목적지 초안',
          draft: true,
        ),
      if (editing && joinPoint != null)
        MeetingPin(
          'draft-joinPoint',
          joinPoint!.point,
          '합류 지점 초안',
          draft: true,
        ),
      if (editing && pendingPoint != null)
        MeetingPin(
          'pending',
          pendingPoint!.point,
          field == MeetingPointField.destination ? '목적지 후보' : '합류 지점 후보',
          draft: true,
        ),
    ];
  }

  void _announce() {
    final a = active;
    if (a == null) return;
    final event = '${a.plan.planId}:${a.plan.revision}:${ownRuntime?.phase}';
    final text = switch (ownRuntime?.phase) {
      'atJoinWaiting' => '합류 지점 근처입니다. 함께 출발할 때까지 기다립니다',
      'toDestination' => '목적지로 먼저 이동합니다',
      _ => null,
    };
    if (text != null && _announced.add(event)) onNotice(event, text);
  }

  void _cancelOperations() {
    for (final c in _pending) {
      c.cancel();
    }
    _pending.clear();
    busy = false;
    _passPending = false;
  }

  void clear() {
    ++_epoch;
    _cancelOperations();
    closeEditor();
    _cancelRoute();
    releaseApproach();
    _plans.clear();
    _retired.clear();
    _samples.clear();
    _sampleReceipts.clear();
    participants = const [];
    capabilities = const MeetingCapabilities();
    selectedLeader = null;
    _selectedPlanId = null;
    _selectedRelationship = null;
    restored = false;
    _destinationBranch = false;
    _input = null;
    error = null;
    _announced.clear();
    onInvalidated();
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
