import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/mic_router.dart';
import '../auth/session_store.dart';
import '../call/call_service.dart';
import '../call/call_state.dart';
import '../call/media_engine.dart';
import '../call/mesh_coordinator.dart';
import '../core/errors.dart';
import '../core/device_mode.dart';
import '../location/location_share.dart';
import '../location/location_source.dart';
import '../net/api_client.dart';
import '../net/models.dart';

const joinedRoomReason = '이미 참여 중인 방이 있음 — 나간 뒤 만들 수 있음';
const _unchanged = Object();

class _FollowStart {
  _FollowStart(this.code, this.target, this.requestId)
    : incoming = requestId != null;
  final String code, target;
  final bool incoming;
  String? requestId;
}

class RoomState {
  const RoomState({
    this.code,
    this.room,
    this.members = const [],
    this.isConnected = false,
    this.isLeaving = false,
    this.error,
  });
  final String? code;
  final Room? room;
  final List<Member> members;
  final bool isConnected;
  final bool isLeaving;
  final String? error;
  RoomState copyWith({
    Room? room,
    List<Member>? members,
    bool? isConnected,
    bool? isLeaving,
    Object? error = _unchanged,
  }) => RoomState(
    code: code,
    room: room ?? this.room,
    members: members ?? this.members,
    isConnected: isConnected ?? this.isConnected,
    isLeaving: isLeaving ?? this.isLeaving,
    error: identical(error, _unchanged) ? this.error : error as String?,
  );
}

class RoomSession extends ChangeNotifier {
  RoomSession({
    required this.api,
    required this.mediaEngine,
    required this.store,
    required this.callService,
    required this.micRouter,
    this.deviceMode,
    LocationSource? locationSource,
    DateTime Function()? locationNow,
  }) {
    locationShare = LocationShare(
      api: api,
      source: locationSource,
      roomCode: () => state.isLeaving ? null : state.code,
      selfHandle: () => store.handle,
      now: locationNow,
    );
    _lastLocationState = _locationState();
    locationShare.addListener(_locationChanged);
    callService.onLeaveCall = leave;
    callService.onToggleMute = () {
      if (call.isActive || joiningCall) setMuted(!muted);
    };
    _lastAudioState = _audioState();
    micRouter.addListener(_audioChanged);
    callVolume = store.callVolume;
    store.addListener(_profileChanged);
    callService.addListener(_nativeCallChanged);
    mediaEngine.localSpeaking = _setLocalSpeaking;
    mediaEngine.remoteSpeaking = (handle, speaking) {
      if (speaking) {
        _speaking.add(handle);
        mediaEngine.onRemoteSpeaking(handle);
      } else {
        _speaking.remove(handle);
      }
      _notify();
    };
    mediaEngine.sendSignal = (to, kind, payload) async {
      final code = state.code;
      if (code != null) await api.sendSignal(code, to, kind, payload);
    };
    mediaEngine.connectionChanged = (connection, message) {
      mediaConnection = connection;
      mediaError = message;
      // The engine emits failed only after every peer exhausts recovery.
      if (connection == MediaConnectionState.failed && !joiningCall) {
        _scheduleRetry();
      } else if (connection == MediaConnectionState.connected) {
        if (!joiningCall) retryAttempts = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
      }
      _notify();
    };
    _peerSubscription = mediaEngine.peerStateChanges.listen((_) => _notify());
  }
  final ApiClient api;
  final MediaEngine mediaEngine;
  final SessionStore store;
  final CallService callService;
  final MicRouter micRouter;
  final DeviceMode? deviceMode;
  late final LocationShare locationShare;
  late final StreamSubscription<Map<String, MeshPeerState>> _peerSubscription;
  Map<String, MeshPeerState> get peerStates => mediaEngine.peerStates;
  RoomState _state = const RoomState();
  RoomState get state => _state;
  set state(RoomState value) {
    final changedRoom = _state.code != value.code;
    final changedMembers = !identical(_state.members, value.members);
    _state = value;
    if (changedRoom) {
      _displayNames.clear();
      _clearLocations();
    }
    if (changedRoom || changedMembers) {
      for (final member in value.members) {
        _rememberDisplayName(member.handle, member.displayName);
      }
    }
    locationShare.roomChanged();
  }

  final Map<String, String> _displayNames = {};

  String displayNameOf(String handle) {
    final name = state.members
        .where((member) => member.handle == handle)
        .firstOrNull
        ?.displayName;
    return name != null && name.trim().isNotEmpty
        ? name
        : _displayNames[handle] ?? handle;
  }

  void _rememberDisplayName(String handle, String? name) {
    if (name != null && name.trim().isNotEmpty) _displayNames[handle] = name;
  }

  final Map<String, LocationFix> _positions = {};
  Map<String, LocationFix> get positions => Map.unmodifiable(_positions);
  String? _leaderHandle;
  String? get leaderHandle => _leaderHandle;
  final Map<String, List<LocationFix>> _trails = {};
  List<LocationFix> trailOf(String? handle) =>
      List.unmodifiable(_trails[handle] ?? const <LocationFix>[]);
  final Map<String, Map<String, int>> _lastTrailSeq = {};
  String? _followTarget;
  String? get followTarget => _followTarget;
  String? _pendingFollow, _followRequestId;
  String? get pendingFollow => _pendingFollow;
  String? get followIntent => _pendingFollow ?? _followTarget;
  String? get followRequestId => _followRequestId;
  int _serverRevision = 0;
  int get followServerRevision => _serverRevision;
  bool _followPostInFlight = false;
  final Set<Object> _followStops = {};
  final List<FollowResponse> _earlyFollowResponses = [];
  final Map<Object, _FollowStart> _locationStarts = {};

