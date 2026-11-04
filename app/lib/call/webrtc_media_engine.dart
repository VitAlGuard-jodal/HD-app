import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../audio/mic_router.dart';
import '../core/errors.dart';
import '../net/api_client.dart';
import '../net/models.dart';
import 'media_engine.dart';
import 'mesh_coordinator.dart';
import 'sdp_munge.dart';

const remoteSpeakingThreshold = 0.02;
const remoteSpeakingInterval = Duration(milliseconds: 500);
const _icePolicy = String.fromEnvironment('UNAVO_ICE_POLICY');

class WebRtcMediaEngine extends MediaEngine {
  WebRtcMediaEngine({required this.api, required this.micRouter});

  final ApiClient api;
  final MicRouter micRouter;
  List<String> _members = [];
  List<JsonMap> _iceServers = [];
  MediaStream? _local;
  MeshCoordinator? _mesh;
  final Map<String, _WebRtcPeer> _peers = {};
  final Map<String, MeshPeerState> _states = {};
  final Set<String> _speaking = {};
  Future<void> _lifecycle = Future<void>.value();
  Future<void>? _starting;
  Future<void> _inputQueue = Future<void>.value();
  Timer? _statsTimer;
  Timer? _credentialTimer;
  DateTime? _credentialsExpireAt;
  bool _muted = false;
  bool _interrupted = false;
  bool _localSpeaking = false;
  double _playbackVolume = 1;
  Future<void> _volumeWrites = Future<void>.value();
  bool _pollingStats = false;
  bool _listeningToMic = false;
  bool _signalingFailed = false;
  MediaConnectionState _localConnection = MediaConnectionState.idle;
  String? _localError;
  bool _acceptingSignals = false;
  String? _selectedInput;
  int _generation = 0;

  @override
  Future<void> setMembers(List<String> handles) async {
    _members = List.of(handles);
    await _mesh?.updateMembers(_members);
    _publishState();
  }

