import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_state.dart';

class CallService extends ChangeNotifier {
  static const channel = MethodChannel('unavo/call');
  static const events = EventChannel('unavo/call/events');
  StreamSubscription<dynamic>? _subscription;
  CallState state = const CallState();
  Future<void> Function()? onLeaveCall;
  void Function(String code)? onOpenRoom;
  String? pendingOpenRoom;

  Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    _subscription = events.receiveBroadcastStream().listen(
      (dynamic value) {
        final event = Map<Object?, Object?>.from(value as Map);
        switch (event['event']) {
          case 'leaveCall':
            final callback = onLeaveCall;
            if (callback != null) unawaited(callback());
          case 'openRoom':
            final code = event['roomCode'] as String?;
            if (code != null) {
              pendingOpenRoom = code;
              onOpenRoom?.call(code);
            }
          case 'state':
            state = CallState.fromMap(event);
            notifyListeners();
        }
      },
      onError: (Object error) {
        state = CallState(
          error: error is PlatformException ? error.message : error.toString(),
        );
        notifyListeners();
      },
    );
    final value = await channel.invokeMapMethod<Object?, Object?>('getState');
    if (value != null) state = CallState.fromMap(value);
  }

  Future<void> start(String roomCode, String handle) async {
    if (!Platform.isAndroid)
      throw PlatformException(
        code: 'unavailable',
        message: '이 기기의 오디오 연결은 아직 지원하지 않습니다.',
      );
    final value = await channel.invokeMapMethod<Object?, Object?>('start', {
      'roomCode': roomCode,
      'handle': handle,
    });
    if (value != null) state = CallState.fromMap(value);
    notifyListeners();
  }

  Future<void> stop() async {
    if (Platform.isAndroid) await channel.invokeMethod<void>('stop');
    state = const CallState();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
