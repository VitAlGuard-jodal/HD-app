import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const legalConsentKey = 'legal.consent.v1';
const legalVersion = '3';
const locationLegalVersion = '3';

Map<String, dynamic> _consents(SharedPreferences preferences) {
  try {
    final value = jsonDecode(preferences.getString(legalConsentKey) ?? '{}');
    return value is Map<String, dynamic> ? value : {};
  } on FormatException {
    return {};
  }
}

bool hasPrivacyConsent(SharedPreferences preferences) {
  final privacy = _consents(preferences)['privacy'];
  return privacy is Map &&
      privacy['accepted'] == true &&
      privacy['version'] == legalVersion;
}

bool hasLocationConsent(SharedPreferences preferences) {
  final location = _consents(preferences)['location'];
  return location is Map &&
      location['accepted'] == true &&
      location['version'] == locationLegalVersion;
}

Future<void> saveLegalConsent(
  SharedPreferences preferences, {
  required bool privacy,
  required bool location,
}) async {
  final saved = await preferences.setString(
    legalConsentKey,
    jsonEncode({
      'privacy': {'accepted': privacy, 'version': legalVersion},
      'location': {'accepted': location, 'version': locationLegalVersion},
    }),
  );
  if (!saved) throw const FormatException('동의 내역을 저장하지 못했습니다.');
}

Future<void> saveLocationConsent(SharedPreferences preferences) async {
  final values = _consents(preferences);
  values['location'] = {'accepted': true, 'version': locationLegalVersion};
  if (!await preferences.setString(legalConsentKey, jsonEncode(values))) {
    throw const FormatException('동의 내역을 저장하지 못했습니다.');
  }
}
