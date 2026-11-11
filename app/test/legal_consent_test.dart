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
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  for (final signup in [false, true]) {
    testWidgets('첫 ${signup ? '회원가입' : '로그인'} 후 두 항목 동의·저장을 거쳐야 방 목록을 연다', (
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
        expect(_acceptButton(tester).onPressed, isNull);
        expect(services.store.preferences.getString(legalConsentKey), isNull);
        await _tapKey(tester, 'legal-check-0');
        expect(_acceptButton(tester).onPressed, isNull);
        await _tapKey(tester, 'legal-check-1');
        expect(_acceptButton(tester).onPressed, isNotNull);
        await _tapKey(tester, 'legal-check-0');
        expect(_acceptButton(tester).onPressed, isNull);
        await _tapKey(tester, 'legal-check-0');
        await _tapKey(tester, 'legal-accept');
        expect(
          services.store.preferences.getString(legalConsentKey),
          legalVersion,
        );
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
      expect(find.text('1. 수집하는 정보'), findsOneWidget);
      expect(
        find.text('• 계정: 로그인 아이디, 비밀번호(서버에는 해시 값만 저장), 표시 이름'),
        findsOneWidget,
      );
      expect(find.text('# 우나보 개인정보 처리방침'), findsNothing);
      await _tapKey(tester, 'legal-expand-0');
      expect(detail, findsNothing);
      await _tapKey(tester, 'legal-expand-1');
      expect(find.byKey(const ValueKey('legal-detail-1')), findsOneWidget);
      expect(find.text('1. 수집하는 위치정보'), findsOneWidget);
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
            expect(
              services.store.preferences.getString(legalConsentKey),
              legalVersion,
            );
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
    try {
      await _mount(tester, services, car: true);
      expect(find.byType(CarShell), findsOneWidget);
      expect(find.byKey(const ValueKey('car-secondary')), findsNothing);
      final primary = find.byKey(const ValueKey('car-primary'));
      expect(
        find.descendant(of: primary, matching: find.text('서비스 이용 동의')),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('legal-accept'))).bottom,
        moreOrLessEquals(tester.getRect(primary).bottom - 20, epsilon: 1),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('legal-accept'))),
        const Size(80, 80),
      );
      await _tapKey(tester, 'legal-decline');
      final card = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Material),
      );
      expect(tester.getRect(card.first).center, const Offset(660, 470));
      expect(tester.getSize(find.byTooltip('닫기')), const Size(80, 80));
      await tester.tap(find.byTooltip('닫기'));
      await pumpConsentUi(tester);
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

PanelButton _acceptButton(WidgetTester tester) =>
    tester.widget<PanelButton>(find.byKey(const ValueKey('legal-accept')));

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
  }
  await tester.tap(find.byTooltip(signup ? '가입하고 시작' : '시작'));
  await pumpConsentUi(tester);
}

Future<void> _mount(
  WidgetTester tester,
  ConsentTestServices services, {
  bool car = false,
}) async {
  tester.view.physicalSize = car ? const Size(1320, 940) : const Size(412, 915);
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
  await tester.pumpWidget(
    DefaultAssetBundle(
      bundle: TestIconBundle(),
      child: UnavoApp(
        services: services,
        mode: car ? DeviceMode.car : DeviceMode.phone,
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
