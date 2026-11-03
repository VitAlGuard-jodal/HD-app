import 'dart:async';

import 'package:flutter/foundation.dart';

import 'mesh_coordinator.dart';

enum MediaConnectionState { idle, connecting, connected, failed }

/// The chip describes local receive readiness. A usable peer wins over pending
/// peers; terminal peer failures stay on their cards. With no viable peers left,
/// the live local stream is ready for the next arrival, just as when alone.
MediaConnectionState receiveConnectionState(
  MediaConnectionState local,
  Iterable<MeshPeerState> peers,
) {
  if (local != MediaConnectionState.connected) return local;
  if (peers.contains(MeshPeerState.connected)) return local;
  return peers.contains(MeshPeerState.connecting)
      ? MediaConnectionState.connecting
      : local;
}

abstract class MediaEngine {
  final _peerStateEvents =
      StreamController<Map<String, MeshPeerState>>.broadcast();
  Map<String, MeshPeerState> _peerStates = const {};
  Map<String, MeshPeerState> get peerStates => _peerStates;
  Stream<Map<String, MeshPeerState>> get peerStateChanges =>
      _peerStateEvents.stream;

  @protected
  void publishPeerStates(Map<String, MeshPeerState> states) {
    _peerStates = Map.unmodifiable(states);
    if (!_peerStateEvents.isClosed) _peerStateEvents.add(_peerStates);
  }

  Future<void> dispose() async {
    try {
      await leave();
    } finally {
      await _peerStateEvents.close();
    }
  }

  Future<void> join(String roomCode, String selfHandle);
  Future<void> leave();
  Future<void> setMembers(List<String> handles);
  void setMuted(bool muted);

  /// Playback gain: 0 is silent, 1 is the original remote audio level.
  Future<void> setVolume(double volume) async {}
  void setInterrupted(bool interrupted) {}
  Future<void> onSignal(String from, String kind, Object? payload);
  void onRemoteSpeaking(String handle);

  // F3 엔진은 수신 발화와 로컬 시그널을 이 콜백으로 전달한다.
  void Function(String handle, bool speaking)? remoteSpeaking;
  Future<void> Function(String to, String kind, Object? payload)? sendSignal;
  void Function(MediaConnectionState state, String? message)? connectionChanged;
}

class NoopMediaEngine extends MediaEngine {
  @override
  Future<void> join(String roomCode, String selfHandle) async =>
      debugPrint('HDMEDIA join room=$roomCode self=$selfHandle (미디어 엔진 미연결)');
  @override
  Future<void> leave() async => debugPrint('HDMEDIA leave');
  @override
  Future<void> setMembers(List<String> handles) async {}
  @override
  void setMuted(bool muted) => debugPrint('HDMEDIA muted=$muted');
  @override
  Future<void> onSignal(String from, String kind, Object? payload) async =>
      debugPrint('HDMEDIA signal from=$from kind=$kind');
  @override
  void onRemoteSpeaking(String handle) =>
      debugPrint('HDMEDIA speaking=$handle');
}
