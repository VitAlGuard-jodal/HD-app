import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../net/models.dart';

String errorMessage(Object error) {
  if (error is ApiException)
    return error.status == 401
        ? '인증에 실패했습니다. 아이디·비밀번호 또는 로그인 상태를 확인해 주세요.'
        : error.message;
  if (error is IOException || error is TimeoutException)
    return '서버에 연결하지 못했습니다. 서버 주소와 네트워크를 확인해 주세요.';
  if (error is FormatException) return error.message;
  if (error is PlatformException)
    return error.message ?? '요청을 처리하지 못했습니다. 다시 시도해 주세요.';
  if (error is StateError) return error.message;
  return '요청을 처리하지 못했습니다. 다시 시도해 주세요.';
}

// RoomSession의 Kotlin exception.message ?: fallback 정책.
String exceptionMessage(Object error, String fallback) {
  if (error is ApiException) return error.message;
  if (error is PlatformException) return error.message ?? fallback;
  if (error is FormatException) return error.message;
  if (error is SocketException) return error.message;
  if (error is HttpException) return error.message;
  if (error is TimeoutException) return error.message ?? fallback;
  if (error is StateError) return error.message;
  return fallback;
}
