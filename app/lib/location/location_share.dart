import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../net/api_client.dart';
import '../net/models.dart';
import 'location_source.dart';

class _LocationDeletion {
  _LocationDeletion(this.code, this.handle, this.generation);
  final String code, handle;
  final int generation;
  int failures = 0;
}

enum LocationMotionState { unknown, moving, stationary }

class LocationShare extends ChangeNotifier {
  LocationShare({
    required this.api,
    required this.source,
    required this.roomCode,
    required this.selfHandle,
    this.canStart,
    DateTime Function()? now,
    int Function()? monotonicNow,
  }) : now = now ?? DateTime.now {
    _sampleNow = monotonicNow ?? () => _sampleClock.elapsedMilliseconds;
    _lastState = _stateValues();
    _observedRoom = roomCode();
    _observedHandle = selfHandle();
  }

  final ApiClient api;
  final LocationSource? source;
  final String? Function() roomCode;
  final String? Function() selfHandle;
  final bool Function()? canStart;
  final DateTime Function() now;
  // 중지·방 변경으로 재시작해도 이 실행의 stream과 세션 seq는 유지한다.
  static final String _processStream = _newStream();
  final String stream = _processStream;
  bool get available => source != null;
  bool get sharing => _sharing;
  LocationPermissionState? get permission => _permission;
  String? get error => _error;
  bool get deletionPending => _deletion != null;
  String? get deletionStatus => deletionPending ? '위치 삭제 대기 중' : null;
  LocationFix? get lastSent => _lastSent;
  final _sampleClock = Stopwatch()..start();
  late final int Function() _sampleNow;
  int? _pendingCollected, _sentCollected;
  num? _lastMeasuredAt;
  int? _measurementCollected;
  double get lastSentAgeMs => _sentCollected == null
      ? double.infinity
      : (_sampleNow() - _sentCollected!).toDouble();
  LocationMotionState get motionState => _motionState;
  bool get isStationary => motionState == LocationMotionState.stationary;

  bool _sharing = false;
  LocationMotionState _motionState = LocationMotionState.unknown;
  bool _disposed = false;
  LocationPermissionState? _permission;
  String? _error, _activeCode, _activeHandle, _observedRoom, _observedHandle;
  LocationFix? _lastSent, _lastAttempt;
  DateTime? _lastAttemptAt, _observingSince;
  LocationSample? _pending;
  final _samples = <(DateTime, LocationSample)>[];
  int _seq = 0, _failures = 0, _generation = 0;
  StreamSubscription<LocationSample>? _subscription;
  Timer? _sendTimer, _stationaryTimer;
  Future<void>? _starting, _stopping, _sending, _deleting, _shutdown;
  Object? _startToken;
  bool Function()? _startValid;
  _LocationDeletion? _deletion;
  Timer? _deleteTimer;

  // 성공한 기능 요청의 공유는 더 이상 임시 요청 토큰에 종속되지 않는다.
  void commitStart(Object token) {
    if (!sharing && !identical(_startToken, token)) return;
    _startToken = null;
    _startValid = null;
  }

  void invalidateStart(Object token) {
    if (identical(_startToken, token)) unawaited(stop());
  }

  // 기능을 켤 때마다 화면이 먼저 동의를 받는다. 공유는 자동 복원하지 않는다.
  Future<void> start({
    required Object token,
    required bool Function() stillValid,
  }) {
    if (_disposed || !(canStart?.call() ?? true) || !stillValid() || sharing)
      return Future<void>.value();
    if (_starting != null) {
      if (identical(_startToken, token)) return _starting!;
      return _starting!.then(
        (_) => start(token: token, stillValid: stillValid),
      );
    }
    _startToken = token;
    _startValid = stillValid;
    final generation = ++_generation;
    final code = roomCode();
    final handle = selfHandle();
    return _starting =
        Future<void>.microtask(
          () => _start(generation, code, handle, stillValid),
        ).whenComplete(() {
          _starting = null;
          if (!sharing &&
              generation == _generation &&
              identical(_startToken, token)) {
            _startToken = null;
            _startValid = null;
          }
        });
  }