  Object beginLocationStart(String target, {String? requestId}) {
    final token = Object();
    final code = state.code;
    if (code != null)
      _locationStarts[token] = _FollowStart(code, target, requestId);
    return token;
  }

  bool locationStartValid(Object token) {
    final start = _locationStarts[token];
    return start != null &&
        !_disposed &&
        !state.isLeaving &&
        state.code == start.code &&
        (start.incoming
            ? (_followRequests.containsKey(start.requestId) ||
                  _respondingRequests.contains(start.requestId))
            : state.members.any((member) => member.handle == start.target) &&
                  (start.requestId == null ||
                      start.requestId == _followRequestId));
  }

  void finishLocationStart(Object token) {
    _locationStarts.remove(token);
    locationShare.commitStart(token);
  }

  void cancelLocationStart(Object token) {
    _locationStarts.remove(token);
    locationShare.invalidateStart(token);
  }

  void _cancelStarts({
    String? handle,
    String? requestId,
    bool accepted = false,
  }) {
    for (final entry in _locationStarts.entries.toList()) {
      if (handle != null && entry.value.target != handle ||
          requestId != null && entry.value.requestId != requestId)
        continue;
      if (accepted)
        finishLocationStart(entry.key);
      else
        cancelLocationStart(entry.key);
    }
  }

  bool _followRequestSent = false;
  int _followRevision = 0;
  int? _followMotionRevision;
  Future<void> _followQueue = Future<void>.value();
  final Map<String, FollowRequest> _followRequests = {};
  Map<String, FollowRequest> get followRequests =>
      Map.unmodifiable(_followRequests);
  final Set<String> _requestsRefreshing = {};
  final Set<String> _respondingRequests = {};
  Iterable<FollowRequest> get readyFollowRequests => _followRequests.values
      .where((request) => !_requestsRefreshing.contains(request.requestId));
  final List<FollowResponse> _followNotices = [];
  FollowResponse? takeFollowNotice() =>
      _followNotices.isEmpty ? null : _followNotices.removeAt(0);
  bool get hasFollowNotice => _followNotices.isNotEmpty;
  String? _followError;
  String? get followError => _followError;
  late List<Object?> _lastLocationState;
  Room? _restorableRoom;
  Room? get restorableRoom => _restorableRoom;

  void setRestorableRoom(Room? room) {
    if (_disposed || state.code != null) return;
    _restorableRoom = room;
    _notify();
  }

  CallState get call => callService.state;
  bool muted = false;
  bool speakerphone = true;
  late int callVolume;
  bool permissionDenied = false;
  int retryAttempts = 0;
  Timer? _retryTimer;
  bool _wantCall = false;
  bool _interrupted = false;
  late List<Object?> _lastAudioState;
  bool get interrupted => micRouter.audioInterrupted;
  int? _lastSystemVolume;
  bool _settingVolume = false;
  Future<void> _volumeQueue = Future<void>.value();
  OutputRoute get outputRoute => micRouter.outputRoute;
  bool get canReconnect =>
      mediaConnection == MediaConnectionState.failed &&
      !joiningCall &&
      _retryTimer == null;
  String get outputLabel =>
      '현재 ${outputRoute.label}. 전환 순서: '
      '${micRouter.availableOutputRoutes.map((route) => route.label).join(' → ')}';
  bool joiningCall = false;
  MediaConnectionState mediaConnection = MediaConnectionState.idle;
  String? mediaError;
  String? get callJoinBlockedReason {
    final handle = store.handle;
    if (handle == null || !state.isConnected) return '방 연결을 기다려 주세요.';
    if (!state.members.any((member) => member.handle == handle)) {
      return '방 참여 정보를 기다려 주세요.';
    }
    if (!MeshCoordinator.canJoin(
      handle,
      state.members.map((member) => member.handle),
    )) {
      return meshCapacityReason;
    }
    return null;
  }

  bool _disposed = false;
  bool _mediaJoined = false;
  bool _localSpeaking = false;
  bool get localSpeaking => _localSpeaking;
  final Set<String> _speaking = {};
  Set<String> get speaking => Set.unmodifiable(_speaking);
  StreamSubscription<RoomEvent>? _subscription;
  Future<void> _eventQueue = Future<void>.value();
  Future<void>? _stopFuture;
  int _generation = 0;
  int _callGeneration = 0;

  void _setLocalSpeaking(bool speaking) {
    final value =
        speaking && !muted && !interrupted && call.isActive && !state.isLeaving;
    if (_localSpeaking == value || _disposed) return;
    _localSpeaking = value;
    _notify();
  }

