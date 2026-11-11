import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/errors.dart';
import '../net/api_client.dart';
import '../net/models.dart';
import 'location_source.dart';

class LocationShare extends ChangeNotifier {
  LocationShare({
    required this.api,
    required this.source,
    required this.roomCode,
    required this.selfHandle,
    required this.preferences,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    _lastState = _stateValues();
  }

  final ApiClient api;
  final LocationSource? source;
  final String? Function() roomCode;
  final String? Function() selfHandle;
  final SharedPreferences preferences;
  final DateTime Function() now;
  static const consentKey = 'location.consent.v1';
  // 중지·방 변경으로 재시작해도 이 실행의 stream과 세션 seq는 유지한다.
  static final String _processStream = _newStream();
  final String stream = _processStream;
  bool get available => source != null;
  bool get consented => _consented;
  bool get sharing => _sharing;
  LocationPermissionState? get permission => _permission;
  String? get error => _error;
  LocationFix? get lastSent => _lastSent;
  bool get isStationary => _isStationary;

  bool _consented = false, _sharing = false, _isStationary = false;
  bool _disposed = false;
  LocationPermissionState? _permission;
  String? _error, _activeCode, _activeHandle;
  LocationFix? _lastSent, _lastAttempt;
  DateTime? _lastAttemptAt, _observingSince;
  LocationSample? _pending;
  final _samples = <(DateTime, LocationSample)>[];
  int _seq = 0, _failures = 0, _generation = 0;
  StreamSubscription<LocationSample>? _subscription;
  Timer? _sendTimer, _stationaryTimer;
  Future<void>? _starting, _stopping, _sending;

  // 저장값은 동의 이력이다. 새 실행의 동의나 공유 시작으로 복원하지 않는다.
  Future<void> consent() async {
    await preferences.setBool(consentKey, true);
    if (_disposed || _consented) return;
    _consented = true;
    _notify();
  }

  Future<void> start() {
    if (_disposed || sharing) return Future<void>.value();
    if (_starting != null) return _starting!;
    final generation = ++_generation;
    final code = roomCode();
    final handle = selfHandle();
    return _starting = Future<void>.microtask(
      () => _start(generation, code, handle),
    ).whenComplete(() => _starting = null);
  }

  Future<void> _start(int generation, String? code, String? handle) async {
    if (_stopping != null) await _stopping;
    if (_disposed ||
        generation != _generation ||
        code != roomCode() ||
        handle != selfHandle())
      return;
    if (!available) {
      _setError('위치 공유를 사용할 수 없습니다');
      return;
    }
    if (!consented) {
      _setError('위치 공유 동의가 필요합니다');
      return;
    }
    if (code == null || handle == null) {
      _setError('방에 참여한 뒤 공유할 수 있습니다');
      return;
    }
    _activeCode = code;
    _activeHandle = handle;
    try {
      final permission = await source!.requestPermission();
      if (!_current(generation, code)) return;
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
          _recordSample(sample);
          if (!_current(generation, code)) return;
          _pending = sample;
          _scheduleSend(generation, code);
        },
        onError: (Object error) {
          if (!_current(generation, code)) return;
          _setStationary(false);
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
    final slow = _samples.every(
      (entry) => entry.$2.speed != null && entry.$2.speed! < 1,
    );
    final nearby = _samples.every(
      (entry) =>
          _distance(first.lat, first.lng, entry.$2.lat, entry.$2.lng) < 3,
    );
    final stationary =
        time.difference(_observingSince!) >= const Duration(seconds: 3) &&
        (slow || nearby);
    _stationaryTimer?.cancel();
    // 표본이 끊긴 뒤 예전 정차 판정으로 차량 설정을 허용하지 않는다.
    _stationaryTimer = Timer(const Duration(seconds: 3), () {
      _observingSince = null;
      _samples.clear();
      _setStationary(false);
    });
    _setStationary(stationary);
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
    _sending = _send(code, fix, generation).whenComplete(() {
      _sending = null;
      _scheduleSend(generation, code);
    });
  }

  Future<void> _send(String code, LocationFix fix, int generation) async {
    try {
      final dropped = await api.sendLocation(code, fix);
      if (!_current(generation, code)) return;
      _failures = 0;
      _error = null;
      if (!dropped) _lastSent = fix;
      _notify();
    } catch (error) {
      if (!_current(generation, code)) return;
      _failures++;
      _setError(exceptionMessage(error, '위치를 보내지 못했습니다'));
    }
  }

  // RoomSession이 방 코드/나가기 상태를 바꿀 때 호출한다.
  void roomChanged() {
    if (_activeCode != null &&
        (roomCode() != _activeCode || selfHandle() != _activeHandle))
      unawaited(stop());
  }

  Future<void> stop() {
    // 진행 중인 DELETE를 기다리는 start도 뒤이은 stop으로 취소할 수 있다.
    ++_generation;
    if (_stopping != null) return _stopping!;
    final stopped = Completer<void>();
    _stopping = stopped.future;
    unawaited(
      _stop().then<void>(
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

  Future<void> _stop() async {
    final code = _activeCode;
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
    _isStationary = false;
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
    if (code != null) {
      try {
        await api.stopLocation(code);
      } catch (_) {
        /* 방이 사라졌거나 연결이 끊겨도 로컬 공유는 끝낸다. */
      }
    }
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

  void _setStationary(bool value) {
    if (_isStationary == value) return;
    _isStationary = value;
    _notify();
  }

  List<Object?> _stateValues() => [
    available,
    consented,
    sharing,
    permission,
    error,
    lastSent,
    isStationary,
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
    _disposed = true;
    unawaited(stop());
    super.dispose();
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
