import 'package:flutter/foundation.dart';

abstract class MediaEngine {
  void join(String roomCode, String selfHandle);
  void leave();
  void setMuted(bool muted);
  void onSignal(String from, String kind, Object? payload);
  void onRemoteSpeaking(String handle);

  // F3 엔진은 수신 발화와 로컬 시그널을 이 콜백으로 전달한다.
  void Function(String handle, bool speaking)? remoteSpeaking;
  Future<void> Function(String to, String kind, Object? payload)? sendSignal;
}

class NoopMediaEngine extends MediaEngine {
  @override
  void join(String roomCode, String selfHandle) =>
      debugPrint('HDMEDIA join room=$roomCode self=$selfHandle (미디어 엔진 미연결)');
  @override
  void leave() => debugPrint('HDMEDIA leave');
  @override
  void setMuted(bool muted) => debugPrint('HDMEDIA muted=$muted');
  @override
  void onSignal(String from, String kind, Object? payload) =>
      debugPrint('HDMEDIA signal from=$from kind=$kind');
  @override
  void onRemoteSpeaking(String handle) =>
      debugPrint('HDMEDIA speaking=$handle');
}