  Future<void> _start(
    int generation,
    String? code,
    String? handle,
    bool Function() stillValid,
  ) async {
    if (_stopping != null) await _stopping;
    if (_disposed ||
        !(canStart?.call() ?? true) ||
        !stillValid() ||
        generation != _generation ||
        code != roomCode() ||
        handle != selfHandle())
      return;
    if (!available) {
      _setError('위치 공유를 사용할 수 없습니다');
      return;
    }
    if (code == null || handle == null) {
      _setError('방에 참여한 뒤 공유할 수 있습니다');
      return;
    }
    _activeCode = code;
    _activeHandle = handle;
    try {
      bool valid() => (canStart?.call() ?? true) && stillValid();
      if (!valid()) return;
      final permission = await source!.requestPermission();
      if (!_current(generation, code) || !valid()) return;
      _permission = permission;
      if (permission != LocationPermissionState.granted) {
        _activeCode = null;
        _activeHandle = null;
        _setError(
          permission == LocationPermissionState.serviceOff
              ? '위치 서비스가 꺼져 있습니다'
              : '위치 권한이 없습니다',
        );
        return;
      }
      // 재시도 DELETE가 이미 전송됐으면 완료 뒤 새 공유를 시작한다.
      if (_deleting != null) await _deleting;
      if (!_current(generation, code) || !valid()) return;
      _cancelDeletion();
      if (!_current(generation, code) || !valid()) return;
      _sharing = true;
      _error = null;
      _failures = 0;
      _lastAttemptAt = null;
      _lastAttempt = null;
      _lastSent = null;
      _subscription = source!.watch().listen(
        (sample) {
          if (!_current(generation, code)) {
            roomChanged();
            return;
          }
          if (!(_startValid?.call() ?? true)) {
            unawaited(stop());
            return;
          }
          _recordSample(sample);
          if (!_current(generation, code)) return;
          _pending = sample;
          // Duplicate measurements, even with a new transmission seq, do not
          // restart age. Include sensor delivery delay before the local clock.
          final at = sample.at.millisecondsSinceEpoch;
          if (_lastMeasuredAt == null || at > _lastMeasuredAt!) {
            _lastMeasuredAt = at;
            final delay = now().millisecondsSinceEpoch - at;
            _measurementCollected = _sampleNow() - (delay < 0 ? 10001 : delay);
          }
          _pendingCollected = _measurementCollected;
          _scheduleSend(generation, code);
        },
        onError: (Object error) {
          if (!_current(generation, code)) return;
          _stationaryTimer?.cancel();
          _observingSince = null;
          _samples.clear();
          _setMotionState(LocationMotionState.unknown);
          _setError(exceptionMessage(error, '위치를 읽지 못했습니다'));
        },
        onDone: () {
          if (_current(generation, code)) unawaited(stop());
        },
      );
      _notify();
    } catch (error) {
      if (!_current(generation, code)) return;
      _sharing = false;
      _activeCode = null;
      _activeHandle = null;
      _setError(exceptionMessage(error, '위치 공유를 시작하지 못했습니다'));
    }
  }

  void _recordSample(LocationSample sample) {
    final time = now();
    _observingSince ??= time;
    _samples.add((time, sample));
    final cutoff = time.subtract(const Duration(seconds: 3));
    // 창 경계의 표본 하나를 남겨 3초 동안의 이동 거리를 판단한다.
    while (_samples.length > 1 && !_samples[1].$1.isAfter(cutoff)) {
      _samples.removeAt(0);
    }
    final first = _samples.first.$2;
    final moving = _samples.any(
      (entry) =>
          (entry.$2.speed != null && entry.$2.speed! >= .5) ||
          _distance(first.lat, first.lng, entry.$2.lat, entry.$2.lng) >= 3,
    );
    final motion = moving
        ? LocationMotionState.moving
        : time.difference(_observingSince!) >= const Duration(seconds: 3)
        ? LocationMotionState.stationary
        : LocationMotionState.unknown;
    _stationaryTimer?.cancel();
    // 표본이 끊기면 이전 이동·정차 판정 대신 미확인 상태로 돌아간다.
    _stationaryTimer = Timer(const Duration(seconds: 3), () {
      _observingSince = null;
      _samples.clear();
      _setMotionState(LocationMotionState.unknown);
    });
    _setMotionState(motion);
  }

