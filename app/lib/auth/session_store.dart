import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/models.dart';

abstract interface class TokenStore {
  String? get token;
  String get baseUrl;
}

class Session {
  const Session(this.token, this.handle, this.displayName);
  final String token;
  final String handle;
  final String displayName;
}

class SessionStore extends ChangeNotifier implements TokenStore {
  SessionStore(this.preferences, {String? defaultBaseUrl})
    : defaultBaseUrl =
          defaultBaseUrl ??
          (Platform.isIOS ? 'http://127.0.0.1:8787' : 'http://10.0.2.2:8787') {
    final token = preferences.getString('token');
    final handle = preferences.getString('handle');
    if (token != null && token.trim().isNotEmpty && handle != null) {
      _session = Session(
        token,
        handle,
        preferences.getString('displayName') ?? handle,
      );
    }
  }
  final SharedPreferences preferences;
  final String defaultBaseUrl;
  Session? _session;
  Session? get session => _session;
  @override
  String? get token => _session?.token;
  String? get handle => _session?.handle;
  String? get displayName => _session?.displayName;
  @override
  String get baseUrl => preferences.getString('baseUrl') ?? defaultBaseUrl;
  int? get manualMicId => preferences.getInt('manualMicId');
  int get callVolume => (preferences.getInt('callVolume') ?? 100).clamp(0, 200);

  Future<void> setCallVolume(int value) =>
      preferences.setInt('callVolume', value.clamp(0, 200));

  Future<void> setBaseUrl(String value) async {
    await preferences.setString(
      'baseUrl',
      value.trim().replaceFirst(RegExp(r'/+$'), ''),
    );
  }

  Future<void> setManualMicId(int? id) async {
    if (id == null) {
      await preferences.remove('manualMicId');
    } else {
      await preferences.setInt('manualMicId', id);
    }
  }

  Future<void> save(AuthResult result) async {
    // 토큰은 마지막에 쓴다. 비밀번호는 어떤 저장소에도 기록하지 않는다.
    await preferences.setString('handle', result.user.handle);
    await preferences.setString('displayName', result.user.displayName);
    await preferences.setString('token', result.token);
    _session = Session(
      result.token,
      result.user.handle,
      result.user.displayName,
    );
    notifyListeners();
  }

  Future<void> clear() async {
    await preferences.remove('token');
    await preferences.remove('handle');
    await preferences.remove('displayName');
    _session = null;
    // 서버 주소와 마이크 선택은 다음 로그인에서도 보존한다.
    notifyListeners();
  }
}