  @override
  Future<void> join(String roomCode, String selfHandle) {
    final generation = ++_generation;
    _acceptingSignals = true;
    _stopTimers();
    final starting = _schedule(() async {
      await _release();
      if (!_current(generation)) return;
      try {
        _setLocalConnection(MediaConnectionState.connecting);
        if (!MeshCoordinator.canJoin(selfHandle, _members)) {
          throw StateError(meshCapacityReason);
        }
        // The native call service owns focus/session; WebRTC owns capture.
        await micRouter.stopPreview();
        final requestedAt = DateTime.now();
        final credentials = await api.fetchIceServers();
        if (!_current(generation)) return;
        _iceServers = credentials.iceServers;
        if (defaultTargetPlatform == TargetPlatform.android) {
          await Helper.setAndroidAudioConfiguration(
            AndroidAudioConfiguration(
              manageAudioFocus: false,
              androidAudioMode: AndroidAudioMode.inCommunication,
              androidAudioStreamType: AndroidAudioStreamType.voiceCall,
              androidAudioAttributesUsageType:
                  AndroidAudioAttributesUsageType.voiceCommunication,
              androidAudioAttributesContentType:
                  AndroidAudioAttributesContentType.speech,
            ),
          );
        }
        if (!_current(generation)) return;
        _local = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': false,
        });
        if (!_current(generation)) return;
        setMuted(_muted);
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          await Helper.setAppleAudioConfiguration(
            AppleAudioConfiguration(
              appleAudioCategory: AppleAudioCategory.playAndRecord,
              appleAudioMode: AppleAudioMode.voiceChat,
              appleAudioCategoryOptions: {
                AppleAudioCategoryOption.allowBluetooth,
                AppleAudioCategoryOption.defaultToSpeaker,
              },
            ),
          );
        }
        await _selectInput(generation);
        if (!_current(generation)) return;
        final mesh = MeshCoordinator(
          selfHandle: selfHandle,
          sessionId:
              '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
          createPeer: (handle, candidate, state) =>
              _createPeer(handle, candidate, state, generation),
          sendSignal: (to, kind, payload) async {
            // Capture this room: delayed leave/ICE cannot target another room.
            await api.sendSignal(roomCode, to, kind, payload);
          },
          onPeerState: (handle, state) {
            if (!_current(generation)) return;
            if (state == MeshPeerState.closed) {
              _states.remove(handle);
              _setSpeaking(handle, false);
            } else {
              _states[handle] = state;
              if (state != MeshPeerState.connected) _setSpeaking(handle, false);
            }
            _publishState();
          },
        );
        _mesh = mesh;
        _localConnection = MediaConnectionState.connected;
        await mesh.join(_members);
        if (!_current(generation)) return;
        micRouter.addListener(_micChanged);
        _listeningToMic = true;
        _statsTimer = Timer.periodic(remoteSpeakingInterval, (_) {
          unawaited(_pollStats(generation));
        });
        _scheduleCredentials(credentials, requestedAt, generation);
        _publishState();
      } catch (error) {
        await _release();
        if (_current(generation)) {
          _acceptingSignals = false;
          _setLocalConnection(
            MediaConnectionState.failed,
            exceptionMessage(error, '음성 연결을 시작하지 못했습니다.'),
          );
          rethrow;
        }
      }
    });
    _starting = starting;
    return starting;
  }

  Future<_WebRtcPeer> _createPeer(
    String handle,
    void Function(Map<String, Object?>) candidate,
    void Function(MeshPeerState) state,
    int generation,
  ) async {
    final pc = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
      if (_icePolicy == 'relay') 'iceTransportPolicy': 'relay',
    });
    late final _WebRtcPeer peer;
    peer = _WebRtcPeer(pc, () {
      if (identical(_peers[handle], peer)) _peers.remove(handle);
      if (_peers.isEmpty) _setLocalSpeaking(false);
    });
    try {
      if (!_current(generation) || _local == null) {
        throw StateError('종료된 통화입니다.');
      }
      _peers[handle] = peer;
      pc.onIceCandidate = (ice) {
        if (ice.candidate?.isNotEmpty == true) {
          candidate(Map<String, Object?>.from(ice.toMap() as Map));
        }
      };
      pc.onConnectionState = (value) => state(switch (value) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
          MeshPeerState.connected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
          MeshPeerState.failed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
          MeshPeerState.closed,
        _ => MeshPeerState.connecting,
      });
      // Native Android/iOS receivers play audio without a video renderer.
      pc.onTrack = (event) {
        if (event.track.kind == 'audio') {
          event.track.enabled = true;
          peer.audioTracks.add(event.track);
          unawaited(
            setVolume(_playbackVolume).catchError((Object error) {
              if (_current(generation)) {
                _setLocalConnection(
                  MediaConnectionState.failed,
                  exceptionMessage(error, '통화 음량을 적용하지 못했습니다.'),
                );
              }
            }),
          );
        }
      };
      for (final track in _local!.getAudioTracks()) {
        await pc.addTrack(track, _local!);
      }
      return peer;
    } catch (_) {
      await peer.close();
      rethrow;
    }
  }

  @override
  Future<void> onSignal(String from, String kind, Object? payload) async {
    if (!_acceptingSignals) {
      if (kind == 'offer' &&
          payload is Map &&
          payload['negotiationId'] is String) {
        await sendSignal?.call(from, 'custom', {
          'type': 'mesh-left',
          'negotiationId': payload['negotiationId'],
        });
      }
      return;
    }
    final generation = _generation;
    await _starting;
    if (_current(generation)) await _mesh?.onSignal(from, kind, payload);
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
    if (_muted || _interrupted) _setLocalSpeaking(false);
    for (final track in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted && !_interrupted;
    }
  }

  @override
  void setInterrupted(bool interrupted) {
    _interrupted = interrupted;
    // Resume the same tracks after native AVAudioSession interruption ended.
    setMuted(_muted);
  }

  @override
  Future<void> setVolume(double volume) {
    // Both native RTCAudioSource.volume and org.webrtc.AudioTrack.setVolume
    // accept gain 0..10. 100% is unity (1); the phone slider allows up to
    // 200% (+6 dB) because the iPhone call-mode speaker is quiet.
    _playbackVolume = volume.clamp(0, 2);
    final operation = _volumeWrites.then((_) async {
      for (final peer in _peers.values.toList()) {
        for (final track in peer.audioTracks.toList()) {
          if (!peer.closed) await Helper.setVolume(_playbackVolume, track);
        }
      }
    });
    _volumeWrites = operation.catchError((Object _) {});
    return operation;
  }

  @override
  void onRemoteSpeaking(String handle) {} // No capture/renegotiation side effect.

  void _micChanged() {
    final generation = _generation;
    _inputQueue = _inputQueue
        .then((_) async {
          if (_current(generation) && _mesh != null)
            await _selectInput(generation);
        })
        .catchError((Object error) {
          if (_current(generation) && _mesh != null) {
            _setLocalConnection(
              MediaConnectionState.failed,
              exceptionMessage(error, '통화 마이크를 변경하지 못했습니다.'),
            );
          }
        });
  }

  Future<void> _selectInput(int generation) async {
    final id = micRouter.state.selected?.webrtcDeviceId;
    if (id == null || id == _selectedInput || !_current(generation)) return;
    final devices = await navigator.mediaDevices.enumerateDevices();
    if (!_current(generation)) return;
    if (!devices.any(
      (device) => device.kind == 'audioinput' && device.deviceId == id,
    )) {
      throw StateError('선택한 마이크가 연결되어 있지 않습니다. 마이크를 다시 선택해 주세요.');
    }
    await Helper.selectAudioInput(id);
    if (_current(generation)) _selectedInput = id;
  }

  void _scheduleCredentials(
    IceServerCredentials credentials,
    DateTime requestedAt,
    int generation,
  ) {
    _credentialTimer?.cancel();
    _credentialsExpireAt = requestedAt.add(
      Duration(seconds: credentials.ttlSeconds),
    );
    final elapsed = DateTime.now().difference(requestedAt).inMilliseconds;
    final delay = max(100, (credentials.ttlSeconds * 800) - elapsed);
    _credentialTimer = Timer(Duration(milliseconds: delay), () {
      unawaited(_refreshCredentials(generation));
    });
  }

  Future<void> _refreshCredentials(int generation) async {
    if (!_current(generation) || _mesh == null) return;
    try {
      final requestedAt = DateTime.now();
      final credentials = await api.fetchIceServers();
      if (!_current(generation) || _mesh == null) return;
      _iceServers = credentials.iceServers;
      for (final peer in _peers.values.toList()) {
        if (!_current(generation)) return;
        if (!peer.closed) {
          await peer.pc.setConfiguration({
            ...peer.pc.getConfiguration,
            'iceServers': _iceServers,
          });
        }
      }
      await _mesh?.restartIce();
      if (!_current(generation)) return;
      if (_signalingFailed) {
        _localConnection = MediaConnectionState.connected;
        _localError = null;
      }
      _signalingFailed = false;
      _scheduleCredentials(credentials, requestedAt, generation);
      _publishState();
    } catch (_) {
      if (!_current(generation) || _mesh == null) return;
      _signalingFailed = true;
      _setLocalConnection(
        MediaConnectionState.failed,
        '통화 연결 정보를 갱신하지 못해 다시 시도합니다.',
      );
      final remaining =
          _credentialsExpireAt?.difference(DateTime.now()).inMilliseconds ?? 0;
      final retry = remaining > 0 ? (remaining ~/ 2).clamp(250, 5000) : 5000;
      _credentialTimer = Timer(Duration(milliseconds: retry), () {
        unawaited(_refreshCredentials(generation));
      });
    }
  }

  Future<void> _pollStats(int generation) async {
    if (_pollingStats || !_current(generation)) return;
    _pollingStats = true;
    try {
      final localLevels = <_WebRtcPeer, double>{};
      for (final entry in _peers.entries.toList()) {
        var level = 0.0;
        var localLevel = 0.0;
        try {
          for (final report in await entry.value.pc.getStats()) {
            final values = report.values;
            final audio = (values['kind'] ?? values['mediaType']) == 'audio';
            final remote =
                report.type == 'inbound-rtp' ||
                (report.type == 'track' && values['remoteSource'] == true);
            if (audio && (remote || report.type == 'media-source')) {
              final value = values['audioLevel'];
              final audioLevel = value is num
                  ? value.toDouble()
                  : double.tryParse(value?.toString() ?? '') ?? 0.0;
              if (remote) {
                level = max(level, audioLevel);
              } else {
                localLevel = max(localLevel, audioLevel);
              }
            }
          }
        } catch (_) {
          // A peer can close while a stats request is outstanding.
        }
        if (!_current(generation)) return;
        if (identical(_peers[entry.key], entry.value) && !entry.value.closed) {
          localLevels[entry.value] = localLevel;
          _setSpeaking(
            entry.key,
            _states[entry.key] == MeshPeerState.connected &&
                level > remoteSpeakingThreshold,
          );
        }
      }
      if (!_current(generation)) return;
      // All peers send the same source; discard peers closed during this poll.
      var localLevel = 0.0;
      for (final peer in _peers.values) {
        if (!peer.closed) localLevel = max(localLevel, localLevels[peer] ?? 0);
      }
      _setLocalSpeaking(
        !_muted && !_interrupted && localLevel > remoteSpeakingThreshold,
      );
    } finally {
      _pollingStats = false;
    }
  }

  void _setSpeaking(String handle, bool speaking) {
    final changed = speaking ? _speaking.add(handle) : _speaking.remove(handle);
    if (changed) remoteSpeaking?.call(handle, speaking);
  }

  void _setLocalSpeaking(bool speaking) {
    if (_localSpeaking == speaking) return;
    _localSpeaking = speaking;
    localSpeaking?.call(speaking);
  }

  void _publishState() {
    publishPeerStates(_states);
    final state = receiveConnectionState(_localConnection, _states.values);
    connectionChanged?.call(state, _localError);
  }

  void _setLocalConnection(MediaConnectionState state, [String? message]) {
    _localConnection = state;
    _localError = message;
    _publishState();
  }

  bool _current(int generation) => generation == _generation;

  @override
  Future<void> leave() {
    ++_generation;
    _acceptingSignals = false;
    _stopTimers();
    for (final track in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = false;
    }
    // Invalidate peer retry timers now, even if native track teardown is slow.
    // _release awaits the same idempotent close Future and handles its error.
    unawaited(_mesh?.close().catchError((Object _) {}));
    _starting = null;
    _states.clear();
    _setLocalConnection(MediaConnectionState.idle);
    return _schedule(_release);
  }

  void _stopTimers() {
    _setLocalSpeaking(false);
    _statsTimer?.cancel();
    _statsTimer = null;
    _credentialTimer?.cancel();
    _credentialTimer = null;
    if (_listeningToMic) micRouter.removeListener(_micChanged);
    _listeningToMic = false;
  }

  Future<void> _release() async {
    _stopTimers();
    final local = _local;
    _local = null;
    final mesh = _mesh;
    _mesh = null;
    try {
      if (local != null) {
        try {
          for (final track in local.getTracks()) {
            await track.stop();
          }
        } finally {
          await local.dispose();
        }
      }
    } finally {
      try {
        await mesh?.close();
      } finally {
        try {
          await Future.wait(_peers.values.toList().map((peer) => peer.close()));
        } finally {
          _peers.clear();
          _states.clear();
          publishPeerStates(_states);
          for (final handle in _speaking.toList()) {
            _setSpeaking(handle, false);
          }
          _selectedInput = null;
          _signalingFailed = false;
        }
      }
    }
  }

  Future<void> _schedule(Future<void> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    _lifecycle = result.catchError((Object _) {});
    return result;
  }
}

