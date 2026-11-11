import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/theme.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  testWidgets('위치 공유를 두 번 켜면 동의 모달도 두 번 열고 끌 때는 열지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      for (var start = 1; start <= 2; start++) {
        await _tap(tester, '위치 공유');
        expect(find.byType(Dialog), findsOneWidget);
        final dialog = find.byType(Dialog);
        expect(
          find.descendant(of: dialog, matching: find.text('앨리스')),
          findsOneWidget,
        );
        expect(find.text('방을 나가거나 위치 공유 아이콘을 다시 누르면 끝납니다'), findsOneWidget);
        expect(find.text('위치는 방이 있는 동안만 서버(국내)에 남습니다'), findsOneWidget);
        expect(f.services.locationSource.requests, start - 1);
        await _tap(tester, '동의');
        expect(f.services.locationShare.sharing, isTrue);
        expect(f.services.locationSource.watches, start);
        expect(find.byType(Dialog), findsNothing);
        await _tap(tester, '위치 공유 중지');
        expect(f.services.locationShare.sharing, isFalse);
        expect(f.services.locationSource.cancellations, start);
        expect(find.byType(Dialog), findsNothing);
      }
      expect(f.services.api.stops, 2);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final feature in ['위치 공유', '그룹장 따라가기']) {
    testWidgets('$feature 미동의는 안내만 표시하고 공유·따라가기를 시작하지 않는다', (tester) async {
      final f = await _Fixture.create(tester);
      try {
        await _tap(tester, feature);
        expect(find.byType(Dialog), findsOneWidget);
        await _tap(tester, '미동의');
        expect(find.text('동의하지 않아 $feature 기능을 사용할 수 없습니다'), findsOneWidget);
        expect(find.byType(Dialog), findsOneWidget);
        expect(f.services.locationSource.requests, 0);
        expect(f.services.locationSource.watches, 0);
        expect(f.services.locationShare.sharing, isFalse);
        expect(f.services.rooms.followLeader, isFalse);
        await _tap(tester, '닫기');
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await f.dispose(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('따라가기는 동의 후 start·follow하고 공유 중 재설정·해제에는 팝업이 없다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _tap(tester, '그룹장 따라가기');
      expect(find.byType(Dialog), findsOneWidget);
      expect(f.services.rooms.followLeader, isFalse);
      expect(f.services.locationSource.requests, 0);
      await _tap(tester, '동의');
      expect(f.services.locationShare.sharing, isTrue);
      expect(f.services.locationSource.watches, 1);
      expect(f.services.rooms.followLeader, isTrue);
      await _tap(tester, '그룹장 따라가기');
      expect(f.services.rooms.followLeader, isFalse);
      expect(f.services.locationShare.sharing, isTrue);
      expect(find.byType(Dialog), findsNothing);
      await _tap(tester, '그룹장 따라가기');
      expect(f.services.rooms.followLeader, isTrue);
      expect(f.services.locationSource.requests, 1);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('권한 거부로 공유 시작에 실패하면 따라가기도 켜지지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    f.services.locationSource.permission = LocationPermissionState.denied;
    try {
      await _tap(tester, '그룹장 따라가기');
      await _tap(tester, '동의');
      expect(f.services.locationSource.requests, 1);
      expect(f.services.locationSource.watches, 0);
      expect(f.services.locationShare.sharing, isFalse);
      expect(f.services.rooms.followLeader, isFalse);
      expect(find.text('위치 권한이 없습니다'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('동의 중 방이 바뀌면 이전 방 동의로 공유를 시작하지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _tap(tester, '위치 공유');
      f.services.rooms.state = const RoomState(code: 'OTHER1');
      await _tap(tester, '동의');
      expect(f.services.locationSource.requests, 0);
      expect(f.services.locationShare.sharing, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('차량은 정차 오류를 팝업보다 먼저 표시하고 공유 모달은 화면 중앙에 뜬다', (tester) async {
    final f = await _Fixture.create(tester, car: true);
    try {
      await _tap(tester, '그룹장 따라가기');
      expect(find.text('정차 후 설정할 수 있습니다'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(f.services.locationSource.requests, 0);
      await _tap(tester, '위치 공유');
      final card = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Material),
      );
      expect(tester.getRect(card.first).center, const Offset(660, 470));
      expect(tester.getSize(card.first).width, 560);
      expect(tester.getSize(find.byTooltip('동의')), const Size(80, 80));
      await _tap(tester, '동의');
      // 정차 창은 기존 세션 테스트에서 검증한다. 표본 없는 공유 중에도 제한 유지.
      await _tap(tester, '그룹장 따라가기');
      expect(f.services.rooms.followLeader, isFalse);
      expect(f.services.rooms.followError, '정차 후 설정할 수 있습니다');
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.byTooltip(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await pumpConsentUi(tester);
}

class _Fixture {
  _Fixture(this.services);
  final ConsentTestServices services;
  final appearance = AppearanceController();

  static Future<_Fixture> create(
    WidgetTester tester, {
    bool car = false,
  }) async {
    tester.view.physicalSize = car
        ? const Size(1320, 940)
        : const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final mode = car ? DeviceMode.car : DeviceMode.phone;
    final services = await ConsentTestServices.create(tester, mode: mode);
    await services.openRoom(tester);
    final f = _Fixture(services);
    await tester.pumpWidget(
      UnavoAppearance(
        controller: f.appearance,
        child: MaterialApp(
          builder: testIconBuilder,
          theme: unavoTheme(Brightness.dark),
          home: RoomScreen(services: services, mode: mode),
        ),
      ),
    );
    await pumpConsentUi(tester);
    return f;
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await services.finish(tester);
    appearance.dispose();
  }
}
