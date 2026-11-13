import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../auth/session_store.dart';
import 'mic_ranker.dart';

enum OutputRoute { speaker, receiver, bluetooth, headphones, carAudio }

extension OutputRouteLabel on OutputRoute {
  String get label => switch (this) {
    OutputRoute.speaker => '스피커',
    OutputRoute.receiver => '수화부',
    OutputRoute.bluetooth => '블루투스',
    OutputRoute.headphones => '이어폰',
    OutputRoute.carAudio => '차량 오디오',
  };
  String get icon => switch (this) {
    OutputRoute.speaker => 'speaker',
    OutputRoute.receiver => 'earpiece',
    OutputRoute.bluetooth => 'bluetooth',
    OutputRoute.headphones => 'headset',
    OutputRoute.carAudio => 'carplay',
  };
}

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
    this.isCallActive = false,
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
      isCallActive: map['isCallActive'] as bool? ?? false,
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
  final bool isCallActive;
  final String? error;
}

class MicRouter extends ChangeNotifier {
  MicRouter(this.store);
  final SessionStore store;
  static const channel = MethodChannel('unavo/audio');
  static const events = EventChannel('unavo/audio/levels');
  static const routeEvents = EventChannel('unavo/audio/routes');
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<dynamic>? _routeSubscription;
  final _outputRoutes = StreamController<OutputRoute>.broadcast();
  Stream<OutputRoute> get outputRoutes => _outputRoutes.stream;
  OutputRoute outputRoute = OutputRoute.speaker;
  List<OutputRoute> availableOutputRoutes = const [
    OutputRoute.speaker,
    OutputRoute.receiver,
  ];
  OutputRoute? _requestedOutput;
  int? systemCallVolume;
  bool systemVolumeWritable = true;
  bool audioInterrupted = false;
  bool resumeFailed = false;
  String? outputError;
  bool get isAutomotive => state.mode == MicMode.car;
  MicState state = const MicState();
  AudioPermissions permissions = const AudioPermissions();
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

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
    await refreshOutputRoute();
    _routeSubscription = routeEvents.receiveBroadcastStream().listen(
      (dynamic event) => _readOutput(Map<Object?, Object?>.from(event as Map)),
      onError: (Object error) {
        systemCallVolume = null;
        outputError = error is PlatformException
            ? error.message
            : error.toString();
        notifyListeners();
      },
    );
  }

  OutputRoute _route(Object? value) => OutputRoute.values.firstWhere(
    (route) => route.name == value,
    orElse: () => OutputRoute.speaker,
  );

  void _readOutput(Map<Object?, Object?> snapshot) {
    final next = _route(snapshot['route']);
    final changed = next != outputRoute;
    outputRoute = next;
    if (snapshot['available'] case final List<dynamic> routes) {
      availableOutputRoutes = routes.map(_route).toSet().toList();
    }
    final volume = snapshot['callVolume'];
    // Missing/invalid route snapshots and focus transitions are not a mute.
    // Android confirms zero only from a valid stream range or an explicit mute.
    systemCallVolume =
        volume is num &&
            volume.isFinite &&
            volume >= 0 &&
            volume <= 100 &&
            (volume > 0 ||
                (snapshot['callVolumeZeroConfirmed'] == true &&
                    snapshot['interrupted'] != true))
        ? (volume > 0 ? volume.round().clamp(1, 100) : 0)
        : null;
    systemVolumeWritable = snapshot['volumeWritable'] as bool? ?? true;
    audioInterrupted = snapshot['interrupted'] as bool? ?? false;
    resumeFailed = snapshot['resumeFailed'] as bool? ?? false;
    outputError = snapshot['error'] as String?;
    if (changed) _outputRoutes.add(next);
    notifyListeners();
  }

  Future<void> refreshOutputRoute() async {
    if (!supported) return;
    try {
      final snapshot = await channel.invokeMapMethod<Object?, Object?>(
        'getOutputRoute',
      );
      if (snapshot != null) {
        _readOutput(snapshot);
      } else {
        systemCallVolume = null;
        notifyListeners();
      }
    } catch (_) {
      systemCallVolume = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setOutputRoute(OutputRoute route) async {
    _requirePlatform();
    final snapshot = await channel.invokeMapMethod<Object?, Object?>(
      'setOutputRoute',
      {'route': route.name},
    );
    _requestedOutput = route;
    if (snapshot != null) _readOutput(snapshot);
  }

  Future<void> applyOutputRoute() async {
    final requested = _requestedOutput;
    if (requested != null && availableOutputRoutes.contains(requested)) {
      await setOutputRoute(requested);
    } else {
      _requestedOutput = null;
      await setSpeakerphone(true); // Automatic: external device, then speaker.
    }
    await refreshOutputRoute();
  }

  Future<void> cycleOutputRoute() async {
    await refreshOutputRoute();
    if (availableOutputRoutes.isEmpty) return;
    final index = availableOutputRoutes.indexOf(outputRoute);
    await setOutputRoute(
      availableOutputRoutes[(index + 1) % availableOutputRoutes.length],
    );
  }

  void resetOutputPreference() {
    _requestedOutput = null;
  }

  Future<void> setSystemCallVolume(int percent) async {
    if (!isAutomotive || !supported) return;
    final snapshot = await channel.invokeMapMethod<Object?, Object?>(
      'setCallVolume',
      {'value': percent.clamp(0, 100)},
    );
    if (snapshot != null) _readOutput(snapshot);
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
    unawaited(_routeSubscription?.cancel());
    unawaited(_outputRoutes.close());
    super.dispose();
  }
}
