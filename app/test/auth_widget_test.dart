import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/auth/handle_rules.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/screens/phone/auth.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/avatar_fakes.dart';
import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  testWidgets('가입은 만 14세 이상 확인 전 제출을 막고 확인 뒤 over14 true를 전송한다', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(await SharedPreferences.getInstance());
    final appearance = AppearanceController();
    final http = AvatarTestHttp()
      ..jsonResponse = (_) => {
        'user': {'handle': 'alice', 'displayName': '앨리스'},
        'token': 'signup-token',
      };
    final api = http.api(store);
    try {
      await tester.pumpWidget(
        UnavoAppearance(
          controller: appearance,
          child: MaterialApp(
            builder: testIconBuilder,
            theme: unavoTheme(Brightness.dark),
            home: AuthScreen(api: api, store: store, mode: DeviceMode.phone),
          ),
        ),
      );
      await pumpConsentUi(tester);
      final age = find.byKey(const ValueKey('signup-age-check'));
      expect(age, findsNothing);
      await tester.tap(find.byTooltip('가입'));
      await pumpConsentUi(tester);
      expect(tester.widget<PanelButton>(age).selected, isFalse);
      await tester.enterText(find.byType(TextField).at(0), 'alice');
      await tester.enterText(find.byType(TextField).at(1), 'password123');
      await tester.ensureVisible(find.byType(TextField).at(2));
      await tester.enterText(find.byType(TextField).at(2), '앨리스');
      await tester.tap(find.byTooltip('가입하고 시작'));
      await pumpConsentUi(tester);
      expect(find.text('만 14세 이상만 가입할 수 있습니다.'), findsOneWidget);
      expect(http.requests, isEmpty);
      expect(store.session, isNull);
      await tester.ensureVisible(age);
      await tester.tap(age);
      await pumpConsentUi(tester);
      expect(tester.widget<PanelButton>(age).selected, isTrue);
      expect(tester.widget<PanelButton>(age).style, PanelButtonStyle.gold);
      await tester.tap(find.byTooltip('가입하고 시작'));
      await pumpConsentUi(tester);
      expect(http.requests, hasLength(1));
      expect(http.requests.single.method, 'POST');
      expect(http.requests.single.uri.path, '/v1/auth/signup');
      expect(jsonDecode(utf8.decode(http.requests.single.body)), {
        'handle': 'alice',
        'password': 'password123',
        'displayName': '앨리스',
        'over14': true,
      });
      expect(store.token, 'signup-token');
      await tester.tap(find.byTooltip('로그인'));
      await pumpConsentUi(tester);
      expect(age, findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
      store.dispose();
      appearance.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('로그인 빈 입력은 Kotlin 아이디 규칙 오류를 표시한다', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(await SharedPreferences.getInstance());
    final appearance = AppearanceController();
    await tester.pumpWidget(
      UnavoAppearance(
        controller: appearance,
        child: MaterialApp(
          builder: testIconBuilder,
          theme: unavoTheme(Brightness.dark),
          home: AuthScreen(
            api: ApiClient(tokenStore: store),
            store: store,
            mode: DeviceMode.phone,
          ),
        ),
      ),
    );
    await pumpConsentUi(tester);
    await tester.tap(find.byTooltip('시작'));
    await pumpConsentUi(tester);
    await tester.ensureVisible(find.text(HandleRules.help).first);
    await pumpConsentUi(tester);
    expect(find.text(HandleRules.help), findsOneWidget);
    expect(store.session, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    appearance.dispose();
  });
}
