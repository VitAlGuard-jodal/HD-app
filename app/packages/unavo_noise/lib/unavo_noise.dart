import 'package:flutter/services.dart';

class UnavoNoise {
  UnavoNoise._();

  static const MethodChannel _channel = MethodChannel('unavo/noise');

  /// 캡처 후단 RNNoise 처리를 켜거나 끈다.
  /// 플러그인이 없는 플랫폼에서는 예외 대신 false를 돌려준다.
  static Future<bool> setEnabled(bool enabled) async {
    final result = await configure(enabled: enabled);
    return result['enabled'] == true;
  }

  /// RNNoise 처리와 캡처 PCM 덤프 시간을 설정한다(0초이면 덤프하지 않음).
  static Future<Map<String, Object?>> configure({
    required bool enabled,
    int dumpSeconds = 0,
  }) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('configure', {
            'enabled': enabled,
            'dumpSeconds': dumpSeconds,
          }) ??
          const <String, Object?>{'supported': false};
    } on MissingPluginException {
      return const <String, Object?>{'supported': false};
    }
  }

  /// 루프백 HTTP 서버로 캡처 덤프를 내보낸다.
  static Future<Map<String, Object?>> exportDump({int port = 18085}) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('exportDump', {
            'port': port,
          }) ??
          const <String, Object?>{'supported': false};
    } on MissingPluginException {
      return const <String, Object?>{'supported': false};
    }
  }

  /// supported, enabled, sampleRate, channels, frames, processed, bypassed, vad, exportPort.
  /// dumpPath, dumpBytes, dumpDropped(입력 파일 경로, 기록한 입력 바이트, 누락 10 ms 블록 수).
  static Future<Map<String, Object?>> status() async {
    try {
      return await _channel.invokeMapMethod<String, Object?>('status') ??
          const <String, Object?>{'supported': false};
    } on MissingPluginException {
      return const <String, Object?>{'supported': false};
    }
  }
}