  Future<void> open(String code, {bool force = false}) async {
    if (state.isLeaving) return;
    if (!force && state.code == code && _subscription != null) return;
    if (state.code != null && state.code != code)
      throw StateError(joinedRoomReason);
    if (state.code == null) {
      _wantCall = true;
      retryAttempts = 0;
      permissionDenied = false;
      speakerphone = true;
    }
    final generation = ++_generation;
    await _subscription?.cancel();
    _subscription = null;
    if (!_current(generation)) return;
    _restorableRoom = null;
    state = state.code == code
        ? state.copyWith(error: null, isConnected: false)
        : RoomState(code: code);
    _notify();
    await _refresh(code, generation);
    if (!_current(generation)) return;
    // Wait for hello.members before restoring the media session.
    _eventQueue = Future<void>.value();
    _subscription = api
        .subscribeEvents(code)
        .listen(
          (event) {
            // hello / 재연결 / 멤버 갱신은 Kotlin collect처럼 순서대로 처리한다.
            _eventQueue = _eventQueue
                .then((_) async {
                  if (!_current(generation)) return;
                  await _onEvent(code, event, generation);
                })
                .catchError((Object error) {
                  if (_current(generation))
                    _setError(exceptionMessage(error, '방 연결을 확인해 주세요.'));
                });
          },
          onError: (Object error) {
            if (!_current(generation)) return;
            if (_isAccessError(error)) {
              unawaited(_forgetInaccessibleRoom(error as ApiException));
              return;
            }
            ++_generation;
            _subscription = null;
            state = state.copyWith(
              isConnected: false,
              error: exceptionMessage(error, '방 연결을 확인해 주세요.'),
            );
            _notify();
          },
          onDone: () {
            if (_current(generation)) {
              _subscription = null;
            }
          },
        );
  }

  Future<void> _onEvent(String code, RoomEvent event, int generation) async {
    switch (event) {
      case FollowRequest():
        if (event.requester == store.handle || event.revision < _serverRevision)
          return;
        _serverRevision = event.revision;
        _rememberDisplayName(event.requester, event.displayName);
        _followRequests[event.requestId] = event;
        if (!state.members.any((m) => m.handle == event.requester)) {
          // 이벤트 큐를 HTTP 뒤에 묶지 않아 그 사이의 취소를 먼저 적용할 수 있다.
          _requestsRefreshing.add(event.requestId);
          unawaited(
            _refresh(code, generation).whenComplete(() {
              _requestsRefreshing.remove(event.requestId);
              if (_current(generation)) _notify();
            }),
          );
        }
        _notify();
        return;
      case FollowCancelled():
        _serverRevision = event.revision > _serverRevision
            ? event.revision
            : _serverRevision;
        _cancelStarts(
          requestId: event.requestId,
          accepted: event.reason == 'accepted',
        );
        if (_followRequests.remove(event.requestId) != null) _notify();
        return;
      case FollowResponse():
        if (_followPostInFlight) {
          if (event.target == _pendingFollow &&
              (event.requester.isEmpty || event.requester == store.handle)) {
            _earlyFollowResponses.add(event);
          }
          return;
        }
        _applyFollowResponse(event);
        return;
      case TrailUpdated():
        if (event.handle != followIntent || event.revision < _serverRevision)
          return;
        _setTrails({event.handle: event.points});
        _notify();
        return;
      case LocationUpdated():
        if (event.revision > _serverRevision) _serverRevision = event.revision;
        if (_updateLocation(event.fix)) _notify();
        return;
      case LocationStopped():
        if (event.revision < _serverRevision) return;
        if (event.revision > _serverRevision) _serverRevision = event.revision;
        var changed = _positions.remove(event.handle) != null;
        changed = _trails.remove(event.handle) != null || changed;
        _lastTrailSeq.remove(event.handle);
        if (followIntent == event.handle) {
          _endFollow(
            FollowResponse(
              event.handle,
              false,
              requestId: _followRequestId ?? '',
              reason: event.reason,
              revision: event.revision,
            ),
          );
          changed = true;
        }
        _cancelStarts(handle: event.handle);
        if (changed) _notify();
        return;
      case Signal():
        await mediaEngine.onSignal(event.from, event.kind, event.payload);
      case Disconnected():
        state = state.copyWith(
          isConnected: false,
          error: '${event.message} (${event.retryInMillis ~/ 1000}초 후)',
        );
      case Reconnected():
        try {
          await api.joinRoom(code);
          if (!_current(generation)) return;
          await _refresh(code, generation);
          if (_current(generation) && _mediaJoined) {
            await mediaEngine.reconcilePeers(
              state.members.map((member) => member.handle).toList(),
            );
          }
        } catch (error) {
          if (!_current(generation)) return;
          if (_isAccessError(error)) {
            await _forgetInaccessibleRoom(error as ApiException);
          } else {
            _setError(exceptionMessage(error, '방에 다시 참여하지 못했습니다.'));
          }
        }
      case Hello():
        if (event.revision < _serverRevision) {
          state = state.copyWith(isConnected: true, error: null);
          _maybeAutoJoin();
          _notify();
          return;
        }
        _setLocationSnapshot(event);
        await _setMembers(event.members);
        if (!_current(generation)) return;
        // Keep live peers; repair only offers lost while SSE was unavailable.
        state = state.copyWith(isConnected: true, error: null);
        if (_mediaJoined) {
          await mediaEngine.reconcilePeers(
            state.members.map((member) => member.handle).toList(),
          );
          if (!_current(generation)) return;
        }
        _maybeAutoJoin();
      case MemberJoined():
        if (event.revision > _serverRevision) _serverRevision = event.revision;
        await _refresh(code, generation);
      case MemberUpdated():
        state = state.copyWith(
          members: [
            for (final member in state.members)
              if (member.handle == event.handle &&
                  event.avatar.version >= member.avatar.version)
                member.withAvatar(event.avatar)
              else
                member,
          ],
        );
        if (event.handle == store.handle)
          await store.updateAvatar(event.avatar);
      case MemberLeft():
        if (event.revision > _serverRevision) _serverRevision = event.revision;
        _positions.remove(event.handle);
        _cancelStarts(handle: event.handle);
        _followRequests.removeWhere(
          (_, request) => request.requester == event.handle,
        );
        _trails.remove(event.handle);
        _lastTrailSeq.remove(event.handle);
        if (followIntent == event.handle) {
          _endFollow(
            FollowResponse(
              event.handle,
              false,
              requestId: _followRequestId ?? '',
              reason: 'left',
            ),
          );
        }
        // Close immediately, even if the subsequent HTTP refresh fails.
        await _setMembers(
          state.members.where((m) => m.handle != event.handle).toList(),
        );
        await _refresh(code, generation);
    }
    if (!_current(generation)) return;
    // Only hello establishes readiness. Signals during a reconnect are not hello.
    if (event is MemberJoined || event is MemberLeft) _maybeAutoJoin();
    _notify();
  }

