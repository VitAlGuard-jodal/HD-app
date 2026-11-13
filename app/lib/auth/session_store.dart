import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/models.dart';
import 'legal_consent_store.dart';

abstract interface class TokenStore {
  String? get token;
  String get baseUrl;
}

class Session {
  const Session(
    this.token,
    this.handle,
    this.displayName, {
    this.avatar = const Avatar(),
  });
  final String token;
  final String handle;
  final String displayName;
  final Avatar avatar;
}

String resolveDefaultBaseUrl({
  required String environment,
  required bool isIOS,
}) {
  final baseUrl = environment.trim();
  if (baseUrl.isNotEmpty) return baseUrl;
  return isIOS ? 'http://127.0.0.1:8787' : 'http://10.0.2.2:8787';
}

class SessionStore extends ChangeNotifier implements TokenStore {
  SessionStore(this.preferences, {String? defaultBaseUrl})
    : defaultBaseUrl =
          defaultBaseUrl ??
          resolveDefaultBaseUrl(
            environment: const String.fromEnvironment('UNAVO_SERVER_URL'),
            isIOS: Platform.isIOS,
          ) {
    final token = preferences.getString('token');
    final handle = preferences.getString('handle');
    if (token != null && token.trim().isNotEmpty && handle != null) {
      _session = Session(
        token,
        handle,
        preferences.getString('displayName') ?? handle,
        avatar: _readAvatar(preferences),
      );
    }
  }
  final SharedPreferences preferences;
  final String defaultBaseUrl;
  Session? _session;
  Session? get session => _session;
  int _sessionRevision = 0;
  int get sessionRevision => _sessionRevision;
  ConsentRecord? _consent;
  ConsentRecord? get consent => _consent;
  int _consentRevision = 0;
  int get consentRevision => _consentRevision;
  bool _consentLoaded = false;
  bool get consentLoaded => _consentLoaded;
  // Entry requires only the account's current server privacy consent.
  // Optional location consent does not affect login or session restoration.
  bool get legalAccepted => hasPrivacyConsent(_consent);

  void _resetConsent() {
    ++_sessionRevision;
    ++_consentRevision;
    _consent = null;
    _consentLoaded = false;
  }

  bool updateConsent(ConsentRecord consent, {required int sessionRevision}) {
    if (_session == null || sessionRevision != _sessionRevision) return false;
    _consent = consent;
    ++_consentRevision;
    _consentLoaded = true;
    notifyListeners();
    return true;
  }

  @override
  String? get token => _session?.token;
  String? get handle => _session?.handle;
  String? get displayName => _session?.displayName;
  Avatar get avatar => _session?.avatar ?? const Avatar();
  static Avatar _readAvatar(SharedPreferences preferences) {
    try {
      return Avatar.fromJson(
        jsonDecode(preferences.getString('avatar') ?? '{}'),
      );
    } on FormatException {
      return const Avatar();
    }
  }

  @override
  String get baseUrl => preferences.getString('baseUrl') ?? defaultBaseUrl;
  int? get manualMicId => preferences.getInt('manualMicId');
  int get callVolume => (preferences.getInt('callVolume') ?? 100).clamp(0, 100);

  Future<void> setCallVolume(int value) =>
      preferences.setInt('callVolume', value.clamp(0, 100));

  Future<void> setBaseUrl(String value) async {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final previous = Uri.parse(baseUrl);
    final next = Uri.parse(normalized);
    final changed =
        previous.scheme != next.scheme ||
        previous.host != next.host ||
        previous.port != next.port;
    await preferences.setString('baseUrl', normalized);
    if (changed) {
      _resetConsent();
      notifyListeners();
    }
  }

  Future<void> setManualMicId(int? id) async {
    if (id == null) {
      await preferences.remove('manualMicId');
    } else {
      await preferences.setInt('manualMicId', id);
    }
  }

  Future<void> save(
    AuthResult result, {
    ConsentRecord? consent,
    bool consentLoaded = false,
    int? expectedConsentRevision,
  }) async {
    // 토큰은 마지막에 쓴다. 비밀번호는 어떤 저장소에도 기록하지 않는다.
    await preferences.setString('handle', result.user.handle);
    await preferences.setString('displayName', result.user.displayName);
    await preferences.setString(
      'avatar',
      jsonEncode(result.user.avatar.toJson()),
    );
    await preferences.setString('token', result.token);
    if (token != result.token || handle != result.user.handle) _resetConsent();
    _session = Session(
      result.token,
      result.user.handle,
      result.user.displayName,
      avatar: result.user.avatar,
    );
    if (consentLoaded &&
        (expectedConsentRevision == null ||
            expectedConsentRevision == _consentRevision)) {
      _consent = consent;
      ++_consentRevision;
      _consentLoaded = true;
    }
    notifyListeners();
  }

  Future<void> updateAvatar(Avatar value) async {
    final current = _session;
    if (current == null || value.version < current.avatar.version) return;
    _session = Session(
      current.token,
      current.handle,
      current.displayName,
      avatar: value,
    );
    notifyListeners();
    await preferences.setString('avatar', jsonEncode(value.toJson()));
  }

  Future<void> clear() async {
    await preferences.remove('token');
    await preferences.remove('handle');
    await preferences.remove('displayName');
    await preferences.remove('avatar');
    _session = null;
    _resetConsent();
    // 서버 주소와 마이크 선택은 다음 로그인에서도 보존한다.
    notifyListeners();
  }
}
