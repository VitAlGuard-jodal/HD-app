import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../auth/session_store.dart';
import 'mic_ranker.dart';

class AudioPermissions {
  const AudioPermissions({this.microphone = false, this.notifications = false});
  factory AudioPermissions.fromMap(Map<Object?, Object?> map) =>
      AudioPermissions(
        microphone: map['microphone'] as bool? ?? false,
        notifications: map['notifications'] as bool? ?? false,
      );
  final bool microphone;
  final bool notifications;
}

class MicState {
  const MicState({
    this.mode = MicMode.phone,
    this.devices = const [],
    this.selected,
    this.manualId,
    this.level = 0,
    this.rms = 0,
    this.dbfs = double.negativeInfinity,
    this.isRecording = false,
    this.isPreviewing = false,
    this.error,
  });
  factory MicState.fromMap(Map<Object?, Object?> map) {
    final selected = map['selected'];
    return MicState(
      mode: map['mode'] == 'car' ? MicMode.car : MicMode.phone,
      devices: (map['devices'] as List<dynamic>? ?? [])
          .map((v) => MicDevice.fromMap(Map<Object?, Object?>.from(v as Map)))
          .toList(),
      selected: selected is Map
          ? MicDevice.fromMap(Map<Object?, Object?>.from(selected))
          : null,
      manualId: map['manualId'] as int?,
      level: (map['level'] as num?)?.toDouble() ?? 0,
      rms: (map['rms'] as num?)?.toInt() ?? 0,
      dbfs: (map['dbfs'] as num?)?.toDouble() ?? double.negativeInfinity,
      isRecording: map['isRecording'] as bool? ?? false,
      isPreviewing: map['isPreviewing'] as bool? ?? false,
      error: map['error'] as String?,
    );
  }
  final MicMode mode;
  final List<MicDevice> devices;
  final MicDevice? selected;
  final int? manualId;
  final double level;
  final int rms;
  final double dbfs;
  final bool isRecording;
  final bool isPreviewing;
  final String? error;
}

class MicRouter extends ChangeNotifier {
  MicRouter(this.store);
  final SessionStore store;
  static const channel = MethodChannel('unavo/audio');
  static const events = EventChannel('unavo/audio/levels');
  StreamSubscription<dynamic>? _subscription;
  MicState state = const MicState();
  AudioPermissions permissions = const AudioPermissions();
  bool get supported => Platform.isAndroid;

  Future<void> initialize() async {
    if (!supported) return;
    final snapshot = await channel.invokeMapMethod<Object?, Object?>(
      'getState',
    );
    if (snapshot != null) state = MicState.fromMap(snapshot);
    await choose(store.manualMicId);
    await refreshPermissions();
    _subscription = events.receiveBroadcastStream().listen(
      (dynamic event) {
        final previousId = state.manualId;
        state = MicState.fromMap(Map<Object?, Object?>.from(event as Map));
        if (previousId != state.manualId)
          unawaited(store.setManualMicId(state.manualId));
        notifyListeners();
      },
      onError: (Object error) {
        state = MicState(
          error: error is PlatformException ? error.message : error.toString(),
        );
        notifyListeners();
      },
    );
  }

  Future<void> refreshPermissions() async {
    if (!supported) return;
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'permissions',
    );
    if (result != null) permissions = AudioPermissions.fromMap(result);
    notifyListeners();
  }

  Future<AudioPermissions> requestPermissions() async {
    _requirePlatform();
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'requestPermissions',
    );
    if (result != null) permissions = AudioPermissions.fromMap(result);
    notifyListeners();
    return permissions;
  }

  Future<void> openSettings() async {
    _requirePlatform();
    await channel.invokeMethod<void>('openSettings');
  }

  Future<void> choose(int? id) async {
    _requirePlatform();
    final value = await channel.invokeMapMethod<Object?, Object?>('choose', {
      'id': id,
    });
    if (value != null) state = MicState.fromMap(value);
    await store.setManualMicId(state.manualId);
    notifyListeners();
  }

  Future<void> startPreview() async {
    _requirePlatform();
    await channel.invokeMethod<void>('startPreview');
  }

  Future<void> stopPreview() async {
    if (supported) await channel.invokeMethod<void>('stopPreview');
  }

  Future<bool> setSpeakerphone(bool enabled) async {
    _requirePlatform();
    return await channel.invokeMethod<bool>('setSpeakerphone', {
          'enabled': enabled,
        }) ??
        false;
  }

  void _requirePlatform() {
    if (!supported)
      throw PlatformException(
        code: 'unavailable',
        message: '이 기기의 오디오 연결은 아직 지원하지 않습니다.',
      );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