  Future<void> _refresh(String code, int generation) async {
    try {
      final details = await api.getRoom(code);
      if (_current(generation) && state.code == code) {
        state = state.copyWith(room: details.room, error: null);
        _setLeader(details.room.leader);
        await _setMembers(details.members);
        _notify();
      }
    } catch (error) {
      if (!_current(generation)) return;
      if (_isAccessError(error)) {
        await _forgetInaccessibleRoom(error as ApiException);
      } else {
        _setError(exceptionMessage(error, '참여자를 불러오지 못했습니다.'));
      }
    }
  }

  Future<void> _setMembers(List<Member> members) async {
    // 늦은 HTTP/hello 응답이 이미 받은 새 프로필 버전을 덮지 않는다.
    final previous = {
      for (final member in state.members) member.handle: member.avatar,
    };
    final self = store.handle;
    if (self != null &&
        store.avatar.version > (previous[self]?.version ?? -1)) {
      previous[self] = store.avatar;
    }
    members = [
      for (final member in members)
        if ((previous[member.handle]?.version ?? -1) > member.avatar.version)
          member.withAvatar(previous[member.handle]!)
        else
          member,
    ];
    state = state.copyWith(members: members);
    for (final member in members) {
      if (member.handle == store.handle && member.avatar != store.avatar) {
        await store.updateAvatar(member.avatar);
      }
    }
    _speaking.removeWhere((handle) => !members.any((m) => m.handle == handle));
    await mediaEngine.setMembers(members.map((m) => m.handle).toList());
    if (_mediaJoined &&
        !MeshCoordinator.canJoin(
          store.handle ?? '',
          members.map((m) => m.handle),
        )) {
      _mediaJoined = false;
      _setLocalSpeaking(false);
      await mediaEngine.leave();
      mediaError = meshCapacityReason;
    }
  }

  void _setLeader(String? handle) => _leaderHandle = handle;

  void _profileChanged() {
    final index = state.members.indexWhere(
      (member) => member.handle == store.handle,
    );
    if (index < 0 ||
        store.avatar.version <= state.members[index].avatar.version)
      return;
    final members = [...state.members];
    members[index] = members[index].withAvatar(store.avatar);
    state = state.copyWith(members: members);
    _notify();
  }

  void _setLocationSnapshot(Hello event) {
    _setLeader(event.leader ?? state.room?.leader);
    if (event.revision < _serverRevision) return;
    _positions.clear();
    for (final fix in event.positions) {
      final previous = _positions[fix.handle];
      if (previous == null ||
          fix.stream != previous.stream ||
          fix.seq > previous.seq) {
        _positions[fix.handle] = fix;
      }
    }
    // 진행 중 POST가 아직 ID/revision을 돌려주지 않았다면 사용자 의도를 보존한다.
    if (!_followPostInFlight && _followStops.isEmpty) {
      final previousIntent = followIntent;
      _followTarget = locationShare.sharing ? event.followTarget : null;
      _pendingFollow = locationShare.sharing ? event.pendingFollow : null;
      _followRequestId = locationShare.sharing ? event.followRequestId : null;
      _followRequestSent = followIntent != null;
      if (previousIntent != followIntent) {
        ++_followRevision;
        _followMotionRevision = null;
      }
      _setTrails(locationShare.sharing ? event.trails : const {});
      _serverRevision = event.revision;
      for (final entry in _locationStarts.entries.toList()) {
        final start = entry.value;
        if (start.incoming || start.requestId == null) continue;
        if (start.requestId != _followRequestId)
          cancelLocationStart(entry.key);
        else if (_followTarget != null)
          finishLocationStart(entry.key);
      }
    }
    final incomingIds = event.followRequests
        .map((request) => request.requestId)
        .toSet();
    for (final request in event.followRequests) {
      _rememberDisplayName(request.requester, request.displayName);
    }
    for (final id in _followRequests.keys.toList()) {
      if (!incomingIds.contains(id) && !_respondingRequests.contains(id))
        _cancelStarts(requestId: id);
    }
    _followRequests
      ..clear()
      ..addEntries(
        event.followRequests.map(
          (request) => MapEntry(request.requestId, request),
        ),
      );
  }

  void _endFollow(FollowResponse event) {
    _followTarget = null;
    _pendingFollow = null;
    _followRequestId = null;
    _followRequestSent = false;
    _followPostInFlight = false;
    _earlyFollowResponses.clear();
    _setTrails(const {});
    ++_followRevision;
    _followNotices.add(event);
  }

  void _applyFollowResponse(FollowResponse event) {
    if (event.requestId != _followRequestId || event.target != followIntent)
      return;
    if (event.revision > _serverRevision) _serverRevision = event.revision;
    _cancelStarts(requestId: event.requestId, accepted: event.accepted);
    if (event.accepted) {
      _followTarget = event.target;
      _pendingFollow = null;
    } else {
      _endFollow(event);
    }
    _notify();
  }

