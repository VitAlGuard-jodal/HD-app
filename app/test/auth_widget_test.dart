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

void main() {
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
          theme: unavoTheme(Brightness.dark),
          home: AuthScreen(
            api: ApiClient(tokenStore: store),
            store: store,
            mode: DeviceMode.phone,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('시작'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(HandleRules.help).first);
    await tester.pumpAndSettle();
    expect(find.text(HandleRules.help), findsOneWidget);
    expect(store.session, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
    appearance.dispose();
  });
}
