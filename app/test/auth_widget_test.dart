import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/auth/handle_rules.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/screens/phone/auth.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/avatar_fakes.dart';
import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  testWidgets('서버 설정은 검증된 정규화 주소를 콜백에 전달하고 저장·화면 전환을 위임한다', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(await SharedPreferences.getInstance());
    final appearance = AppearanceController();
    final api = ApiClient(tokenStore: store);
    final original = store.baseUrl;
    final saved = <String>[];
    var failSave = false;
    try {
      await tester.pumpWidget(
        UnavoAppearance(
          controller: appearance,
          child: MaterialApp(
            builder: testIconBuilder,
            theme: unavoTheme(Brightness.dark),
            home: AuthScreen(
              api: api,
              store: store,
              mode: DeviceMode.phone,
              serverSettingsOnly: true,
              onSaveServer: (url) async {
                saved.add(url);
                if (failSave)
                  throw const ApiException(503, 'unavailable', '연결 실패');
              },
            ),
          ),
        ),
      );
      await pumpConsentUi(tester);
      final field = find.byType(TextField);
      final save = find.byKey(const ValueKey('server-settings-save'));
      await tester.enterText(field, 'ftp://example.invalid');
      await tester.tap(save);
      await pumpConsentUi(tester);
      expect(saved, isEmpty);
      await tester.enterText(field, ' https://new.example.invalid/// ');
      await tester.tap(save);
      await pumpConsentUi(tester);
      expect(saved, ['https://new.example.invalid']);
      expect(store.baseUrl, original);
      expect(find.byType(AuthScreen), findsOneWidget);
      failSave = true;
      await tester.tap(save);
      await pumpConsentUi(tester);
      expect(find.text('연결 실패'), findsOneWidget);
      expect(store.baseUrl, original);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      api.close();
      store.dispose();
      appearance.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

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
  for (final size in [const Size(1706, 1206), const Size(1320, 940)]) {
    for (final signup in [false, true]) {
      testWidgets(
        '차량 $size ${signup ? '가입' : '로그인'} 입력·시작은 가로 한 줄이며 45% IME에도 보인다',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          SharedPreferences.setMockInitialValues({});
          final store = SessionStore(await SharedPreferences.getInstance());
          final appearance = AppearanceController();
          final http = AvatarTestHttp()
            ..jsonResponse = (_) => {
              'user': {'handle': 'alice', 'displayName': '앨리스'},
              'token': 'car-auth-token',
            };
          final api = http.api(store);
          try {
            await tester.pumpWidget(
              UnavoAppearance(
                controller: appearance,
                child: MaterialApp(
                  builder: testIconBuilder,
                  theme: unavoTheme(Brightness.dark),
                  home: AuthScreen(
                    api: api,
                    store: store,
                    mode: DeviceMode.car,
                  ),
                ),
              ),
            );
            await pumpConsentUi(tester);
            if (signup) {
              await tester.tap(find.byTooltip('가입'));
              await pumpConsentUi(tester);
            }
            final form = find.byKey(const ValueKey('car-auth-form'));
            final inputs = find.descendant(
              of: form,
              matching: find.byType(TextField),
            );
            final submit = find.byKey(const ValueKey('car-auth-submit'));
            expect(inputs, findsNWidgets(signup ? 3 : 2));
            final before = [
              for (var i = 0; i < (signup ? 3 : 2); i++)
                tester.getRect(inputs.at(i)),
            ];
            for (var i = 0; i < before.length; i++) {
              expect(
                before[i].center.dy,
                closeTo(tester.getCenter(submit).dy, .01),
              );
              if (i > 0)
                expect(before[i].left - before[i - 1].right, closeTo(24, .01));
            }
            expect(tester.getRect(submit).left, greaterThan(before.last.right));
            await tester.enterText(inputs.at(0), 'alice');
            await tester.enterText(inputs.at(1), 'password123');
            if (signup) await tester.enterText(inputs.at(2), '앨리스');
            await tester.tap(
              find.byKey(const ValueKey('car-auth-server-toggle')),
            );
            await pumpConsentUi(tester);
            final server = find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.hintText == 'https://…',
            );
            await tester.enterText(server, 'https://example.invalid');
            final keyboardHeight = size.width == 1706
                ? 648.0
                : size.height * .45;
            tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
            await pumpConsentUi(tester);
            final keyboardTop = size.height - keyboardHeight;
            for (var i = 0; i < before.length; i++) {
              // 탭 뒤에는 커서 손잡이가 칸 가운데를 덮을 수 있어 가림 여부는 탭 전에 본다.
              expect(inputs.at(i).hitTestable(), findsOneWidget);
              await tester.tap(inputs.at(i));
              await pumpConsentUi(tester);
              expect(tester.getRect(inputs.at(i)), before[i]);
              expect(
                tester.getRect(inputs.at(i)).bottom,
                lessThan(keyboardTop),
              );
            }
            expect(tester.getRect(server).bottom, lessThan(keyboardTop));
            expect(tester.getRect(submit).bottom, lessThan(keyboardTop));
            expect(tester.getSize(submit), const Size(80, 80));
            expect(submit.hitTestable(), findsOneWidget);
            expect(
              find.descendant(of: submit, matching: find.byType(Text)),
              findsNothing,
            );
            if (signup) {
              final age = find.byKey(const ValueKey('signup-age-check'));
              expect(tester.getCenter(age).dy, tester.getCenter(submit).dy);
              await tester.tap(submit);
              await pumpConsentUi(tester);
              expect(http.requests, isEmpty);
              expect(store.session, isNull);
              await tester.tap(age);
              await pumpConsentUi(tester);
            }
            await tester.tap(submit);
            await pumpConsentUi(tester);
            expect(http.requests, hasLength(1));
            expect(
              http.requests.single.uri.path,
              signup ? '/v1/auth/signup' : '/v1/auth/login',
            );
            if (signup)
              expect(
                jsonDecode(utf8.decode(http.requests.single.body))['over14'],
                isTrue,
              );
            expect(store.token, 'car-auth-token');
            expect(store.baseUrl, 'https://example.invalid');
            await tester.tap(find.byTooltip(signup ? '로그인' : '가입'));
            await pumpConsentUi(tester);
            expect(
              find.byKey(const ValueKey('signup-age-check')),
              signup ? findsNothing : findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            api.close();
            store.dispose();
            appearance.dispose();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }
}