  void _setTrails(Map<String, List<LocationFix>> trails) {
    _trails.clear();
    _lastTrailSeq.clear();
    for (final entry in trails.entries) {
      _trails[entry.key] = [];
      for (final fix in entry.value) {
        if (fix.handle == entry.key) _appendTrail(fix);
      }
    }
  }

  bool _appendTrail(LocationFix fix) {
    final trail = _trails[fix.handle];
    if (trail == null) return false;
    final sequences = _lastTrailSeq.putIfAbsent(fix.handle, () => {});
    if (fix.seq <= (sequences[fix.stream] ?? -1)) return false;
    sequences[fix.stream] = fix.seq;
    trail.add(fix);
    if (trail.length > 7200) trail.removeRange(0, trail.length - 7200);
    return true;
  }

  bool _updateLocation(LocationFix fix) {
    final previous = _positions[fix.handle];
    if (previous != null &&
        fix.stream == previous.stream &&
        fix.seq <= previous.seq)
      return false;
    _positions[fix.handle] = fix;
    _appendTrail(fix);
    return true;
  }

  bool get _carMode =>
      (deviceMode ??
          (micRouter.isAutomotive ? DeviceMode.car : DeviceMode.phone)) ==
      DeviceMode.car;

  bool get followNeedsStop =>
      _carMode && locationShare.motionState == LocationMotionState.moving;

  bool checkFollowAllowed(String target) {
    if (_disposed ||
        state.code == null ||
        state.isLeaving ||
        target == store.handle ||
        !state.members.any((member) => member.handle == target))
      return false;
    final error = followNeedsStop ? '정차 후 설정할 수 있습니다' : null;
    if (_followError != error) {
      _followError = error;
      _notify();
    }
    return error == null;
  }

  Future<void> _queueFollowOperation(Future<void> Function() action) {
    final operation = _followQueue.then((_) => action());
    _followQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<T> _followApi<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ApiException catch (error) {
      if (error.code != 'FOLLOW_RATE_LIMIT') rethrow;
      await Future<void>.delayed(const Duration(seconds: 1));
      return action();
    }
  }

  Future<void> _queueStopFollowing(String code) {
    final token = Object();
    _followStops.add(token);
    return _queueFollowOperation(() => _stopServerFollowing(code)).whenComplete(
      () {
        _followStops.remove(token);
      },
    );
  }

  Future<void> _stopServerFollowing(String code) async {
    final revision = await _followApi(() => api.stopFollowing(code));
    if (state.code == code && revision > _serverRevision)
      _serverRevision = revision;
  }

  Future<void> startFollowing(String target) async {
    if (target == followIntent ||
        !checkFollowAllowed(target) ||
        !locationShare.sharing)
      return;
    // 다른 pending 대상에서 전환할 때 이미 켜진 공유는 이번 동의로 이어 쓴다.
    for (final entry in _locationStarts.entries.toList()) {
      if (!entry.value.incoming && entry.value.target != target)
        finishLocationStart(entry.key);
    }
    final code = state.code!;
    final revision = ++_followRevision;
    _followMotionRevision =
        _carMode && locationShare.motionState == LocationMotionState.unknown
        ? revision
        : null;
    _followTarget = null;
    _pendingFollow = target;
    _followRequestId = null;
    _followPostInFlight = true;
    _earlyFollowResponses.clear();
    _setTrails(const {});
    _notify();
    try {
      await _queueFollowOperation(() async {
        if (_disposed ||
            revision != _followRevision ||
            state.code != code ||
            !locationShare.sharing)
          return;
        _followRequestSent = true;
        final result = await _followApi(() => api.follow(code, target));
        if (state.code == code && result.revision > _serverRevision)
          _serverRevision = result.revision;
        if (_disposed ||
            state.code != code ||
            state.isLeaving ||
            !locationShare.sharing) {
          try {
            await _stopServerFollowing(code);
          } on ApiException catch (error) {
            if (!_isAccessError(error)) rethrow;
          }
          return;
        }
        if (revision != _followRevision) return; // 취소 DELETE는 같은 큐에서 뒤이어 실행된다.
        _followRequestId = result.requestId;
        for (final start in _locationStarts.values) {
          if (!start.incoming && start.code == code && start.target == target)
            start.requestId = result.requestId;
        }
        if (result.accepted)
          _cancelStarts(requestId: result.requestId, accepted: true);
        _followPostInFlight = false;
        _followTarget = result.accepted ? target : null;
        _pendingFollow = result.accepted ? null : target;
        final early = List<FollowResponse>.of(_earlyFollowResponses);
        _earlyFollowResponses.clear();
        for (final event in early) _applyFollowResponse(event);
      });
    } catch (_) {
      if (revision == _followRevision && state.code == code) {
        _followTarget = null;
        _pendingFollow = null;
        _followRequestId = null;
        _followRequestSent = false;
      }
      rethrow;
    } finally {
      if (revision == _followRevision) _followPostInFlight = false;
      _notify();
    }
  }

  Future<void> stopFollowing() async {
    final code = state.code;
    if (code == null || followIntent == null) return;
    final requestSent = _followRequestSent;
    final requestId = _followRequestId;
    _followTarget = null;
    _pendingFollow = null;
    _followRequestId = null;
    _followRequestSent = false;
    _followPostInFlight = false;
    _earlyFollowResponses.clear();
    _setTrails(const {});
    ++_followRevision;
    _followError = null;
    _notify();
    if (requestId != null) _cancelStarts(requestId: requestId);
    if (requestSent) await _queueStopFollowing(code);
  }