class _WebRtcPeer implements MeshPeer {
  _WebRtcPeer(this.pc, this.onClosed);
  final RTCPeerConnection pc;
  final void Function() onClosed;
  bool closed = false;
  final Set<MediaStreamTrack> audioTracks = {};

  @override
  Future<Map<String, Object?>> createOffer({bool iceRestart = false}) async {
    final offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
      if (iceRestart) 'iceRestart': true,
    });
    offer.sdp = stripTransportCc(offer.sdp!);
    await pc.setLocalDescription(offer);
    return Map<String, Object?>.from(offer.toMap() as Map);
  }

  @override
  Future<Map<String, Object?>> answerOffer(Map<String, Object?> offer) async {
    await pc.setRemoteDescription(
      RTCSessionDescription(stripTransportCc(offer['sdp'] as String), 'offer'),
    );
    final answer = await pc.createAnswer();
    answer.sdp = stripTransportCc(answer.sdp!);
    await pc.setLocalDescription(answer);
    return Map<String, Object?>.from(answer.toMap() as Map);
  }

  @override
  Future<void> acceptAnswer(Map<String, Object?> answer) =>
      pc.setRemoteDescription(
        RTCSessionDescription(
          stripTransportCc(answer['sdp'] as String),
          'answer',
        ),
      );

  @override
  Future<void> addCandidate(Map<String, Object?> candidate) => pc.addCandidate(
    RTCIceCandidate(
      candidate['candidate'] as String,
      candidate['sdpMid'] as String?,
      (candidate['sdpMLineIndex'] as num?)?.toInt(),
    ),
  );

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    audioTracks.clear();
    pc.onIceCandidate = null;
    pc.onConnectionState = null;
    pc.onTrack = null;
    try {
      await pc.close();
    } finally {
      try {
        await pc.dispose();
      } finally {
        onClosed();
      }
    }
  }
}
