import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class FollowSpeechOutput {
  Future<void> speak(String text, DateTime expiresAt);
  Future<void> stop();
}

/// The native channel accepts one utterance. Stopping follow must not stop a
/// readiness announcement, although both guidance queues share that channel.
class SpeechOutputCoordinator {
  SpeechOutputCoordinator({
    FollowSpeechOutput? output,
    DateTime Function()? now,
  }) : output = output ?? PleosSpeechOutput(),
       now = now ?? DateTime.now;
  final FollowSpeechOutput output;
  final DateTime Function() now;
  Future<void> _queue = Future<void>.value(), _stopping = Future<void>.value();
  _ScopedSpeechOutput? _active;
  FollowSpeechOutput scope() => _ScopedSpeechOutput(this);

  Future<void> _speak(
    _ScopedSpeechOutput scope,
    String text,
    DateTime expiresAt,
  ) {
    final generation = scope.generation;
    final operation = _queue.then((_) async {
      while (true) {
        final stopping = _stopping;
        await stopping;
        if (identical(stopping, _stopping)) break;
      }
      if (generation != scope.generation || !now().isBefore(expiresAt)) return;
      _active = scope;
      try {
        await output.speak(text, expiresAt);
      } finally {
        if (identical(_active, scope)) _active = null;
      }
    });
    _queue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _stop(_ScopedSpeechOutput scope) {
    ++scope.generation;
    if (!identical(_active, scope)) return Future<void>.value();
    return _stopping = _stopping.then((_) => output.stop()).catchError((
      Object error,
    ) {
      debugPrint('unavo-tts: scoped stop failed (${error.runtimeType})');
    });
  }
}

class _ScopedSpeechOutput implements FollowSpeechOutput {
  _ScopedSpeechOutput(this.coordinator);
  final SpeechOutputCoordinator coordinator;
  int generation = 0;
  @override
  Future<void> speak(String text, DateTime expiresAt) =>
      coordinator._speak(this, text, expiresAt);
  @override
  Future<void> stop() => coordinator._stop(this);
}

class PleosSpeechOutput implements FollowSpeechOutput {
  PleosSpeechOutput({this.channel = const MethodChannel('unavo/tts')});
  final MethodChannel channel;

  @override
  Future<void> speak(String text, DateTime expiresAt) => _call('speak', {
    'text': text,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
  });

  @override
  Future<void> stop() => _call('stop');

  Future<void> _call(String method, [Map<String, Object>? arguments]) async {
    try {
      await channel.invokeMethod<bool>(method, arguments);
    } on MissingPluginException {
      debugPrint('unavo-tts: unavailable');
    } on PlatformException catch (error) {
      debugPrint('unavo-tts: ${error.code}');
    }
  }
}

enum _FollowVoiceState { current, delayed, stopped }

class _Announcement {
  _Announcement(this.text, this.expiresAt, this.generation);
  final String text;
  final DateTime expiresAt;
  final int generation;
}

/// Supplements RoomSession's existing notices; never consumes UI notices.
class FollowVoiceGuidance {
  FollowVoiceGuidance({
    required this.enabled,
    FollowSpeechOutput? output,
    DateTime Function()? now,
  }) : output = output ?? PleosSpeechOutput(),
       now = now ?? DateTime.now;

  // Reuse the existing server stale interval, but measure from the fix's `at`.
  static const staleAfter = Duration(seconds: 90);
  static const announcementLifetime = Duration(seconds: 10);
  final bool Function() enabled;
  final FollowSpeechOutput output;
  final DateTime Function() now;
  final _queue = <_Announcement>[];
  final _announced = <String>{};
  String? _room, _target;
  String _name = '';
  DateTime? _measurement;
  num? _lastAt;
  _FollowVoiceState _state = _FollowVoiceState.current;
  Timer? _timer;
  bool _terminal = false, _draining = false, _disposed = false;
  int _generation = 0;
  Future<void> _stopping = Future<void>.value();