  Future<void> respondToFollow(
    String requestId, {
    required bool accepted,
  }) async {
    final code = state.code;
    if (code == null ||
        state.isLeaving ||
        !_followRequests.containsKey(requestId))
      return;
    if (accepted && !locationShare.sharing) return;
    try {
      final revision = await _queueFollowResponse(code, requestId, accepted);
      if (state.code == code && revision > _serverRevision)
        _serverRevision = revision;
      if (accepted) _cancelStarts(requestId: requestId, accepted: true);
    } on ApiException catch (error) {
      if (error.code != 'FOLLOW_EXPIRED') rethrow;
      _cancelStarts(requestId: requestId);
    } finally {
      _respondingRequests.remove(requestId);
      if (state.code == code) _followRequests.remove(requestId);
      _notify();
    }
  }

  Future<int> _queueFollowResponse(
    String code,
    String requestId,
    bool accepted,
  ) async {
    var revision = _serverRevision;
    await _queueFollowOperation(() async {
      // 권한·이전 요청 대기 중 취소된 ID는 서버에 보내지 않는다.
      if (state.code != code ||
          state.isLeaving ||
          !_followRequests.containsKey(requestId))
        return;
      _respondingRequests.add(requestId);
      revision = await _followApi(
        () => api.respondFollow(code, requestId, accepted: accepted),
      );
      // DELETE /location은 이 requestId도 제거한다. 늦은 응답이 새 방의 공유를 끄지 않는다.
    });
    return revision;
  }

  List<Object?> _locationState() => [
    locationShare.available,
    locationShare.sharing,
    locationShare.permission,
    locationShare.error,
    locationShare.lastSent,
    locationShare.motionState,
    locationShare.deletionPending,
  ];

  void _locationChanged() {
    final next = _locationState();
    if (listEquals(next, _lastLocationState)) return;
    final previousFix = _lastLocationState[4];
    final wasSharing = _lastLocationState[1] as bool;
    _lastLocationState = next;
    final firstMotion =
        followIntent != null &&
        _followMotionRevision == _followRevision &&
        locationShare.motionState != LocationMotionState.unknown;
    final rejectFollow = firstMotion && followNeedsStop;
    if (firstMotion) _followMotionRevision = null;
    final fix = locationShare.lastSent;
    if (locationShare.sharing && fix != null && fix != previousFix) {
      // 서버는 송신자에게 반사하지 않으므로 성공한 로컬 표본을 반영한다.
      _updateLocation(fix);
    }
    if (wasSharing && !locationShare.sharing || rejectFollow) {
      if (!locationShare.sharing) {
        _positions.remove(store.handle);
        _cancelStarts();
      }
      if (rejectFollow) {
        _followError = '정차 후 설정할 수 있습니다';
        // 첫 이동 판정은 따라가기만 취소하고 동의한 내 공유는 유지한다.
        for (final entry in _locationStarts.entries.toList()) {
          if (!entry.value.incoming) finishLocationStart(entry.key);
        }
      }
      final code = state.code;
      if (_followRequestSent && code != null) {
        unawaited(
          _queueStopFollowing(code).catchError((Object error) {
            if (!_disposed && state.code == code && !rejectFollow) {
              _followError = errorMessage(error);
              _notify();
            }
          }),
        );
      }
      _followTarget = null;
      _pendingFollow = null;
      _followRequestId = null;
      _followPostInFlight = false;
      _earlyFollowResponses.clear();
      _setTrails(const {});
      _followRequestSent = false;
      ++_followRevision;
    }
    _notify();
  }

  void _clearLocations() {
    _followStops.clear();
    _serverRevision = 0;
    _pendingFollow = null;
    _followRequestId = null;
    _followPostInFlight = false;
    _earlyFollowResponses.clear();
    _requestsRefreshing.clear();
    _respondingRequests.clear();
    _positions.clear();
    _leaderHandle = null;
    _trails.clear();
    _lastTrailSeq.clear();
    _followTarget = null;
    _followRequestSent = false;
    ++_followRevision;
    _followRequests.clear();
    _followNotices.clear();
    _followError = null;
    _cancelStarts();
  }

  void _maybeAutoJoin() {
    if (!_wantCall ||
        _disposed ||
        joiningCall ||
        _retryTimer != null ||
        permissionDenied ||
        retryAttempts >= 3 && mediaConnection == MediaConnectionState.failed ||
        callJoinBlockedReason != null)
      return;
    if (mediaConnection == MediaConnectionState.failed) {
      _scheduleRetry();
    } else if (!_mediaJoined) {
      unawaited(_autoJoin());
    }
  }

  Future<void> _autoJoin() async {
    try {
      await joinCall();
    } catch (_) {
      /* State and retry are owned by joinCall. */
    }
  }

