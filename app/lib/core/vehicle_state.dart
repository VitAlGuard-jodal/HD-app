import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_mode.dart';

enum ExitProtection {
  micAndLocation('마이크와 위치 보내기를 멈춥니다', 'locationoff'),
  micOnly('마이크만 끕니다', 'micoff'),
  none('아무것도 바꾸지 않습니다', 'car');

  const ExitProtection(this.notice, this.icon);
  final String notice, icon;
}

/// Unknown signals enable manual readiness, never infer Park from speed/UX lock.
class VehicleState extends ChangeNotifier {
  VehicleState({required this.mode, Stream<Object?>? events}) {
    if (mode != DeviceMode.car) return;
    _subscription = (events ?? _channel.receiveBroadcastStream()).listen(
      _onEvent,
      onError: (Object _) => _onEvent(null),
      onDone: () => _onEvent(null),
    );
  }
  static const _channel = EventChannel('unavo/vehicle');
  final DeviceMode mode;
  StreamSubscription<Object?>? _subscription;
  bool _disposed = false, _loggedFallback = false;
  bool available = false;
  bool? parked;
  Map<String, int?> doors = const {};
  String? exitDoor;

  String? get readyBlockedReason {
    if (!available) return null;
    if (doors.values.any((position) => position! > 0)) return '문이 열려 있습니다';
    if (parked != true) return 'P단에서 준비할 수 있습니다';
    return null;
  }

  bool get exiting =>
      mode == DeviceMode.car &&
      parked == true &&
      exitDoor != null &&
      (doors[exitDoor] ?? 0) > 0;

  void _onEvent(Object? event) {
    if (_disposed) return;
    final map = event is Map ? event : const <Object?, Object?>{};
    final rawDoors = map['doors'];
    final nextDoors = <String, int?>{};
    if (rawDoors is Map) {
      for (final entry in rawDoors.entries) {
        if (entry.key is String) {
          final value = entry.value;
          nextDoors[entry.key as String] = value is int && value >= 0
              ? value
              : null;
        }
      }
    }
    final nextParked = map['parked'] is bool ? map['parked'] as bool : null;
    final nextExit = map['exitDoor'] is String
        ? map['exitDoor'] as String
        : null;
    final nextAvailable =
        map['available'] == true &&
        nextParked != null &&
        nextDoors.isNotEmpty &&
        nextDoors.values.every((value) => value != null);
    if (!nextAvailable && !_loggedFallback) {
      debugPrint('unavo-vehicle: manual readiness fallback');
      _loggedFallback = true;
    } else if (nextAvailable) {
      _loggedFallback = false;
    }
    if (nextAvailable == available &&
        nextParked == parked &&
        nextExit == exitDoor &&
        mapEquals(nextDoors, doors))
      return;
    available = nextAvailable;
    parked = nextParked;
    doors = Map.unmodifiable(nextDoors);
    exitDoor = nextExit;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