  // Vehicle notices use the same serialized, expiring, generation-scoped queue
  // as follow guidance. Call clear when the readiness cycle/room ends.
  void announceOnce({
    required String room,
    required String key,
    required String text,
  }) {
    if (_disposed || !enabled()) return;
    if (_room != room) clear();
    _room = room;
    if (!_announced.add(key)) return;
    _queue.add(
      _Announcement(text, now().add(announcementLifetime), _generation),
    );
    unawaited(_drain());
  }

  void update({
    required String? room,
    required String? target,
    required String name,
    required num? measuredAt,
    required bool sharing,
    required bool leaving,
  }) {
    if (_disposed) return;
    if (!enabled() || room == null || !sharing || leaving) {
      clear();
      return;
    }
    if (target == null) {
      // A remote terminal event itself ends follow. Keep its final sentence
      // until spoken, while explicit user stops/leave always call clear().
      if (!_terminal || room != _room) clear();
      return;
    }
    if (room != _room || target != _target || _terminal) {
      clear();
      _room = room;
      _target = target;
      _measurement = now(); // no first fix yet: allow the same 90-second grace
    }
    _name = name;
    if (measuredAt != null &&
        measuredAt.isFinite &&
        measuredAt >= 0 &&
        measuredAt <= 8640000000000000 &&
        measuredAt != _lastAt) {
      _lastAt = measuredAt;
      final measured = DateTime.fromMillisecondsSinceEpoch(measuredAt.toInt());
      _measurement = measured.isAfter(now()) ? now() : measured;
    }
    _checkAge();
  }

  void _checkAge() {
    _timer?.cancel();
    if (_disposed || _terminal || _target == null) return;
    final remaining = staleAfter - now().difference(_measurement!);
    if (remaining <= Duration.zero) {
      _transition(_FollowVoiceState.delayed);
    } else {
      if (_state == _FollowVoiceState.delayed) {
        _state = _FollowVoiceState.current;
        _queue.clear(); // an unsaid delay notice is obsolete after recovery
        _stopOutput(); // includes speech waiting for asynchronous SDK initialize
      }
      _timer = Timer(remaining, _checkAge);
    }
  }

  void ended({
    required String target,
    required String name,
    required String? reason,
  }) {
    if (_disposed || !enabled() || target != _target || _terminal) return;
    if (reason != 'stopped' && reason != 'stale') {
      clear();
      return;
    }
    _name = name;
    _terminal = true;
    _timer?.cancel();
    _transition(
      reason == 'stopped'
          ? _FollowVoiceState.stopped
          : _FollowVoiceState.delayed,
    );
  }

  void _transition(_FollowVoiceState next) {
    if (_state == next) return;
    _state = next;
    // Only the latest state of this peer is relevant when speech is backed up.
    _queue.clear();
    final text = next == _FollowVoiceState.stopped
        ? '$_name 님이 위치 공유를 중지했습니다'
        : '$_name 님 위치가 잠시 갱신되지 않고 있습니다';
    _queue.add(
      _Announcement(text, now().add(announcementLifetime), _generation),
    );
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final stopping = _stopping;
        await stopping;
        if (!identical(stopping, _stopping)) continue;
        if (_queue.isEmpty || _disposed) break;
        final item = _queue.removeAt(0);
        if (item.generation != _generation || !now().isBefore(item.expiresAt))
          continue;
        try {
          // Completes on the SDK's onDone/onStop/onError, not on submission.
          await output.speak(item.text, item.expiresAt);
        } catch (error) {
          debugPrint('unavo-tts: output failed (${error.runtimeType})');
        }
      }
    } finally {
      _draining = false;
    }
  }

  void clear() {
    final hadContext = _room != null;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _queue.clear();
    _announced.clear();
    _room = _target = null;
    _measurement = null;
    _lastAt = null;
    _terminal = false;
    _state = _FollowVoiceState.current;
    if (hadContext) _stopOutput();
  }

  void _stopOutput() {
    _stopping = _stopping.then((_) => output.stop()).catchError((Object error) {
      debugPrint('unavo-tts: stop failed (${error.runtimeType})');
    });
  }

  Future<void> dispose() {
    clear();
    _disposed = true;
    return _stopping;
  }
}
