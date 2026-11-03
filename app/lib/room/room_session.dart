import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/mic_router.dart';
import '../auth/session_store.dart';
import '../call/call_service.dart';
import '../call/call_state.dart';
import '../call/media_engine.dart';
import '../call/mesh_coordinator.dart';
import '../core/errors.dart';
import '../net/api_client.dart';
import '../net/models.dart';

const joinedRoomReason = '이미 참여 중인 방이 있음 — 나간 뒤 만들 수 있음';
const _unchanged = Object();

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
  }) {
    callService.onLeaveCall = leaveCall;
    callService.addListener(_nativeCallChanged);
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
      _notify();
    };
  }
  final ApiClient api;
  final MediaEngine mediaEngine;
  final SessionStore store;
  final CallService callService;
  final MicRouter micRouter;
  RoomState state = const RoomState();
  CallState get call => callService.state;
  bool muted = false;
  bool speakerphone = false;
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
  final Set<String> _speaking = {};
  Set<String> get speaking => Set.unmodifiable(_speaking);
  StreamSubscription<RoomEvent>? _subscription;
  Future<void> _eventQueue = Future<void>.value();
  Future<void>? _stopFuture;
  int _generation = 0;
  int _callGeneration = 0;

  Future<void> open(String code, {bool force = false}) async {
    if (state.isLeaving) return;
    if (!force && state.code == code && _subscription != null) return;
    if (state.code != null && state.code != code)
      throw StateError(joinedRoomReason);
    final generation = ++_generation;
    await _subscription?.cancel();
    _subscription = null;
    if (!_current(generation)) return;
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
                  if (_current(generation))
                    await _onEvent(code, event, generation);
                })
                .catchError((Object error) {
                  if (_current(generation))
                    _setError(exceptionMessage(error, '방 연결을 확인해 주세요.'));
                });
          },
          onError: (Object error) {
            if (!_current(generation)) return;
            ++_generation;
            _subscription = null;
            state = state.copyWith(
              isConnected: false,
              error: exceptionMessage(error, '방 연결을 확인해 주세요.'),
            );
            _notify();
            if (error is ApiException && error.status == 401)
              unawaited(_expireSession());
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
        } catch (error) {
          if (_current(generation))
            _setError(exceptionMessage(error, '방에 다시 참여하지 못했습니다.'));
        }
      case Hello():
        await _setMembers(event.members);
        if (!_current(generation)) return;
        if (call.isActive &&
            !joiningCall &&
            call.roomCode == code &&
            call.selfHandle == event.self) {
          await _startMedia(code, event.self);
        }
      case MemberJoined():
        await _refresh(code, generation);
      case MemberLeft():
        // Close immediately, even if the subsequent HTTP refresh fails.
        await _setMembers(
          state.members.where((m) => m.handle != event.handle).toList(),
        );
        await _refresh(code, generation);
    }
    if (!_current(generation)) return;
    if (event is! Disconnected) state = state.copyWith(isConnected: true);
    _notify();
  }

  Future<void> _refresh(String code, int generation) async {
    try {
      final details = await api.getRoom(code);
      if (_current(generation) && state.code == code) {
        state = state.copyWith(room: details.room, error: null);
        await _setMembers(details.members);
        _notify();
      }
    } catch (error) {
      if (_current(generation))
        _setError(exceptionMessage(error, '참여자를 불러오지 못했습니다.'));
    }
  }

  Future<void> _setMembers(List<Member> members) async {
    state = state.copyWith(members: members);
    _speaking.removeWhere((handle) => !members.any((m) => m.handle == handle));
    await mediaEngine.setMembers(members.map((m) => m.handle).toList());
    if (_mediaJoined &&
        !MeshCoordinator.canJoin(
          store.handle ?? '',
          members.map((m) => m.handle),
        )) {
      await leaveCall();
      mediaError = meshCapacityReason;
    }
  }

  Future<void> _startMedia(String code, String handle) async {
    _mediaJoined = true;
    mediaEngine.setMuted(muted);
    try {
      await mediaEngine.join(code, handle);
      if (!_mediaJoined || !call.isActive) return;
      // Reapply the existing native output choice after WebRTC configures audio.
      speakerphone = await micRouter.setSpeakerphone(speakerphone);
    } catch (error) {
      await leaveCall();
      mediaConnection = MediaConnectionState.failed;
      mediaError = exceptionMessage(error, '음성 연결을 시작하지 못했습니다.');
      rethrow;
    }
  }

  Future<void> joinCall() async {
    final code = state.code;
    final handle = store.handle;
    if (code == null ||
        handle == null ||
        joiningCall ||
        call.isStopping ||
        _stopFuture != null)
      return;
    if (call.isActive && call.roomCode == code) return;
    final blocked = callJoinBlockedReason;
    if (blocked != null) throw StateError(blocked);
    if (call.roomCode != null && call.roomCode != code)
      throw StateError('현재 통화에서 나간 뒤 다른 방에 참여해 주세요.');
    final generation = ++_callGeneration;
    joiningCall = true;
    _notify();
    try {
      // Recheck capacity against server order just before allocating audio.
      final details = await api.getRoom(code);
      if (_disposed || generation != _callGeneration) return;
      await _setMembers(details.members);
      final blocked = callJoinBlockedReason;
      if (blocked != null) throw StateError(blocked);
      await micRouter.refreshPermissions();
      if (!micRouter.permissions.microphone)
        await micRouter.requestPermissions();
      if (!micRouter.permissions.microphone)
        throw StateError('마이크 권한을 먼저 허용해 주세요.');
      if (_disposed || generation != _callGeneration) return;
      await micRouter.stopPreview();
      if (_disposed || generation != _callGeneration) return;
      await callService.start(code, handle);
      if (_disposed || generation != _callGeneration || state.code != code) {
        await callService.stop();
        return;
      }
      if (call.isActive) {
        await _startMedia(code, handle);
      }
    } catch (error) {
      _setError(errorMessage(error));
      rethrow;
    } finally {
      joiningCall = false;
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
    _mediaJoined = false;
    _speaking.clear();
    muted = false;
    speakerphone = false;
    try {
      try {
        await mediaEngine.leave();
      } finally {
        await callService.stop();
      }
    } catch (error) {
      _setError(errorMessage(error));
    }
    _notify();
  }

  void setMuted(bool value) {
    muted = value;
    mediaEngine.setMuted(value);
    _notify();
  }

  Future<void> setSpeakerphone(bool value) async {
    speakerphone = await micRouter.setSpeakerphone(value);
    _notify();
  }

  // 알림의 끊기와 네이티브 오디오 포커스 상실 모두 미디어를 정리한다.
  void _nativeCallChanged() {
    if (!call.isActive && !call.isStarting) {
      if (_mediaJoined) {
        unawaited(
          mediaEngine.leave().catchError((Object error) {
            _setError(errorMessage(error));
          }),
        );
        _mediaJoined = false;
      }
      _speaking.clear();
      muted = false;
      speakerphone = false;
    }
    _notify();
  }

  Future<void> leave() async {
    final code = state.code;
    if (code == null || state.isLeaving) return;
    state = state.copyWith(isConnected: false, isLeaving: true);
    ++_generation;
    _notify();
    try {
      await _subscription?.cancel();
      _subscription = null;
      await leaveCall();
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
    await _subscription?.cancel();
    _subscription = null;
    await leaveCall();
    state = const RoomState();
    _notify();
  }

  Future<void> _expireSession() async {
    await forget();
    await store.clear();
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
    ++_generation;
    ++_callGeneration;
    unawaited(_subscription?.cancel());
    callService.removeListener(_nativeCallChanged);
    callService.onLeaveCall = null;
    mediaEngine.remoteSpeaking = null;
    mediaEngine.sendSignal = null;
    mediaEngine.connectionChanged = null;
    unawaited(mediaEngine.leave().catchError((Object _) {}));
    super.dispose();
  }
}
