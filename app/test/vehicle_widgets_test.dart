import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/core/vehicle_state.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/screens/phone/settings.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  for (final mode in DeviceMode.values) {
    testWidgets('$mode 준비 숫자·멤버 아이콘·토글과 이어받음 버튼', (tester) async {
      tester.view.physicalSize = mode == DeviceMode.car
          ? const Size(1706, 1206)
          : const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = await ConsentTestServices.create(tester, mode: mode);
      try {
        await services.openRoom(tester);
        await tester.pumpWidget(
          MaterialApp(
            builder: testIconBuilder,
            theme: unavoTheme(Brightness.dark),
            home: RoomScreen(services: services, mode: mode, embedded: true),
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
        await tester.tap(toggle);
        await pumpConsentUi(tester);
        expect(
          find.descendant(of: summary, matching: find.text('1/2')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('member-ready-bob')), findsOneWidget);
        expect(tester.widget<PanelButton>(toggle).selected, isTrue);
        services.api.events.add(const DeviceReplaced());
        await pumpConsentUi(tester);
        expect(find.text('다른 기기에서 이어받았습니다'), findsWidgets);
        final takeBack = find.byKey(const ValueKey('room-take-back'));
        expect(tester.widget<PanelButton>(takeBack).iconOnly, isTrue);
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
        await tester.pumpWidget(const SizedBox.shrink());
        await services.finish(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('차량 하차 사실 안내와 직접 재개 아이콘은 문을 닫아도 유지된다', (tester) async {
    tester.view.physicalSize = const Size(1706, 1206);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<Object?>.broadcast();
    final services = await ConsentTestServices.create(
      tester,
      mode: DeviceMode.car,
      vehicleEvents: events.stream,
    );
    void door(int position) => events.add({
      'available': true,
      'parked': true,
      'doors': {'ROW_1_LEFT': position},
      'exitDoor': 'ROW_1_LEFT',
    });
    try {
      await services.openRoom(tester);
      await tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          theme: unavoTheme(Brightness.dark),
          home: RoomScreen(
            services: services,
            mode: DeviceMode.car,
            embedded: true,
          ),
        ),
      );
      door(1);
      await pumpConsentUi(tester);
      expect(find.text('내리는 중이라 차량 마이크와 위치 보내기를 멈췄습니다'), findsOneWidget);
      final resume = find.byKey(const ValueKey('room-exit-resume'));
      expect(tester.widget<PanelButton>(resume).iconOnly, isTrue);
      door(0);
      await pumpConsentUi(tester);
      expect(resume, findsOneWidget);
      await tester.tap(resume);
      await pumpConsentUi(tester);
      expect(resume, findsNothing);
      expect(services.rooms.muted, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await services.finish(tester);
      await events.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

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
