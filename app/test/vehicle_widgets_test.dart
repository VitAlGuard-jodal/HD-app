import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/core/vehicle_state.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/screens/phone/settings.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/panel_button.dart';
import 'package:unavo/ui/widgets/status_chip.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  // 2560×1440·160dpi Pleos의 앱 가용 영역은 약 1706×1206dp다.
  for (final (mode, size, embedded) in [
    (DeviceMode.car, const Size(1706, 1206), false),
    (DeviceMode.car, const Size(1320, 940), false),
    (DeviceMode.phone, const Size(412, 915), false),
    (DeviceMode.phone, const Size(320, 568), false),
    // 7:3 지도의 통화 패널 너비도 검사한다(바깥 셸 여백은 이미 소비됨).
    (DeviceMode.car, const Size(381, 940), true),
    (DeviceMode.phone, const Size(274.5, 412), true),
  ]) {
    testWidgets('$mode $size 준비 크기·정렬·강조색·접근성과 이어받음 버튼', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final appearance = AppearanceController();
      addTearDown(appearance.dispose);
      final services = await ConsentTestServices.create(tester, mode: mode);
      final semantics = tester.ensureSemantics();
      try {
        await services.openRoom(tester);
        await tester.pumpWidget(
          UnavoAppearance(
            controller: appearance,
            child: MaterialApp(
              builder: testIconBuilder,
              theme: unavoTheme(Brightness.dark),
              home: RoomScreen(
                services: services,
                mode: mode,
                embedded: embedded,
              ),
            ),
          ),
        );
        await pumpConsentUi(tester);
        final summary = find.byKey(const ValueKey('room-ready-summary'));
        expect(
          find.descendant(of: summary, matching: find.text('0/2')),
          findsOneWidget,
        );
        final toggle = find.byKey(const ValueKey('room-ready-toggle'));
        expect(tester.widget<PanelButton>(toggle).iconOnly, isTrue);
        _expectReadinessLayout(
          tester,
          car: mode == DeviceMode.car,
          inlineStatus: !embedded && size.width >= 412,
        );
        expect(find.bySemanticsLabel('출발 준비 0/2'), findsOneWidget);
        await tester.tap(toggle);
        await pumpConsentUi(tester);
        expect(
          find.descendant(of: summary, matching: find.text('1/2')),
          findsOneWidget,
        );
        final badge = find.byKey(const ValueKey('member-ready-bob'));
        expect(badge, findsOneWidget);
        expect(
          tester.getSize(badge),
          Size.square(mode == DeviceMode.car ? 28 : 18),
        );
        final badgeBackground = find
            .ancestor(of: badge, matching: find.byType(Container))
            .first;
        expect(
          tester.getSize(badgeBackground),
          Size.square(mode == DeviceMode.car ? 36 : 24),
        );
        expect(find.bySemanticsLabel('보비, @bob, 나, 출발 준비됨'), findsOneWidget);
        expect(tester.widget<PanelButton>(toggle).selected, isTrue);
        expect(tester.widget<PanelButton>(toggle).style, PanelButtonStyle.call);
        expect(tester.widget<PanelButton>(toggle).label, '출발 준비 취소');
        expect(
          tester.widget<Text>(find.text('1/2')).style!.color,
          UnavoColors.text,
        );
        services.api.events.add(const ReadyChanged('alice', true, 1));
        await pumpConsentUi(tester);
        expect(find.bySemanticsLabel('출발 준비 2/2'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('2/2')).style!.color,
          UnavoColors.onCall,
        );
        expect(
          tester.widget<UnavoIcon>(_summaryCheck(summary)).color,
          UnavoColors.onCall,
        );
        services.api.events.add(const ReadyChanged('alice', false, 2));
        await pumpConsentUi(tester);
        expect(
          tester.widget<Text>(find.text('1/2')).style!.color,
          UnavoColors.text,
        );
        expect(
          tester.widget<UnavoIcon>(_summaryCheck(summary)).color,
          UnavoColors.text,
        );
        services.api.events.add(const DeviceReplaced());
        await pumpConsentUi(tester);
        expect(find.text('다른 기기에서 이어받았습니다'), findsWidgets);
        final takeBack = find.byKey(const ValueKey('room-take-back'));
        expect(tester.widget<PanelButton>(takeBack).iconOnly, isTrue);
        expect(tester.widget<PanelButton>(takeBack).label, '이 기기에서 다시 참여');
        final banner = find.byKey(const ValueKey('room-vehicle-notice'));
        final notice = find.descendant(
          of: banner,
          matching: find.text('다른 기기에서 이어받았습니다'),
        );
        expect(
          tester.widget<Text>(notice).style!.fontSize,
          mode == DeviceMode.car ? 24 : 18,
        );
        expect(
          tester.getRect(takeBack).right,
          closeTo(tester.getRect(toggle).right, .01),
        );
        _expectDisjoint(tester, [
          find.byKey(const ValueKey('room-vehicle-notice-icon')),
          notice,
          takeBack,
        ]);
        _expectContained(tester, banner, takeBack);
        expect(
          tester.renderObject<RenderParagraph>(notice).didExceedMaxLines,
          isFalse,
        );
        expect(tester.widget<PanelButton>(toggle).onPressed, isNull);
        await tester.tap(takeBack);
        await pumpConsentUi(tester);
        // Keep this UI fixture silent; media resumption is covered by the session test.
        await completeConsentFuture(tester, services.rooms.leaveCall());
        services.api.events.add(Hello('bob', services.api.members));
        await pumpConsentUi(tester);
        expect(find.byKey(const ValueKey('room-take-back')), findsNothing);
        expect(find.byKey(const ValueKey('member-bob')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await services.finish(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final (size, embedded, wasReady) in [
    (const Size(1706, 1206), false, false),
    (const Size(1706, 1206), false, true),
    (const Size(1320, 940), false, false),
    (const Size(381, 940), true, false),
  ]) {
    testWidgets('차량 $size 준비=$wasReady 하차 배너 크기·재개 아이콘과 문 닫힘 유지', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final appearance = AppearanceController();
      addTearDown(appearance.dispose);
      final events = StreamController<Object?>.broadcast();
      final services = await ConsentTestServices.create(
        tester,
        mode: DeviceMode.car,
        vehicleEvents: events.stream,
      );
      final semantics = tester.ensureSemantics();
      void door(int position) => events.add({
        'available': true,
        'parked': true,
        'doors': {'ROW_1_LEFT': position},
        'exitDoor': 'ROW_1_LEFT',
      });
      try {
        await services.openRoom(tester);
        // 화면의 연결 표시는 refresh여도 하차 재개는 play로 구별되어야 한다.
        services.rooms.mediaConnection = MediaConnectionState.connecting;
        await tester.pumpWidget(
          UnavoAppearance(
            controller: appearance,
            child: MaterialApp(
              builder: testIconBuilder,
              theme: unavoTheme(Brightness.dark),
              home: RoomScreen(
                services: services,
                mode: DeviceMode.car,
                embedded: embedded,
              ),
            ),
          ),
        );
        await pumpConsentUi(tester);
        if (wasReady) {
          await tester.tap(find.byKey(const ValueKey('room-ready-toggle')));
          await pumpConsentUi(tester);
        }
        door(1);
        await pumpConsentUi(tester);
        final message =
            '${wasReady ? '준비가 취소됐습니다. ' : ''}'
            '내리는 중이라 차량 마이크와 위치 보내기를 멈췄습니다';
        final notice = find.text(message);
        expect(notice, findsOneWidget);
        final resume = find.byKey(const ValueKey('room-exit-resume'));
        expect(tester.widget<PanelButton>(resume).iconOnly, isTrue);
        expect(tester.widget<PanelButton>(resume).icon, 'player-play');
        final status = find.byKey(const ValueKey('room-connection-status'));
        expect(tester.widget<StatusChip>(status).icon, 'refresh');
        expect(
          tester.widget<PanelButton>(resume).icon,
          isNot(tester.widget<StatusChip>(status).icon),
        );
        expect(find.bySemanticsLabel('차량 마이크와 이전 위치 공유 다시 켜기'), findsOneWidget);
        expect(
          find.descendant(of: resume, matching: find.byType(Text)),
          findsNothing,
        );
        expect(tester.getSize(resume), const Size(80, 80));
        expect(tester.widget<Text>(notice).style!.fontSize, 24);
        expect(
          tester.widget<Text>(notice).style!.fontSize!,
          greaterThanOrEqualTo(
            tester.widget<Text>(find.text('앨리스')).style!.fontSize!,
          ),
        );
        final banner = find.byKey(const ValueKey('room-vehicle-notice'));
        final noticeIcon = find.byKey(
          const ValueKey('room-vehicle-notice-icon'),
        );
        expect(tester.getSize(noticeIcon), const Size(36, 36));
        expect(tester.widget<UnavoIcon>(noticeIcon).name, 'micoff');
        final toggle = find.byKey(const ValueKey('room-ready-toggle'));
        expect(
          tester.getRect(resume).right,
          closeTo(tester.getRect(toggle).right, .01),
        );
        expect(
          tester.getCenter(notice).dy,
          closeTo(tester.getCenter(resume).dy, .01),
        );
        expect(
          tester.getCenter(noticeIcon).dy,
          closeTo(tester.getCenter(resume).dy, .01),
        );
        _expectDisjoint(tester, [noticeIcon, notice, resume]);
        final panel = find.byKey(const ValueKey('room-call-panel'));
        for (final child in [noticeIcon, notice, resume]) {
          _expectContained(tester, banner, child);
          _expectContained(tester, panel, child);
        }
        expect(
          tester.getRect(toggle).bottom,
          lessThan(tester.getRect(banner).top),
        );
        expect(
          tester.getRect(banner).bottom,
          lessThan(
            tester.getRect(find.byKey(const ValueKey('member-alice'))).top,
          ),
        );
        expect(
          tester.getRect(banner).bottom,
          lessThan(
            tester.getRect(find.byKey(const ValueKey('room-controls'))).top,
          ),
        );
        final paragraph = tester.renderObject<RenderParagraph>(notice);
        expect(paragraph.didExceedMaxLines, isFalse);
        final lines = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: message.length),
            )
            .map((box) => box.top)
            .toSet();
        if (embedded) {
          expect(lines.length, greaterThan(1));
        } else {
          expect(lines, hasLength(1));
        }
        expect(tester.takeException(), isNull);
        door(0);
        await pumpConsentUi(tester);
        expect(resume, findsOneWidget);
        await tester.tap(resume);
        await pumpConsentUi(tester);
        expect(resume, findsNothing);
        expect(services.rooms.muted, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await services.finish(tester);
        await events.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('차량 설정의 세 보호 동작은 아이콘으로 선택해 기기에 저장한다', (tester) async {
    tester.view.physicalSize = const Size(1706, 1206);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = await ConsentTestServices.create(
      tester,
      mode: DeviceMode.car,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          theme: unavoTheme(Brightness.dark),
          home: Scaffold(body: SettingsScreen(services: services, car: true)),
        ),
      );
      await pumpConsentUi(tester);
      final menu = find.byKey(const ValueKey('car-settings-menu-exit'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await pumpConsentUi(tester);
      for (final action in ExitProtection.values) {
        final button = find.byKey(ValueKey('settings-exit-${action.name}'));
        expect(tester.widget<PanelButton>(button).iconOnly, isTrue);
        await tester.tap(button);
        await pumpConsentUi(tester);
        expect(services.store.exitProtection, action);
        expect(tester.widget<PanelButton>(button).selected, isTrue);
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await services.finish(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Finder _summaryCheck(Finder summary) => find
    .descendant(
      of: summary,
      matching: find.byWidgetPredicate(
        (w) => w is UnavoIcon && w.name == 'check',
      ),
    )
    .first;

void _expectReadinessLayout(
  WidgetTester tester, {
  required bool car,
  required bool inlineStatus,
}) {
  final summary = find.byKey(const ValueKey('room-ready-summary'));
  final members = find.byKey(const ValueKey('room-member-count'));
  final count = find.descendant(of: summary, matching: find.text('0/2'));
  final check = _summaryCheck(summary);
  final toggle = find.byKey(const ValueKey('room-ready-toggle'));
  final status = find.byKey(const ValueKey('room-connection-status'));
  final panel = find.byKey(const ValueKey('room-call-panel'));
  expect(tester.getSize(toggle), Size.square(car ? 80 : 56));
  expect(tester.getSize(check), Size.square(car ? 36 : 24));
  expect(tester.widget<Text>(count).style!.fontSize, car ? 24 : 18);
  expect(
    tester.widget<Text>(count).style!.fontSize!,
    greaterThanOrEqualTo(
      tester.widget<Text>(find.text('앨리스')).style!.fontSize!,
    ),
  );
  expect(
    tester.getCenter(members).dy,
    closeTo(tester.getCenter(count).dy, .01),
  );
  expect(tester.getCenter(count).dy, closeTo(tester.getCenter(toggle).dy, .01));
  expect(
    tester.getRect(toggle).right,
    closeTo(tester.getRect(summary).right, .01),
  );
  if (inlineStatus) {
    expect(
      tester.getCenter(status).dy,
      closeTo(tester.getCenter(toggle).dy, .01),
    );
  } else {
    expect(
      tester.getRect(status).bottom,
      lessThan(tester.getRect(summary).top),
    );
    expect(
      tester.getCenter(status).dx,
      closeTo(tester.getCenter(toggle).dx, .01),
    );
  }
  final elements = [members, check, count, status, toggle];
  _expectDisjoint(tester, elements);
  for (final child in elements) {
    _expectContained(tester, panel, child);
  }
  expect(
    find.descendant(of: toggle, matching: find.byType(Text)),
    findsNothing,
  );
  expect(tester.takeException(), isNull);
}

void _expectDisjoint(WidgetTester tester, List<Finder> elements) {
  for (var i = 0; i < elements.length; i++) {
    for (var j = i + 1; j < elements.length; j++) {
      expect(
        tester.getRect(elements[i]).overlaps(tester.getRect(elements[j])),
        isFalse,
        reason: '${elements[i]} overlaps ${elements[j]}',
      );
    }
  }
}

void _expectContained(WidgetTester tester, Finder parent, Finder child) {
  final bounds = tester.getRect(parent), rect = tester.getRect(child);
  expect(rect.left, greaterThanOrEqualTo(bounds.left));
  expect(rect.top, greaterThanOrEqualTo(bounds.top));
  expect(rect.right, lessThanOrEqualTo(bounds.right));
  expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
}
