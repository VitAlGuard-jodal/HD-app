import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_mode.dart';

class DrivingState extends ChangeNotifier {
  DrivingState({required DeviceMode mode, Stream<Object?>? events}) {
    // 폰은 이벤트 채널에 구독하지 않으며 주입된 이벤트도 적용하지 않는다.
    if (mode != DeviceMode.car) return;
    _subscription = (events ?? _channel.receiveBroadcastStream()).listen(
      _onEvent,
      onError: (Object error) => _update(restricted: false, available: false),
      onDone: () => _update(restricted: false, available: false),
    );
  }

  static const _channel = EventChannel('unavo/drive');
  StreamSubscription<Object?>? _subscription;
  bool _restricted = false;
  bool _available = false;
  bool _disposed = false;

  bool get restricted => _restricted;
  bool get available => _available;

  void _onEvent(Object? event) {
    final available =
        event is Map &&
        event['available'] != false &&
        event['restricted'] is bool;
    _update(
      restricted: available && event['restricted'] == true,
      available: available,
    );
  }

  void _update({required bool restricted, required bool available}) {
    if (_disposed || (_restricted == restricted && _available == available)) {
      return;
    }
    _restricted = restricted;
    _available = available;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }
}
