import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/main.dart';
import 'package:unavo/screens/car/car_shell.dart';
import 'package:unavo/screens/phone/auth.dart';
import 'package:unavo/screens/phone/legal_consent.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/screens/phone/rooms.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/consent_fakes.dart';
import 'support/car_shell_expectations.dart';
import 'support/icon_bundle.dart';

void main() {
  for (final car in [false, true]) {
    testWidgets(
      '${car ? "차량 주 패널" : "360dp 폰"}에서 접힌 문서의 요약 라벨은 굵게·gold이며 줄바꿈한다',
      (tester) async {
        final services = await ConsentTestServices.create(
          tester,
          mode: car ? DeviceMode.car : DeviceMode.phone,
        );
        try {
          await _mount(tester, services, car: car, phoneWidth: 360);
          const labels = [
            ['항목', '목적', '보유', '제공', '거부'],
            ['항목', '제공', '보유', '거부'],
          ];
          for (var document = 0; document < labels.length; document++) {
            expect(
              find.byKey(ValueKey('legal-detail-$document')),
              findsNothing,
            );
            for (var line = 0; line < labels[document].length; line++) {
              final summary = find.byKey(
                ValueKey('legal-summary-$document-$line'),
              );
              await tester.ensureVisible(summary);
              await pumpConsentUi(tester);
              final text = tester.widget<Text>(summary);
              final spans = (text.textSpan! as TextSpan).children!;
              final label = spans.first as TextSpan;
              expect(label.text, '${labels[document][line]}: ');
              expect(label.style!.fontWeight, FontWeight.bold);
              expect(label.style!.color, UnavoColors.gold);
              expect(label.style!.fontSize, UnavoType.body.fontSize);
              expect(text.style, UnavoType.body);
              final rect = tester.getRect(summary);
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(car ? 1320 : 360));
              expect(summary.hitTestable(), findsOneWidget);
            }
          }
          expect(tester.takeException(), isNull);
        } finally {
          await _finish(tester, services);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  for (final location in [false, true]) {
    for (final serverFails in [false, true]) {
      testWidgets(
        '동의는 PUT 1회로 개인정보 3·위치 ${location ? "3" : "생략"}을 보내고 ${serverFails ? "서버 500에도 " : ""}onAccepted를 호출한다',
        (tester) async {
          final services = await ConsentTestServices.create(tester);
          services.api.http.status = serverFails ? 500 : 200;
          var accepted = 0;
          try {
            await _mount(tester, services, onAccepted: () => accepted++);
            await _tapKey(tester, 'legal-check-0');
            if (location) await _tapKey(tester, 'legal-check-1');
            await _tapKey(tester, 'legal-accept');
            final requests = services.api.http.requests;
            expect(requests, hasLength(1));
            expect(requests.single.method, 'PUT');
            expect(requests.single.uri.path, '/v1/me/consent');
            expect(jsonDecode(utf8.decode(requests.single.body)), {
              'privacy': {'version': '3'},
              if (location) 'location': {'version': '3'},
            });
            expect(accepted, 1);
            expect(hasPrivacyConsent(services.store.preferences), isTrue);
            expect(hasLocationConsent(services.store.preferences), location);
            expect(tester.takeException(), isNull);
          } finally {
            await _finish(tester, services);
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }

  testWidgets('M10은 개인정보·위치 버전 3을 저장하고 항목별 버전 2 동의는 다시 받는다', (tester) async {
    final services = await ConsentTestServices.create(
      tester,
      savedVersion: '2',
    );
    try {
      expect(legalVersion, '3');
      expect(locationLegalVersion, '3');
      await _mount(tester, services);
      expect(find.byType(LegalConsentScreen), findsOneWidget);
      await _tapKey(tester, 'legal-check-0');
      await _tapKey(tester, 'legal-accept');
      final saved = jsonDecode(
        services.store.preferences.getString(legalConsentKey)!,
      );
      expect(saved['privacy'], {'accepted': true, 'version': '3'});
      expect(saved['location'], {'accepted': false, 'version': '3'});
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('위치 버전 2 동의는 미동의로 판정하고 재동의하면 버전 3만 갱신한다', (tester) async {
    final services = await ConsentTestServices.create(
      tester,
      savedVersion: legalVersion,
    );
    try {
      final preferences = services.store.preferences;
      expect(hasPrivacyConsent(preferences), isTrue);
      expect(hasLocationConsent(preferences), isFalse);
      await completeConsentFuture(tester, saveLocationConsent(preferences));
      expect(hasPrivacyConsent(preferences), isTrue);
      expect(hasLocationConsent(preferences), isTrue);
      final saved = jsonDecode(preferences.getString(legalConsentKey)!);
      expect(saved['privacy'], {'accepted': true, 'version': '3'});
      expect(saved['location'], {'accepted': true, 'version': '3'});
      expect(services.locationSource.requests, 0);
      expect(services.locationSource.watches, 0);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('16-A 위치 미동의로도 입장하며 두 항목의 여부·문서 버전을 따로 저장한다', (tester) async {
    final services = await ConsentTestServices.create(tester);
    try {
      await _mount(tester, services);
      expect(find.text('개인정보 처리방침 (필수)'), findsOneWidget);
      expect(find.text('위치정보 수집·이용 동의 (선택)'), findsOneWidget);
      await _tapKey(tester, 'legal-check-0');
      _expectAcceptButtonState(tester, enabled: true);
      await _tapKey(tester, 'legal-accept');
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(hasPrivacyConsent(services.store.preferences), isTrue);
      expect(hasLocationConsent(services.store.preferences), isFalse);
      final saved = jsonDecode(
        services.store.preferences.getString(legalConsentKey)!,
      );
      expect(saved['privacy'], {'accepted': true, 'version': '3'});
      expect(saved['location'], {'accepted': false, 'version': '3'});
      expect(services.locationSource.requests, 0);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('이전 단일 버전 문자열은 새 개인정보 동의를 건너뛰지 않는다', (tester) async {
    final services = await ConsentTestServices.create(tester);
    try {
      await completeConsentFuture(
        tester,
        services.store.preferences.setString(legalConsentKey, '1'),
      );
      await _mount(tester, services);
      expect(find.byType(LegalConsentScreen), findsOneWidget);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final signup in [false, true]) {
    testWidgets('첫 ${signup ? '회원가입' : '로그인'} 후 필수 개인정보 동의·저장을 거쳐야 방 목록을 연다', (
      tester,
    ) async {
      final services = await ConsentTestServices.create(
        tester,
        signedIn: false,
      );
      try {
        await _mount(tester, services);
        expect(find.byType(AuthScreen), findsOneWidget);
        await _login(tester, signup: signup);
        expect(services.api.logins, signup ? 0 : 1);
        expect(services.api.signups, signup ? 1 : 0);
        expect(find.byType(LegalConsentScreen), findsOneWidget);
        expect(find.byType(RoomsScreen), findsNothing);
        expect(find.text('서비스 이용 동의'), findsOneWidget);
        _expectAcceptButtonState(tester, enabled: false);
        expect(services.store.preferences.getString(legalConsentKey), isNull);
        await _tapKey(tester, 'legal-check-0');
        _expectAcceptButtonState(tester, enabled: true);
        await _tapKey(tester, 'legal-check-1');
        _expectAcceptButtonState(tester, enabled: true);
        await _tapKey(tester, 'legal-check-0');
        _expectAcceptButtonState(tester, enabled: false);
        await _tapKey(tester, 'legal-check-0');
        _expectAcceptButtonState(tester, enabled: true);
        await _tapKey(tester, 'legal-accept');
        expect(hasPrivacyConsent(services.store.preferences), isTrue);
        expect(find.byType(LegalConsentScreen), findsNothing);
        expect(find.byType(RoomsScreen), findsOneWidget);
        expect(services.locationSource.requests, 0);
        // 설치 단위 동의는 로그아웃·다음 로그인에도 보존한다.
        await completeConsentFuture(tester, services.logout());
        await pumpConsentUi(tester);
        await _login(tester);
        expect(find.byType(RoomsScreen), findsOneWidget);
        expect(find.byType(LegalConsentScreen), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('미동의 세션 복원은 전체 동의 화면과 스크롤 가능한 법률 원문을 표시한다', (tester) async {
    final services = await ConsentTestServices.create(tester);
    try {
      await _mount(tester, services);
      expect(services.api.meReads, 1);
      expect(find.byType(LegalConsentScreen), findsOneWidget);
      expect(find.byType(RoomsScreen), findsNothing);
      await _tapKey(tester, 'legal-expand-0');
      final detail = find.byKey(const ValueKey('legal-detail-0'));
      expect(detail, findsOneWidget);
      expect(
        find.descendant(
          of: detail,
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(find.text('우나보 개인정보 처리방침'), findsOneWidget);
      final privacy = (await tester.runAsync(
        () => rootBundle.loadString('assets/legal/privacy.md'),
      ))!;
      final privacyLines = const LineSplitter().convert(privacy);
      final heading = privacyLines.firstWhere((line) => line.startsWith('## '));
      final bullet = privacyLines.firstWhere((line) => line.startsWith('- '));
      expect(find.text(heading.substring(3)), findsOneWidget);
      expect(find.text('• ${bullet.substring(2)}'), findsOneWidget);
      expect(find.text('# 우나보 개인정보 처리방침'), findsNothing);
      await _tapKey(tester, 'legal-expand-0');
      expect(detail, findsNothing);
      await _tapKey(tester, 'legal-expand-1');
      expect(find.byKey(const ValueKey('legal-detail-1')), findsOneWidget);
      final location = (await tester.runAsync(
        () => rootBundle.loadString('assets/legal/location.md'),
      ))!;
      final locationHeading = const LineSplitter()
          .convert(location)
          .firstWhere((line) => line.startsWith('## '));
      expect(find.text(locationHeading.substring(3)), findsOneWidget);
      expect(_acceptButton(tester).onPressed, isNull);
      await tester.binding.handlePopRoute();
      await pumpConsentUi(tester);
      expect(find.byType(LegalConsentScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final offline in [false, true]) {
    testWidgets('미동의 안내 확인 후 ${offline ? '로그아웃 서버 실패에도 ' : ''}로그인 화면으로 돌아간다', (
      tester,
    ) async {
      final services = await ConsentTestServices.create(tester);
      services.api.logoutFails = offline;
      try {
        await _mount(tester, services);
        await _tapKey(tester, 'legal-decline');
        expect(find.text('동의하지 않아 서비스를 이용할 수 없습니다'), findsOneWidget);
        expect(services.logouts, 0);
        expect(services.store.session, isNotNull);
        await tester.tap(find.byTooltip('닫기'));
        await pumpConsentUi(tester);
        expect(services.logouts, 1);
        expect(services.api.logouts, 1);
        expect(services.store.session, isNull);
        expect(services.store.preferences.getString(legalConsentKey), isNull);
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.byType(LegalConsentScreen), findsNothing);
        expect(find.byType(RoomsScreen), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final current in [true, false]) {
    testWidgets(
      current ? '현재 버전 동의를 저장한 설치는 복원 때 건너뛴다' : '문서 버전이 올라가면 다시 동의한다',
      (tester) async {
        final services = await ConsentTestServices.create(
          tester,
          savedVersion: current
              ? legalVersion
              : '${int.parse(legalVersion) - 1}',
        );
        try {
          await _mount(tester, services);
          expect(services.api.meReads, 1);
          expect(
            find.byType(LegalConsentScreen),
            current ? findsNothing : findsOneWidget,
          );
          expect(
            find.byType(RoomsScreen),
            current ? findsOneWidget : findsNothing,
          );
          if (!current) {
            expect(_acceptButton(tester).onPressed, isNull);
            await _tapKey(tester, 'legal-check-0');
            await _tapKey(tester, 'legal-check-1');
            await _tapKey(tester, 'legal-accept');
            expect(hasPrivacyConsent(services.store.preferences), isTrue);
            expect(find.byType(RoomsScreen), findsOneWidget);
          }
          expect(services.locationSource.requests, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await _finish(tester, services);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets('동의 전 알림의 방 열기는 보류하고 동의 후에만 연다', (tester) async {
    final services = await ConsentTestServices.create(tester);
    try {
      await services.openRoom(tester);
      services.calls.pendingOpenRoom = 'ABC123';
      await _mount(tester, services);
      services.calls.onOpenRoom?.call('ABC123');
      await pumpConsentUi(tester);
      expect(find.byType(LegalConsentScreen), findsOneWidget);
      expect(find.byType(RoomScreen), findsNothing);
      expect(services.calls.pendingOpenRoom, 'ABC123');
      await _tapKey(tester, 'legal-check-0');
      await _tapKey(tester, 'legal-check-1');
      await _tapKey(tester, 'legal-accept');
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(services.calls.pendingOpenRoom, isNull);
      expect(services.locationSource.requests, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('차량 동의 화면은 CarShell 주 패널을 채우며 안내 모달은 중앙에 뜬다', (tester) async {
    final services = await ConsentTestServices.create(
      tester,
      mode: DeviceMode.car,
    );
    final semantics = tester.ensureSemantics();
    try {
      await _mount(tester, services, car: true);
      expectCarShellSemantics(tester, settingsEnabled: false);
      expect(find.semantics.byLabel('서비스 이용 동의'), findsOne);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('legal-accept'))),
        isSemantics(label: '동의', isButton: true, isEnabled: false),
      );
      expect(find.byType(CarShell), findsOneWidget);
      expect(find.byKey(const ValueKey('car-secondary')), findsNothing);
      final primary = find.byKey(const ValueKey('car-primary'));
      expect(
        find.descendant(of: primary, matching: find.text('서비스 이용 동의')),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('legal-accept'))).bottom,
        moreOrLessEquals(tester.getRect(primary).bottom - 24, epsilon: 1),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('legal-accept'))),
        const Size(80, 80),
      );
      final privacy = tester.getRect(
        find.byKey(const ValueKey('car-consent-document-0')),
      );
      final location = tester.getRect(
        find.byKey(const ValueKey('car-consent-document-1')),
      );
      expect(privacy.top, location.top);
      expect(privacy.right + 24, closeTo(location.left, .01));
      expect(privacy.width, location.width);
      expect(
        tester.getRect(find.byKey(const ValueKey('legal-check-0'))).top,
        tester.getRect(find.byKey(const ValueKey('legal-check-1'))).top,
      );
      _expectAcceptButtonState(tester, enabled: false);
      await _tapKey(tester, 'legal-check-0');
      _expectAcceptButtonState(tester, enabled: true);
      await _tapKey(tester, 'legal-check-1');
      _expectAcceptButtonState(tester, enabled: true);
      await _tapKey(tester, 'legal-check-0');
      _expectAcceptButtonState(tester, enabled: false);
      await _tapKey(tester, 'legal-decline');
      // 루트 모달은 주 패널 경계 밖에서 셸 전체의 접근성을 가린다.
      for (final label in ['우나보', 'UNAVO', '설정', '서비스 이용 동의']) {
        expect(find.semantics.byLabel(label), findsNothing);
      }
      expect(find.semantics.byLabel('닫기'), findsOne);
      final card = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Material),
      );
      expect(tester.getRect(card.first).center, const Offset(660, 470));
      expect(tester.getSize(find.byTooltip('닫기')), const Size(80, 80));
      await tester.tap(find.byTooltip('닫기'));
      await pumpConsentUi(tester);
      expect(find.byType(AuthScreen), findsOneWidget);
      expectCarShellSemantics(tester, settingsEnabled: true);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

PanelButton _acceptButton(WidgetTester tester) =>
    tester.widget<PanelButton>(find.byKey(const ValueKey('legal-accept')));

void _expectAcceptButtonState(WidgetTester tester, {required bool enabled}) {
  final accept = find.byKey(const ValueKey('legal-accept'));
  final button = tester.widget<OutlinedButton>(
    find.descendant(of: accept, matching: find.byType(OutlinedButton)),
  );
  final states = <WidgetState>{if (!enabled) WidgetState.disabled};
  final foreground = enabled
      ? UnavoColors.ink
      : UnavoColors.text.withValues(alpha: 0.4);
  expect(_acceptButton(tester).onPressed, enabled ? isNotNull : isNull);
  expect(button.onPressed, enabled ? isNotNull : isNull);
  expect(
    button.style!.backgroundColor!.resolve(states),
    enabled ? UnavoColors.gold : UnavoColors.panel,
  );
  expect(button.style!.foregroundColor!.resolve(states), foreground);
  expect(
    button.style!.side!.resolve(states)!.color,
    enabled ? UnavoColors.gold : foreground,
  );
  expect(
    tester
        .widget<UnavoIcon>(
          find.descendant(of: accept, matching: find.byType(UnavoIcon)),
        )
        .color,
    foreground,
  );
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await pumpConsentUi(tester);
}

Future<void> _login(WidgetTester tester, {bool signup = false}) async {
  if (signup) {
    await tester.tap(find.byTooltip('가입'));
    await tester.pump();
  }
  await tester.enterText(find.byType(TextField).at(0), 'bob');
  await tester.enterText(find.byType(TextField).at(1), 'password123');
  if (signup) {
    await tester.ensureVisible(find.byType(TextField).at(2));
    await tester.enterText(find.byType(TextField).at(2), '보비');
    await _tapKey(tester, 'signup-age-check');
  }
  await tester.tap(find.byTooltip(signup ? '가입하고 시작' : '시작'));
  await pumpConsentUi(tester);
}

Future<void> _mount(
  WidgetTester tester,
  ConsentTestServices services, {
  bool car = false,
  double phoneWidth = 412,
  VoidCallback? onAccepted,
}) async {
  tester.view.physicalSize = car
      ? const Size(1320, 940)
      : Size(phoneWidth, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 실제 제공 문서를 캐시에 올려 rootBundle의 파일 I/O와 UI 전환을 분리한다.
  await tester.runAsync(() async {
    await Future.wait([
      rootBundle.loadString('assets/legal/privacy.md'),
      rootBundle.loadString('assets/legal/location.md'),
    ]);
  });
  final appearance = AppearanceController();
  addTearDown(appearance.dispose);
  await tester.pumpWidget(
    DefaultAssetBundle(
      bundle: TestIconBundle(),
      child: onAccepted == null
          ? UnavoApp(
              services: services,
              mode: car ? DeviceMode.car : DeviceMode.phone,
            )
          : UnavoAppearance(
              controller: appearance,
              child: MaterialApp(
                theme: unavoTheme(Brightness.dark),
                home: LegalConsentScreen(
                  services: services,
                  mode: car ? DeviceMode.car : DeviceMode.phone,
                  onAccepted: onAccepted,
                ),
              ),
            ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 1200));
  await pumpConsentUi(tester);
}

Future<void> _finish(WidgetTester tester, ConsentTestServices services) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await services.finish(tester);
}