  void _scheduleSend(int generation, String code) {
    if (!_current(generation, code) ||
        !sharing ||
        _sending != null ||
        _pending == null)
      return;
    _sendTimer?.cancel();
    _sendTimer = null;
    final sample = _pending!;
    final previous = _lastAttempt;
    final stopped =
        sample.speed != null &&
        sample.speed! < .5 &&
        previous != null &&
        _distance(previous.lat, previous.lng, sample.lat, sample.lng) < 3;
    final interval = Duration(seconds: stopped || _failures >= 3 ? 5 : 1);
    final elapsed = _lastAttemptAt == null
        ? interval
        : now().difference(_lastAttemptAt!);
    if (elapsed < interval) {
      _sendTimer = Timer(
        interval - elapsed,
        () => _scheduleSend(generation, code),
      );
      return;
    }
    _pending = null;
    final fix = LocationFix(
      handle: _activeHandle!,
      stream: stream,
      lat: sample.lat,
      lng: sample.lng,
      acc: sample.accuracy,
      speed: sample.speed,
      heading: sample.heading,
      at: sample.at.millisecondsSinceEpoch,
      seq: _seq++,
    );
    _lastAttemptAt = now();
    _lastAttempt = fix;
    _sending = _send(code, fix, generation, _pendingCollected).whenComplete(() {
      _sending = null;
      _scheduleSend(generation, code);
    });
  }

  Future<void> _send(
    String code,
    LocationFix fix,
    int generation,
    int? collected,
  ) async {
    try {
      final dropped = await api.sendLocation(code, fix);
      if (!_current(generation, code)) return;
      _failures = 0;
      _error = null;
      if (!dropped) {
        _lastSent = fix;
        _sentCollected = collected;
      }
      _notify();
    } catch (error) {
      if (!_current(generation, code)) return;
      _failures++;
      _setError(exceptionMessage(error, '위치를 보내지 못했습니다'));
    }
  }

  // 실제 방·사용자 식별자가 바뀔 때만 이전 방의 삭제 재시도를 취소한다.
  void roomChanged() {
    final changed =
        _observedRoom != roomCode() || _observedHandle != selfHandle();
    _observedRoom = roomCode();
    _observedHandle = selfHandle();
    final deletion = _deletion;
    if (deletion != null &&
        (roomCode() != deletion.code || selfHandle() != deletion.handle)) {
      _cancelDeletion();
    }
    if (_activeCode != null &&
        (roomCode() != _activeCode || selfHandle() != _activeHandle)) {
      unawaited(stop());
    } else if (changed && !sharing && _error != null) {
      _error = null;
      _notify();
    }
  }

  Future<void> stop({bool notifyServer = true}) {
    // 진행 중인 DELETE를 기다리는 start도 뒤이은 stop으로 취소할 수 있다.
    ++_generation;
    if (!notifyServer) _cancelDeletion();
    if (_stopping != null) return _stopping!;
    final stopped = Completer<void>();
    _stopping = stopped.future;
    unawaited(
      _stop(notifyServer: notifyServer).then<void>(
        (_) {
          _stopping = null;
          stopped.complete();
        },
        onError: (Object error, StackTrace stack) {
          _stopping = null;
          stopped.completeError(error, stack);
        },
      ),
    );
    return stopped.future;
  }

