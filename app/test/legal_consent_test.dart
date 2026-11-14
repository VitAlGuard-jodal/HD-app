import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/main.dart';
import 'package:unavo/net/models.dart';
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
  test(
    'v5 consent cannot authorize meeting plans and address search; v6 is required on both documents',
    () {
      const old = ConsentRecord(
        privacy: (version: '5', at: 'now'),
        location: (version: '5', at: 'now'),
      );
      expect(hasPrivacyConsent(old), isFalse);
      expect(hasLocationConsent(old), isFalse);
      expect(hasPrivacyConsent(testConsent()), isTrue);
      expect(hasLocationConsent(testConsent()), isTrue);
    },
  );

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
            ['항목', '목적', '보유', '제공', '경로', '거부'],
            ['항목', '제공', '경로', '계획·검색 보유', '제공처 보유', '보유', '거부'],
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
        '동의는 PUT 1회로 개인정보 6·위치 ${location ? "6" : "생략"}을 보내고 ${serverFails ? "서버 500이면 재시도하고 " : ""}성공 후에만 onAccepted를 호출한다',
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
              'privacy': {'version': '6'},
              if (location) 'location': {'version': '6'},
            });
            expect(accepted, serverFails ? 0 : 1);
            expect(hasPrivacyConsent(services.store.consent), !serverFails);
            expect(
              hasLocationConsent(services.store.consent),
              !serverFails && location,
            );
            expect(
              services.store.preferences.getString('legal.consent.v1'),
              isNull,
            );
            if (serverFails) {
              expect(find.byType(LegalConsentScreen), findsOneWidget);
              expect(find.text('프로필 저장 오류'), findsOneWidget);
              _expectAcceptButtonState(tester, enabled: true);
              services.api.http.status = 200;
              await _tapKey(tester, 'legal-accept');
              expect(accepted, 1);
              expect(requests, hasLength(2));
              expect(find.text('프로필 저장 오류'), findsNothing);
            }
            expect(tester.takeException(), isNull);
          } finally {
            await _finish(tester, services);
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }

  testWidgets('개인정보만 선택해 수락하면 위치 기록 없이 같은 계정 재로그인도 동의 화면을 건너뛴다', (
    tester,
  ) async {
    final services = await ConsentTestServices.create(tester, signedIn: false);
    try {
      await _mount(tester, services);
      await _login(tester);
      expect(find.text('개인정보 처리방침 (필수)'), findsOneWidget);
      expect(find.text('위치정보 수집·이용 동의 (선택)'), findsOneWidget);
      await _tapKey(tester, 'legal-check-0');
      _expectAcceptButtonState(tester, enabled: true);
      await _tapKey(tester, 'legal-accept');
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(hasPrivacyConsent(services.store.consent), isTrue);
      expect(hasLocationConsent(services.store.consent), isFalse);
      expect(services.api.consent?.location, isNull);
      expect(services.store.preferences.getString('legal.consent.v1'), isNull);
      expect(services.locationSource.requests, 0);
      await completeConsentFuture(tester, services.logout());
      await pumpConsentUi(tester);
      expect(find.byType(AuthScreen), findsOneWidget);
      await _login(tester);
      expect(find.byType(LegalConsentScreen), findsNothing);
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(services.store.legalAccepted, isTrue);
      expect(services.store.consent?.privacy?.version, legalVersion);
      expect(services.store.consent?.location, isNull);
      expect(services.api.consent?.location, isNull);
      expect(services.api.meReads, 2);
      expect(services.api.http.requests, hasLength(1));
      expect(jsonDecode(utf8.decode(services.api.http.requests.single.body)), {
        'privacy': {'version': legalVersion},
      });
      expect(services.locationSource.requests, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final oldValue in [
    '1',
    jsonEncode({
      'privacy': {'accepted': true, 'version': legalVersion},
      'location': {'accepted': true, 'version': locationLegalVersion},
    }),
  ]) {
    testWidgets('기기 동의 $oldValue는 서버 동의 없는 계정의 복원을 통과시키지 않는다', (tester) async {
      final services = await ConsentTestServices.create(tester);
      try {
        await completeConsentFuture(
          tester,
          services.store.preferences.setString('legal.consent.v1', oldValue),
        );
        await _mount(tester, services);
        expect(find.byType(LegalConsentScreen), findsOneWidget);
        expect(find.byType(RoomsScreen), findsNothing);
        expect(services.api.http.requests, isEmpty);
        expect(services.api.consent, isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final car in [false, true]) {
    testWidgets(
      '${car ? "차량" : "폰"} 같은 기기에서 A 동의 → B 미동의 → A 재로그인은 계정별로 판정한다',
      (tester) async {
        final services = await ConsentTestServices.create(
          tester,
          signedIn: false,
          mode: car ? DeviceMode.car : DeviceMode.phone,
        );
        try {
          await _mount(tester, services, car: car);
          await _login(tester, handle: 'alice');
          await _tapKey(tester, 'legal-check-0');
          await _tapKey(tester, 'legal-check-1');
          await _tapKey(tester, 'legal-accept');
          expect(find.byType(RoomsScreen), findsOneWidget);
          expect(
            services.api.consents['alice']?.privacy?.version,
            legalVersion,
          );
          final preferences = services.store.preferences;
          await completeConsentFuture(tester, services.logout());
          await pumpConsentUi(tester);
          await _login(tester, handle: 'bob');
          expect(identical(preferences, services.store.preferences), isTrue);
          expect(find.byType(LegalConsentScreen), findsOneWidget);
          expect(find.byType(RoomsScreen), findsNothing);
          expect(services.api.consents['bob'], isNull);
          expect(services.api.http.requests, hasLength(1));
          await completeConsentFuture(tester, services.logout());
          await pumpConsentUi(tester);
          await _login(tester, handle: 'alice');
          expect(find.byType(LegalConsentScreen), findsNothing);
          expect(find.byType(RoomsScreen), findsOneWidget);
          expect(services.api.meReads, 3);
          expect(services.api.http.requests, hasLength(1));
        } finally {
          await _finish(tester, services);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets('수락 PUT이 완료되기 전에는 동의 화면과 중복 제출 방지를 유지한다', (tester) async {
    final services = await ConsentTestServices.create(tester);
    final gate = Completer<void>();
    services.api.consentGate = gate.future;
    try {
      await _mount(tester, services);
      await _tapKey(tester, 'legal-check-0');
      await _tapKey(tester, 'legal-check-1');
      await _tapKey(tester, 'legal-accept');
      expect(find.byType(LegalConsentScreen), findsOneWidget);
      expect(find.byType(RoomsScreen), findsNothing);
      _expectAcceptButtonState(tester, enabled: false);
      expect(services.store.legalAccepted, isFalse);
      gate.complete();
      await pumpConsentUi(tester);
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(services.api.http.requests, hasLength(1));
    } finally {
      if (!gate.isCompleted) gate.complete();
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('A의 늦은 동의 PUT 응답은 전환한 B를 통과시키지 않는다', (tester) async {
    final services = await ConsentTestServices.create(tester, handle: 'alice');
    final gate = Completer<void>();
    services.api.consentGate = gate.future;
    try {
      await _mount(tester, services);
      await _tapKey(tester, 'legal-check-0');
      await _tapKey(tester, 'legal-check-1');
      await _tapKey(tester, 'legal-accept');
      await completeConsentFuture(tester, services.logout());
      await pumpConsentUi(tester);
      await _login(tester);
      gate.complete();
      await pumpConsentUi(tester);
      expect(services.store.handle, 'bob');
      expect(services.store.legalAccepted, isFalse);
      expect(services.store.consent, isNull);
      expect(find.byType(LegalConsentScreen), findsOneWidget);
      expect(find.byType(RoomsScreen), findsNothing);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final restoring in [false, true]) {
    for (final (consent, accepted) in <(ConsentRecord?, bool)>[
      (testConsent(version: '4'), false),
      (const ConsentRecord(privacy: (version: legalVersion, at: 'now')), true),
      (
        const ConsentRecord(
          privacy: (version: legalVersion, at: 'now'),
          location: (version: '2', at: 'now'),
        ),
        true,
      ),
      (
        const ConsentRecord(
          privacy: (version: '2', at: 'now'),
          location: (version: locationLegalVersion, at: 'now'),
        ),
        false,
      ),
      (
        const ConsentRecord(
          location: (version: locationLegalVersion, at: 'now'),
        ),
        false,
      ),
      (null, false),
    ]) {
      testWidgets(
        '${restoring ? "복원" : "로그인"} 시 서버 개인정보 ${consent?.privacy?.version}·위치 ${consent?.location?.version}이면 ${accepted ? "동의 화면 없이 입장한다" : "동의 화면을 표시한다"}',
        (tester) async {
          final services = await ConsentTestServices.create(
            tester,
            signedIn: restoring,
          );
          services.api.consents['bob'] = consent;
          try {
            await _mount(tester, services);
            if (!restoring) await _login(tester);
            expect(
              find.byType(LegalConsentScreen),
              accepted ? findsNothing : findsOneWidget,
            );
            expect(
              find.byType(RoomsScreen),
              accepted ? findsOneWidget : findsNothing,
            );
            expect(services.store.consentLoaded, isTrue);
            expect(services.store.legalAccepted, accepted);
            expect(services.api.meReads, 1);
            expect(services.api.http.requests, isEmpty);
            expect(services.locationSource.requests, 0);
            expect(tester.takeException(), isNull);
          } finally {
            await _finish(tester, services);
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }

  testWidgets('로그인 뒤 GET을 기다리는 동안 입장하지 않고 현재 서버 동의 확인 후 건너뛴다', (tester) async {
    final services = await ConsentTestServices.create(tester, signedIn: false);
    services.api.consents['bob'] = testConsent();
    final gate = Completer<void>();
    services.api.meGate = gate.future;
    try {
      await _mount(tester, services);
      await _login(tester);
      expect(find.byType(LegalConsentCheckScreen), findsOneWidget);
      expect(find.byType(RoomsScreen), findsNothing);
      expect(find.byType(LegalConsentScreen), findsNothing);
      gate.complete();
      await pumpConsentUi(tester);
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(find.byType(LegalConsentScreen), findsNothing);
      expect(services.api.http.requests, isEmpty);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await _finish(tester, services);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('오프라인 복원은 기기 동의로 입장하지 않고 조회 오류 뒤 재시도할 수 있다', (tester) async {
    final services = await ConsentTestServices.create(
      tester,
      savedVersion: legalVersion,
    );
    services.api.meError = TimeoutException('offline');
    try {
      await _mount(tester, services);
      for (final seconds in [2, 5, 15]) {
        await tester.pump(Duration(seconds: seconds));
        await pumpConsentUi(tester);
      }
      expect(find.byType(RoomsScreen), findsNothing);
      expect(find.text('동의 내역을 확인하지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
      expect(services.api.http.requests, isEmpty);
      expect(services.store.token, 'test');
      services.api.meError = null;
      services.api.consent = testConsent();
      await _tapKey(tester, 'legal-retry');
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(find.byType(LegalConsentScreen), findsNothing);
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
        expect(
          services.store.preferences.getString('legal.consent.v1'),
          isNull,
        );
        await _tapKey(tester, 'legal-check-0');
        _expectAcceptButtonState(tester, enabled: true);
        await _tapKey(tester, 'legal-check-1');
        _expectAcceptButtonState(tester, enabled: true);
        await _tapKey(tester, 'legal-check-0');
        _expectAcceptButtonState(tester, enabled: false);
        await _tapKey(tester, 'legal-check-0');
        _expectAcceptButtonState(tester, enabled: true);
        await _tapKey(tester, 'legal-accept');
        expect(hasPrivacyConsent(services.store.consent), isTrue);
        expect(find.byType(LegalConsentScreen), findsNothing);
        expect(find.byType(RoomsScreen), findsOneWidget);
        expect(services.locationSource.requests, 0);
        // 같은 계정의 서버 동의는 다음 로그인에서 다시 조회한다.
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
        expect(
          services.store.preferences.getString('legal.consent.v1'),
          isNull,
        );
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
      current ? '현재 서버 동의가 있는 계정은 복원 때 건너뛴다' : '서버 문서 버전이 오래되면 다시 동의한다',
      (tester) async {
        final services = await ConsentTestServices.create(
          tester,
          serverVersion: current
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
            expect(hasPrivacyConsent(services.store.consent), isTrue);
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

Future<void> _login(
  WidgetTester tester, {
  bool signup = false,
  String handle = 'bob',
}) async {
  if (signup) {
    await tester.tap(find.byTooltip('가입'));
    await tester.pump();
  }
  await tester.enterText(find.byType(TextField).at(0), handle);
  await tester.enterText(find.byType(TextField).at(1), 'password123');
  if (signup) {
    await tester.ensureVisible(find.byType(TextField).at(2));
    await tester.enterText(find.byType(TextField).at(2), '보비');
    await _tapKey(tester, 'signup-age-check');
  }
  await tester.pump();
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