  void _scheduleRetry() {
    if (!_wantCall ||
        _disposed ||
        state.isLeaving ||
        joiningCall ||
        permissionDenied ||
        _retryTimer != null ||
        retryAttempts >= 3 ||
        callJoinBlockedReason != null)
      return;
    final delay = Duration(seconds: 1 << retryAttempts);
    retryAttempts++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_wantCall && !_disposed && !state.isLeaving) unawaited(_autoJoin());
    });
    _notify();
  }

  Future<void> reconnect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    retryAttempts = 0;
    permissionDenied = false;
    _wantCall = true;
    if (!state.isConnected && state.code != null) {
      // Keep an existing mesh alive while reconnecting SSE.
      await open(state.code!, force: true);
    } else {
      if (_mediaJoined) mediaConnection = MediaConnectionState.failed;
      await joinCall();
    }
  }

  Future<void> joinCall() async {
    final code = state.code;
    final handle = store.handle;
    if (code == null ||
        handle == null ||
        joiningCall ||
        call.isStopping ||
        _stopFuture != null ||
        state.isLeaving)
      return;
    if (_mediaJoined && mediaConnection != MediaConnectionState.failed) return;
    final blocked = callJoinBlockedReason;
    if (blocked != null) return;
    if (call.roomCode != null && call.roomCode != code) {
      throw StateError('현재 통화에서 나간 뒤 다른 방에 참여해 주세요.');
    }
    final generation = ++_callGeneration;
    bool current() =>
        !_disposed &&
        _wantCall &&
        generation == _callGeneration &&
        state.code == code &&
        !state.isLeaving;
    joiningCall = true;
    mediaConnection = MediaConnectionState.connecting;
    mediaError = null;
    _notify();
    try {
      final details = await api.getRoom(code);
      if (!current()) return;
      await _setMembers(details.members);
      if (!current() || callJoinBlockedReason != null) {
        mediaConnection = MediaConnectionState.idle;
        return;
      }
      await micRouter.refreshPermissions();
      if (!current()) return;
      if (!micRouter.permissions.microphone)
        await micRouter.requestPermissions();
      if (!current()) return;
      if (!micRouter.permissions.microphone) {
        permissionDenied = true;
        throw StateError(
          defaultTargetPlatform == TargetPlatform.iOS
              ? '마이크 권한이 꺼져 있습니다. 설정 > 우나보 > 마이크를 켜 주세요.'
              : '마이크 권한이 꺼져 있습니다. 설정 > 앱 > 우나보 > 권한에서 마이크를 허용해 주세요.',
        );
      }
      permissionDenied = false;
      await micRouter.stopPreview();
      if (!current()) return;
      // On Android this starts a microphone FGS on phones AND cars, while
      // the app is visible, before allocating WebRTC audio. Retries retain it.
      if (!call.isActive) await callService.start(code, handle);
      if (!current()) {
        // A late native start must not survive the user's exit.
        if (call.roomCode == code) await callService.stop();
        return;
      }
      if (!call.isActive) throw StateError(call.error ?? '통화 서비스를 시작하지 못했습니다.');
      if (_mediaJoined) {
        _mediaJoined = false;
        _setLocalSpeaking(false);
        await mediaEngine.leave();
        if (!current()) return;
      }
      await micRouter.refreshOutputRoute();
      if (!current()) return;
      if (carVolumeSlider &&
          micRouter.isAutomotive &&
          micRouter.systemVolumeWritable &&
          micRouter.systemCallVolume != null) {
        callVolume = micRouter.systemCallVolume!;
        _lastSystemVolume = callVolume;
        await store.setCallVolume(callVolume);
      }
      mediaEngine.setMuted(muted);
      mediaEngine.setInterrupted(micRouter.audioInterrupted);
      await mediaEngine.setVolume(callVolume / 100);
      if (!current()) return;
      _mediaJoined = true;
      await mediaEngine.join(code, handle);
      if (!current()) return;
      await micRouter.applyOutputRoute();
      if (mediaConnection == MediaConnectionState.connected) retryAttempts = 0;
      speakerphone = outputRoute == OutputRoute.speaker;
    } catch (error) {
      if (current() && _isAccessError(error)) {
        await _forgetInaccessibleRoom(error as ApiException);
        return;
      }
      if (current()) {
        _mediaJoined = false;
        _setLocalSpeaking(false);
        try {
          await mediaEngine.leave();
        } catch (_) {
          /* Keep the original error. */
        }
        if (current()) {
          mediaConnection = MediaConnectionState.failed;
          mediaError = exceptionMessage(error, '음성 연결을 시작하지 못했습니다.');
        }
      }
      rethrow;
    } finally {
      joiningCall = false;
      if (current() && mediaConnection == MediaConnectionState.failed)
        _scheduleRetry();
      _notify();
    }
  }

  Future<void> leaveCall() {
    return _stopFuture ??= _stopCall().whenComplete(() {
      _stopFuture = null;
    });
  }

  Future<void> _stopCall() async {
    ++_callGeneration;
    _wantCall = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _mediaJoined = false;
    joiningCall = false;
    mediaConnection = MediaConnectionState.idle;
    _setLocalSpeaking(false);
    _speaking.clear();
    muted = false;
    speakerphone = true;
    micRouter.resetOutputPreference();
    try {
      await Future.wait([mediaEngine.leave(), callService.stop()]);
    } catch (error) {
      _setError(errorMessage(error));
    }
    _notify();
  }

  void setMuted(bool value) {
    muted = value;
    if (value) _localSpeaking = false;
    mediaEngine.setMuted(value);
    unawaited(
      callService.setMuted(value).catchError((Object error) {
        mediaError = exceptionMessage(error, '음소거 알림을 갱신하지 못했습니다.');
        _notify();
      }),
    );
    _notify();
  }

  Future<void> cycleOutputRoute() async {
    await micRouter.cycleOutputRoute();
    speakerphone = outputRoute == OutputRoute.speaker;
    _notify();
  }

  Future<void> setCallVolume(int value) {
    callVolume = value.clamp(0, 100);
    _notify();
    final volume = callVolume;
    final operation = _volumeQueue.then((_) async {
      if (_disposed) return;
      _settingVolume = true;
      try {
        await mediaEngine.setVolume(volume / 100);
        if (carVolumeSlider && micRouter.isAutomotive) {
          await micRouter.setSystemCallVolume(volume);
        }
        _lastSystemVolume = micRouter.systemCallVolume;
        await store.setCallVolume(volume);
      } finally {
        _settingVolume = false;
      }
    });
    _volumeQueue = operation.catchError((Object _) {});
    return operation;
  }

  // Compare values: each native meter event rebuilds MicDevice/List objects.
  // Only MicLevel listens to level/rms/dbfs; they must not rebuild the room.
  List<Object?> _audioState() {
    final state = micRouter.state;
    final selected = state.selected;
    return [
      state.mode,
      (selected?.id, selected?.type, selected?.name, selected?.webrtcDeviceId),
      state.manualId,
      state.isRecording,
      state.isPreviewing,
      state.isCallActive,
      state.error,
      micRouter.permissions.microphone,
      micRouter.permissions.notifications,
      micRouter.audioInterrupted,
      micRouter.resumeFailed,
      micRouter.outputRoute,
      micRouter.outputError,
      micRouter.systemCallVolume,
      micRouter.systemVolumeWritable,
      ...micRouter.availableOutputRoutes,
      for (final device in state.devices)
        (device.id, device.type, device.name, device.webrtcDeviceId),
    ];
  }

  void _audioChanged() {
    final next = _audioState();
    if (listEquals(_lastAudioState, next)) return;
    _lastAudioState = next;
    speakerphone = outputRoute == OutputRoute.speaker;
    if (_interrupted != micRouter.audioInterrupted) {
      _interrupted = micRouter.audioInterrupted;
      if (_interrupted) _setLocalSpeaking(false);
      mediaEngine.setInterrupted(_interrupted);
    }
    if (_wantCall &&
        micRouter.resumeFailed &&
        mediaConnection != MediaConnectionState.failed) {
      mediaConnection = MediaConnectionState.failed;
      mediaError = micRouter.outputError ?? '통화 오디오를 재개하지 못했습니다.';
      _scheduleRetry();
    }
    final volume = micRouter.systemCallVolume;
    if (carVolumeSlider &&
        micRouter.isAutomotive &&
        micRouter.systemVolumeWritable &&
        !_settingVolume &&
        volume != null &&
        volume != _lastSystemVolume) {
      _lastSystemVolume = volume;
      callVolume = volume;
      unawaited(store.setCallVolume(volume));
      unawaited(
        mediaEngine.setVolume(volume / 100).catchError((Object error) {
          mediaError = exceptionMessage(error, '통화 음량을 변경하지 못했습니다.');
          _notify();
        }),
      );
    }
    _notify();
  }

  void _nativeCallChanged() {
    if (!call.isActive) _setLocalSpeaking(false);
    if (!call.isActive && !call.isStarting && _mediaJoined && _wantCall) {
      _mediaJoined = false;
      _speaking.clear();
      unawaited(
        mediaEngine.leave().catchError((Object _) {}).whenComplete(() {
          if (_disposed || !_wantCall) return;
          mediaConnection = MediaConnectionState.failed;
          mediaError = call.error ?? '통화 오디오가 중단되었습니다. 다시 연결해 주세요.';
          _scheduleRetry();
          _notify();
        }),
      );
    }
    _notify();
  }

  Future<void> leave() async {
    final code = state.code;
    if (code == null || state.isLeaving) return;
    final stoppingCall = leaveCall();
    state = state.copyWith(isConnected: false, isLeaving: true);
    _cancelStarts();
    _setLocalSpeaking(false);
    _wantCall = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    ++_generation;
    _notify();
    try {
      await stoppingCall;
      await locationShare.stop();
      await _subscription?.cancel();
      _subscription = null;
      await api.leaveRoom(code);
      if (!_disposed && state.code == code) state = const RoomState();
    } catch (error) {
      _setError(exceptionMessage(error, '방 나가기를 다시 시도해 주세요.'));
      rethrow;
    } finally {
      if (state.code == code) state = state.copyWith(isLeaving: false);
      _notify();
    }
  }

  Future<void> forget() async {
    ++_generation;
    _restorableRoom = null;
    final stoppingCall = leaveCall();
    state = state.copyWith(isConnected: false, isLeaving: true);
    _cancelStarts();
    _notify();
    await stoppingCall;
    await locationShare.stop();
    await _subscription?.cancel();
    _subscription = null;
    state = const RoomState();
    _notify();
  }

  bool _isAccessError(Object error) =>
      error is ApiException && {401, 403, 404}.contains(error.status);

  Future<void> _forgetInaccessibleRoom(ApiException error) async {
    final token = store.token;
    await forget();
    if (error.status == 401 && token == store.token) await store.clear();
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  void _setError(String message) {
    if (!_disposed) {
      state = state.copyWith(error: message);
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_profileChanged);
    locationShare.removeListener(_locationChanged);
    locationShare.dispose();
    ++_generation;
    ++_callGeneration;
    unawaited(_subscription?.cancel());
    callService.removeListener(_nativeCallChanged);
    callService.onLeaveCall = null;
    callService.onToggleMute = null;
    micRouter.removeListener(_audioChanged);
    _retryTimer?.cancel();
    _localSpeaking = false;
    mediaEngine.localSpeaking = null;
    mediaEngine.remoteSpeaking = null;
    mediaEngine.sendSignal = null;
    mediaEngine.connectionChanged = null;
    unawaited(_peerSubscription.cancel());
    unawaited(mediaEngine.dispose().catchError((Object _) {}));
    super.dispose();
  }
}