  Future<void> _stop({required bool notifyServer}) async {
    final code = _activeCode;
    final handle = _activeHandle;
    final job = !notifyServer
        ? null
        : code != null && handle != null
        ? _LocationDeletion(code, handle, _generation)
        : _deletion;
    if (job != null) {
      _deleteTimer?.cancel();
      _deleteTimer = null;
      _deletion = job;
    }
    _startToken = null;
    _startValid = null;
    _error = null;
    _lastSent = null;
    _sentCollected = _pendingCollected = _measurementCollected = null;
    _lastMeasuredAt = null;
    _activeCode = null;
    _activeHandle = null;
    _sharing = false;
    _sendTimer?.cancel();
    _sendTimer = null;
    _stationaryTimer?.cancel();
    _stationaryTimer = null;
    _pending = null;
    _samples.clear();
    _observingSince = null;
    _motionState = LocationMotionState.unknown;
    _notify();
    try {
      await _subscription?.cancel();
    } catch (_) {
      /* DELETE는 구독 해제 오류와 관계없이 시도한다. */
    } finally {
      _subscription = null;
    }
    // 늦게 끝난 POST가 DELETE 뒤에 위치를 되살리지 않게 순서를 보장한다.
    if (_sending != null) await _sending;
    if (_deleting != null) await _deleting;
    if (job != null && identical(_deletion, job)) await _deleteLocation(job);
  }

  Future<void> _deleteLocation(_LocationDeletion job) {
    return _deleting = _attemptDelete(job).whenComplete(() => _deleting = null);
  }

  Future<void> _attemptDelete(_LocationDeletion job) async {
    if (!identical(_deletion, job) || sharing && _generation > job.generation)
      return;
    try {
      await api.stopLocation(job.code);
      if (identical(_deletion, job)) _cancelDeletion();
    } catch (error) {
      if (!identical(_deletion, job)) return;
      if (_disposed ||
          roomCode() != job.code ||
          selfHandle() != job.handle ||
          error is ApiException &&
              ({401, 403, 404}.contains(error.status) ||
                  error.code == 'DEVICE_REPLACED')) {
        _cancelDeletion();
        return;
      }
      final seconds = (1 << job.failures.clamp(0, 6)).clamp(1, 60);
      job.failures++;
      _deleteTimer = Timer(Duration(seconds: seconds), () {
        _deleteTimer = null;
        if (identical(_deletion, job) && !sharing)
          unawaited(_deleteLocation(job));
      });
      _notify();
    }
  }

  void _cancelDeletion() {
    _deleteTimer?.cancel();
    _deleteTimer = null;
    _deletion = null;
    _notify();
  }

  bool _current(int generation, String code) =>
      !_disposed &&
      generation == _generation &&
      _activeCode == code &&
      roomCode() == code &&
      selfHandle() == _activeHandle;

  void _setError(String message) {
    _error = message;
    _notify();
  }

  void _setMotionState(LocationMotionState value) {
    if (_motionState == value) return;
    _motionState = value;
    _notify();
  }

  List<Object?> _stateValues() => [
    available,
    sharing,
    permission,
    error,
    lastSent,
    motionState,
    deletionPending,
  ];

  late List<Object?> _lastState;
  void _notify() {
    if (_disposed) return;
    final state = _stateValues();
    if (listEquals(state, _lastState)) return;
    _lastState = state;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _deleteTimer?.cancel();
    _shutdown = stop();
    super.dispose();
  }

  // 권한 대기 중 start는 무효화하고, 진행 중 POST→DELETE까지 기다린다.
  Future<void> shutdown() {
    dispose();
    return _shutdown!;
  }
}

String _newStream() {
  final random = math.Random.secure();
  return List.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

double _distance(double lat1, double lng1, double lat2, double lng2) {
  const radians = math.pi / 180;
  final dLat = (lat2 - lat1) * radians;
  final dLng = (lng2 - lng1) * radians;
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * radians) *
          math.cos(lat2 * radians) *
          math.pow(math.sin(dLng / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
}
