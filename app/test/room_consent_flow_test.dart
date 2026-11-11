import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/map/vworld_room_map.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/map/room_map.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/floating_bar.dart';
import 'package:unavo/ui/widgets/member_avatar.dart';
import 'package:unavo/ui/widgets/unavo_watermark.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

const _timeout = Timeout(Duration(seconds: 30));

void main() {
  testWidgets('입장은 지도 없는 통화 방, 내 카드는 무동작, 바는 음성·방 관리만 하단 8dp', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      expect(find.byType(RoomMap), findsNothing);
      expect(find.text('우나보'), findsNothing);
      expect(find.byType(UnavoWatermark), findsOneWidget);
      expect(find.byType(MemberAvatar), findsNWidgets(2));
      final bar = find.byKey(const ValueKey('room-controls'));
      final icons = tester
          .widgetList<FloatingBarButton>(
            find.descendant(of: bar, matching: find.byType(FloatingBarButton)),
          )
          .map((button) => button.icon);
      expect(icons, containsAll(['mic', 'exit', 'volume2']));
      expect(
        icons,
        isNot(
          contains(anyOf('focus', 'navigation', 'locationoff', 'location')),
        ),
      );
      expect(tester.getRect(bar).bottom, 907);
      await _member(tester, 'bob');
      expect(find.byType(Dialog), findsNothing);
      expect(f.services.locationSource.requests, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('다른 카드 동의는 start 후 follow POST, 중지 모달은 지도만 닫고 공유 유지', (
    tester,
  ) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      expect(find.text('앨리스 님의 위치를 따라갑니다'), findsOneWidget);
      expect(find.text('내 위치도 같은 방 참여자에게 보입니다'), findsOneWidget);
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
      await _tap(tester, '동의');
      expect(f.services.locationShare.sharing, isTrue);
      expect(f.services.locationSource.watches, 1);
      expect(f.services.api.follows, ['alice']);
      expect(f.services.rooms.followTarget, 'alice');
      expect(find.byType(RoomMap), findsOneWidget);
      await _member(tester, 'alice');
      expect(find.text('따라가기 중지'), findsOneWidget);
      await _tap(tester, '미동의');
      expect(f.services.rooms.followTarget, 'alice');
      await _member(tester, 'alice');
      await _tap(tester, '동의');
      expect(f.services.rooms.followTarget, isNull);
      expect(f.services.locationShare.sharing, isTrue);
      expect(f.services.api.unfollows, 1);
      expect(find.byType(RoomMap), findsNothing);
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      await _tap(tester, '동의');
      expect(f.services.locationSource.watches, 1);
      await _tap(tester, '위치 공유 중지');
      expect(f.services.rooms.followTarget, isNull);
      expect(f.services.locationShare.sharing, isFalse);
      expect(f.services.api.stops, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('미동의 안내 후에는 GPS 요청·follow·지도가 없다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      await _tap(tester, '미동의');
      expect(find.text('동의하지 않아 따라가기 기능을 사용할 수 없습니다'), findsOneWidget);
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
      expect(find.byType(RoomMap), findsNothing);
      await _tap(tester, '닫기');
      expect(find.byType(Dialog), findsNothing);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  for (final permission in [
    LocationPermissionState.denied,
    LocationPermissionState.serviceOff,
  ]) {
    testWidgets('위치 시작 실패 $permission이면 follow를 보내지 않는다', (tester) async {
      final f = await _Fixture.create(tester);
      try {
        f.services.locationSource.permission = permission;
        await _member(tester, 'alice');
        await _tap(tester, '동의');
        expect(f.services.locationShare.sharing, isFalse);
        expect(f.services.api.follows, isEmpty);
        expect(find.byType(RoomMap), findsNothing);
        expect(
          find.text(
            permission == LocationPermissionState.denied
                ? '위치 권한이 없습니다'
                : '위치 서비스가 꺼져 있습니다',
          ),
          findsOneWidget,
        );
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  for (final accepted in [true, false]) {
    testWidgets('follow-request 수신 → ${accepted ? "수락" : "거절"} 응답', (
      tester,
    ) async {
      final f = await _Fixture.create(tester, handle: 'alice');
      try {
        f.services.api.events.add(const FollowRequest('bob'));
        await pumpConsentUi(tester);
        expect(find.text('따라가기 요청'), findsOneWidget);
        expect(find.text('보비 님이 내 위치를 따라가려 합니다'), findsOneWidget);
        await _tap(tester, accepted ? '동의' : '미동의');
        expect(f.services.api.followResponses, [('bob', accepted)]);
        expect(f.services.locationSource.watches, accepted ? 1 : 0);
        expect(find.byType(RoomMap), findsNothing);
        if (accepted) {
          f.services.api.events.add(const FollowRequest('bob'));
          await pumpConsentUi(tester);
          expect(find.byType(Dialog), findsNothing);
          expect(f.services.api.followResponses, [
            ('bob', true),
            ('bob', true),
          ]);
          expect(f.services.locationSource.watches, 1);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  testWidgets('상대 거절은 안내하고 따라가기·지도를 닫는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      await _tap(tester, '동의');
      f.services.api.events.add(const FollowResponse('alice', false));
      await pumpConsentUi(tester);
      expect(find.text('앨리스 님이 위치 공유에 동의하지 않았습니다'), findsOneWidget);
      expect(f.services.rooms.followTarget, isNull);
      expect(find.byType(RoomMap), findsNothing);
      expect(f.services.locationShare.sharing, isTrue);
      await _tap(tester, '닫기');
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('동의 중 방 변경·요청 취소는 이전 동의로 위치를 켜지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      f.services.rooms.state = const RoomState(code: 'OTHER1');
      await _tap(tester, '동의');
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
    } finally {
      await f.dispose(tester);
    }
    final target = await _Fixture.create(tester, handle: 'alice');
    try {
      target.services.api.events.add(const FollowRequest('bob'));
      await pumpConsentUi(tester);
      target.services.api.events.add(const FollowCancelled('bob'));
      await pumpConsentUi(tester);
      await _tap(tester, '동의');
      expect(target.services.locationSource.requests, 0);
      expect(target.services.api.followResponses, isEmpty);
    } finally {
      await target.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('차량은 표본 없는 unknown에서 모달을 열고 동의 후 start·follow POST·지도를 표시한다', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, car: true);
    try {
      expect(f.services.locationShare.motionState, LocationMotionState.unknown);
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      expect(find.text('정차 후 설정할 수 있습니다'), findsNothing);
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
      await _tap(tester, '동의');
      expect(f.services.locationShare.sharing, isTrue);
      expect(f.services.locationSource.requests, 1);
      expect(f.services.locationSource.watches, 1);
      expect(f.services.api.follows, ['alice']);
      expect(f.services.rooms.followTarget, 'alice');
      expect(find.byType(RoomMap), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('차량의 moving 표본은 동의 팝업 전에 정차 오류로 차단한다', (tester) async {
    final f = await _Fixture.create(tester, car: true);
    try {
      await completeConsentFuture(tester, f.services.locationShare.start());
      await _sample(tester, f, speed: .5);
      expect(f.services.locationShare.motionState, LocationMotionState.moving);
      await _member(tester, 'alice');
      expect(find.text('정차 후 설정할 수 있습니다'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(f.services.locationSource.requests, 1);
      expect(f.services.api.follows, isEmpty);
      expect(f.services.rooms.followTarget, isNull);
      expect(find.byType(RoomMap), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('차량은 stationary에서 모달·따라가기를 허용하고 이후 이동에도 유지한다', (tester) async {
    final f = await _Fixture.create(tester, car: true);
    try {
      await completeConsentFuture(tester, f.services.locationShare.start());
      for (var second = 0; second <= 3; second++) {
        if (second > 0) await tester.pump(const Duration(seconds: 1));
        await _sample(tester, f, speed: 0);
      }
      expect(
        f.services.locationShare.motionState,
        LocationMotionState.stationary,
      );
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      await _tap(tester, '동의');
      expect(f.services.api.follows, ['alice']);
      expect(f.services.rooms.followTarget, 'alice');
      expect(f.services.locationSource.watches, 1);
      await _sample(tester, f, speed: 3);
      expect(f.services.rooms.followTarget, 'alice');
      expect(find.byType(RoomMap), findsOneWidget);
      expect(find.text('정차 후 설정할 수 있습니다'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  for (final immediate in [true, false]) {
    testWidgets(
      '차량 동의 후 ${immediate ? "start 중" : "POST 뒤"} 첫 moving 판정은 따라가기만 거부한다',
      (tester) async {
        final f = await _Fixture.create(tester, car: true);
        try {
          if (immediate) {
            f.services.locationSource.initialSample = LocationSample(
              lat: 37,
              lng: 127,
              speed: .5,
              at: tester.binding.clock.now(),
            );
          }
          await _member(tester, 'alice');
          expect(find.text('따라가기'), findsOneWidget);
          expect(f.services.locationSource.requests, 0);
          await _tap(tester, '동의');
          if (!immediate) {
            expect(f.services.rooms.followTarget, 'alice');
            await _sample(tester, f, speed: .5);
          }
          expect(f.services.rooms.followTarget, isNull);
          expect(f.services.rooms.followError, '정차 후 설정할 수 있습니다');
          expect(find.text('정차 후 설정할 수 있습니다'), findsOneWidget);
          expect(find.byType(RoomMap), findsNothing);
          expect(f.services.api.follows, immediate ? isEmpty : ['alice']);
          expect(f.services.api.unfollows, immediate ? 0 : 1);
          expect(f.services.locationShare.sharing, isTrue);
          expect(f.services.locationSource.watches, 1);
          expect(f.services.locationSource.cancellations, 0);
          expect(f.services.api.stops, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await f.dispose(tester);
        }
      },
      timeout: _timeout,
    );
  }

  testWidgets('폰은 이동 중에도 모달·동의·따라가기를 허용한다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await completeConsentFuture(tester, f.services.locationShare.start());
      await _sample(tester, f, speed: 3);
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      await _tap(tester, '동의');
      expect(f.services.rooms.followTarget, 'alice');
      expect(f.services.api.follows, ['alice']);
      expect(find.byType(RoomMap), findsOneWidget);
      expect(find.text('정차 후 설정할 수 있습니다'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  for (final (car, size) in [
    (false, const Size(412, 915)),
    (false, const Size(915, 412)),
    (true, const Size(1320, 940)),
  ]) {
    testWidgets('$car $size 지도:통화 7:3·워터마크 경계·원형 버튼·전체 화면·speaking', (
      tester,
    ) async {
      final f = await _Fixture.create(tester, car: car, size: size);
      try {
        await completeConsentFuture(tester, f.services.locationShare.start());
        f.services.api.events.add(
          Hello(
            'bob',
            f.services.api.members,
            'alice',
            const [],
            const {},
            'alice',
          ),
        );
        await pumpConsentUi(tester);
        final map = find.byType(RoomMap);
        final panel = find.byKey(const ValueKey('room-call-panel'));
        final mapSize = tester.getSize(map), panelSize = tester.getSize(panel);
        if (car || size.width > size.height) {
          expect(mapSize.width / panelSize.width, closeTo(7 / 3, .001));
          expect(mapSize.height, panelSize.height);
        } else {
          expect(mapSize.height / panelSize.height, closeTo(7 / 3, .001));
          expect(mapSize.width, panelSize.width);
        }
        expect(
          find.descendant(of: panel, matching: find.byType(UnavoWatermark)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: map, matching: find.byType(UnavoWatermark)),
          findsNothing,
        );
        expect(find.byType(RoomMapButton), findsNWidgets(4));
        expect(
          tester.getSize(find.byTooltip('방향 정렬')),
          Size.square(car ? 64 : 44),
        );
        expect(
          tester
              .widget<RoomMapButton>(
                find.byWidgetPredicate(
                  (w) => w is RoomMapButton && w.icon == 'expand',
                ),
              )
              .translucent,
          isTrue,
        );
        final mapState = tester.state(find.byType(VworldRoomMap));
        await _tap(tester, '지도 전체 화면');
        expect(tester.state(find.byType(VworldRoomMap)), same(mapState));
        expect(panel, findsNothing);
        expect(find.byType(UnavoWatermark), findsNothing);
        expect(find.byType(RoomMapButton), findsNWidgets(4));
        expect(find.byTooltip('지도 축소'), findsOneWidget);
        expect(find.byKey(const ValueKey('room-controls')), findsOneWidget);
        final expanded = tester.getSize(map);
        expect(
          expanded.width,
          closeTo(
            mapSize.width +
                (car || size.width > size.height ? panelSize.width : 0),
            .001,
          ),
        );
        expect(
          expanded.height,
          closeTo(
            mapSize.height +
                (!car && size.width < size.height ? panelSize.height : 0),
            .001,
          ),
        );
        final speaker = find.byKey(const ValueKey('speaker-alice'));
        expect(tester.getSize(speaker), Size.square(car ? 56 : 40));
        f.services.media.remoteSpeaking?.call('alice', true);
        await pumpConsentUi(tester);
        expect(tester.widget<MemberAvatar>(speaker).speaking, isTrue);
        final glow =
            tester
                    .widget<Container>(
                      find
                          .descendant(
                            of: speaker,
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration!
                as BoxDecoration;
        expect((glow.border! as Border).top.width, 3);
        expect((glow.border! as Border).top.color, UnavoColors.speaking);
        expect(glow.boxShadow, isNotEmpty);
        await _tap(tester, '지도 축소');
        expect(panel, findsOneWidget);
        expect(f.services.rooms.followTarget, 'alice');
        expect(tester.takeException(), isNull);
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  testWidgets('전체 화면도 SafeArea·통화를 유지하고 인디케이터는 최대 6명·내 발화를 따른다', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.resetPadding);
    final f = await _Fixture.create(tester);
    try {
      await completeConsentFuture(tester, f.services.locationShare.start());
      f.services.calls.state = const CallState(
        roomCode: 'ABC123',
        selfHandle: 'bob',
        isActive: true,
      );
      final members = [
        const Member('bob', '보비', '1'),
        const Member('alice', '앨리스', '2'),
        for (var index = 0; index < 6; index++)
          Member('user$index', '참여자$index', '$index'),
      ];
      f.services.api.events.add(
        Hello('bob', members, 'alice', const [], const {}, 'alice'),
      );
      await pumpConsentUi(tester);
      await _tap(tester, '지도 전체 화면');
      expect(
        tester.getRect(find.byType(RoomMap)),
        const Rect.fromLTRB(0, 24, 412, 881),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('room-controls'))).bottom,
        873,
      );
      expect(find.byType(MemberAvatar), findsNWidgets(6));
      expect(f.services.rooms.call.isActive, isTrue);
      f.services.media.localSpeaking?.call(true);
      await pumpConsentUi(tester);
      expect(
        tester
            .widget<MemberAvatar>(find.byKey(const ValueKey('speaker-bob')))
            .speaking,
        isTrue,
      );
      f.services.media.localSpeaking?.call(false);
      await pumpConsentUi(tester);
      expect(
        tester
            .widget<MemberAvatar>(find.byKey(const ValueKey('speaker-bob')))
            .speaking,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('테마·지도 밝기는 플랫폼 밝기를 따르고 수동 버튼은 없다', (tester) async {
    final f = await _Fixture.create(tester);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    try {
      await _member(tester, 'alice');
      await _tap(tester, '동의');
      expect(f.appearance.themeMode, ThemeMode.system);
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await pumpConsentUi(tester);
        expect(
          tester.widget<RoomMap>(find.byType(RoomMap)).brightness,
          brightness,
        );
        expect(
          Theme.of(tester.element(find.byType(RoomMap))).brightness,
          brightness,
        );
        expect(find.byTooltip('낮 테마 보기'), findsNothing);
        expect(find.byTooltip('밤 테마 보기'), findsNothing);
      }
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.byTooltip(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await pumpConsentUi(tester);
}

Future<void> _member(WidgetTester tester, String handle) async {
  final card = find.byKey(ValueKey('member-$handle'));
  await tester.ensureVisible(card);
  await tester.tap(card);
  await pumpConsentUi(tester);
}

Future<void> _sample(
  WidgetTester tester,
  _Fixture fixture, {
  required double speed,
}) async {
  fixture.services.locationSource.add(
    LocationSample(
      lat: 37,
      lng: 127,
      speed: speed,
      at: tester.binding.clock.now(),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class _Fixture {
  _Fixture(this.services);
  final ConsentTestServices services;
  final appearance = AppearanceController();
  static Future<_Fixture> create(
    WidgetTester tester, {
    bool car = false,
    String handle = 'bob',
    Size? size,
  }) async {
    tester.view.physicalSize =
        size ?? (car ? const Size(1320, 940) : const Size(412, 915));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final mode = car ? DeviceMode.car : DeviceMode.phone;
    final services = await ConsentTestServices.create(
      tester,
      mode: mode,
      handle: handle,
    );
    await services.openRoom(tester);
    final f = _Fixture(services);
    await tester.pumpWidget(
      UnavoAppearance(
        controller: f.appearance,
        child: MaterialApp(
          builder: testIconBuilder,
          theme: unavoTheme(Brightness.light),
          darkTheme: unavoTheme(Brightness.dark),
          themeMode: f.appearance.themeMode,
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
