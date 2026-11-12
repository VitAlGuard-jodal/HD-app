import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/main.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/phone/auth.dart';
import 'package:unavo/screens/phone/legal_consent.dart';
import 'package:unavo/screens/phone/map_credits.dart';
import 'package:unavo/screens/phone/mic.dart';
import 'package:unavo/screens/phone/profile.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/screens/phone/rooms.dart';
import 'package:unavo/screens/phone/settings.dart';
import 'package:unavo/ui/widgets/floating_bar.dart';
import 'package:unavo/ui/widgets/mic_level.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

const _timeout = Timeout(Duration(seconds: 30));
const _settingKeys = [
  'settings-profile',
  'settings-volume',
  'settings-mic',
  'settings-server',
  'settings-legal',
  'settings-map',
  'settings-logout',
];

void main() {
  for (final car in [false, true]) {
    testWidgets('${car ? '차량' : '폰'} 바 가운데 홈과 좁은 바의 가로 스크롤', (tester) async {
      final services = await ConsentTestServices.create(tester);
      var homeTaps = 0;
      services.rooms.state = const RoomState(code: 'ABC123', isConnected: true);
      // 폰은 재연결 버튼 때문에 좌우 버튼 수가 다른 경우도 확인한다.
      services.rooms.mediaConnection = MediaConnectionState.failed;
      try {
        for (final width in [600.0, 200.0]) {
          await tester.pumpWidget(
            MaterialApp(
              builder: testIconBuilder,
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    child: RoomScreen(
                      services: services,
                      mode: car ? DeviceMode.car : DeviceMode.phone,
                      embedded: true,
                      onHome: () => homeTaps++,
                    ),
                  ),
                ),
              ),
            ),
          );
          await pumpConsentUi(tester);
          final bar = find.byKey(const ValueKey('room-controls'));
          final home = find.byKey(const ValueKey('room-home'));
          final scrollable = tester.state<ScrollableState>(
            find.descendant(of: bar, matching: find.byType(Scrollable)),
          );
          expect(tester.widget<FloatingBarButton>(home).icon, 'home');
          if (width == 600) {
            expect(scrollable.position.maxScrollExtent, 0);
            expect(
              tester.getCenter(home).dx,
              closeTo(tester.getCenter(bar).dx, .01),
            );
          } else {
            expect(scrollable.position.maxScrollExtent, greaterThan(0));
          }
          await tester.ensureVisible(home);
          await tester.tap(home);
          await tester.ensureVisible(find.byTooltip('방 나가기'));
          expect(find.byTooltip('방 나가기').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        expect(homeTaps, 2);
        expect(services.rooms.state.code, 'ABC123');
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);

    testWidgets('${car ? '차량' : '폰'} 홈 이동·복귀 카드는 방과 통화를 유지한다', (tester) async {
      final services = await _mountApp(tester, car: car);
      try {
        if (!car) await _tapKey(tester, 'current-room-card');
        expect(find.byType(RoomScreen), findsOneWidget);
        final room = services.rooms.state;
        final call = services.calls.state;
        Element? companion;
        State? microphone;
        if (car) {
          companion = tester.element(_secondary);
          await tester.tap(
            find.descendant(of: _secondary, matching: find.byTooltip('마이크')),
          );
          await _pumpNavigation(tester);
          microphone = tester.state(_companionMic);
        }

        await _tapKey(tester, 'room-home');
        expect(find.byType(RoomScreen), findsNothing);
        expect(find.byType(RoomsScreen), findsOneWidget);
        expect(find.byKey(const ValueKey('current-room-card')), findsOneWidget);
        expect(find.byTooltip('통화 중'), findsOneWidget);
        expect(services.rooms.state, same(room));
        expect(services.calls.state, same(call));
        _expectLobbyOnly();
        if (car) {
          expect(tester.element(_secondary), same(companion));
          expect(tester.state(_companionMic), same(microphone));
          expect(
            find.descendant(of: _secondary, matching: find.byType(FloatingBar)),
            findsOneWidget,
          );
        }

        await _tapKey(tester, 'current-room-card');
        expect(find.byType(RoomScreen), findsOneWidget);
        expect(services.rooms.state.code, 'ABC123');
        expect(services.calls.state, same(call));
        if (car) expect(tester.state(_companionMic), same(microphone));
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);

    testWidgets('${car ? '차량' : '폰'} 설정 7항목과 프로필·마이크·문서·출처 왕복', (tester) async {
      final services = await _mountApp(tester, car: car);
      try {
        final room = services.rooms.state;
        final call = services.calls.state;
        final consent = services.store.preferences.getString(
          'legal.consent.v1',
        );
        Element? companion;
        State? microphone;
        if (car) {
          // 통화방에서 바로 톱니바퀴를 열어도 보조 패널은 살아 있어야 한다.
          expect(find.byType(RoomScreen), findsOneWidget);
          companion = tester.element(_secondary);
          await tester.tap(
            find.descendant(of: _secondary, matching: find.byTooltip('마이크')),
          );
          await _pumpNavigation(tester);
          microphone = tester.state(_companionMic);
        } else {
          _expectLobbyOnly();
        }

        await _tapKey(tester, 'open-settings');
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(find.byType(RoomScreen), findsNothing);
        var previousY = double.negativeInfinity;
        for (final key in _settingKeys) {
          final item = find.byKey(ValueKey(key));
          expect(item, findsOneWidget);
          final y = tester.getTopLeft(item).dy;
          expect(y, greaterThan(previousY));
          previousY = y;
        }
        expect(find.text(services.store.baseUrl), findsOneWidget);
        for (final button in tester.widgetList<PanelButton>(
          find.descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(PanelButton),
          ),
        )) {
          expect(button.iconOnly, isTrue);
        }

        void expectCompanion() {
          if (!car) return;
          expect(tester.element(_secondary), same(companion));
          expect(tester.state(_companionMic), same(microphone));
          expect(
            find.descendant(of: _secondary, matching: find.byType(MicLevel)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: _secondary, matching: find.byType(FloatingBar)),
            findsOneWidget,
          );
        }

        void expectPrimary(Type screen) {
          if (!car) return;
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('car-primary')),
              matching: find.byType(screen),
            ),
            findsOneWidget,
          );
          expectCompanion();
        }

        expectPrimary(SettingsScreen);
        await _tapKey(tester, 'settings-profile');
        expect(find.byType(ProfileScreen), findsOneWidget);
        expectPrimary(ProfileScreen);
        expect(
          tester.getSize(find.byKey(const ValueKey('profile-back'))).height,
          car ? 80 : 56,
        );
        expect(find.byKey(const ValueKey('profile-gallery')), findsNothing);
        expect(find.byKey(const ValueKey('profile-edit-badge')), findsOneWidget);
        await _tapKey(tester, 'profile-edit');
        expect(
          find.byKey(const ValueKey('profile-source-dialog')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('profile-gallery')), findsOneWidget);
        expect(tester.getSize(find.byTooltip('닫기')).height, car ? 80 : 56);
        expectPrimary(ProfileScreen);
        await tester.tap(find.byTooltip('닫기'));
        await _pumpNavigation(tester);
        expect(
          find.byKey(const ValueKey('profile-source-dialog')),
          findsNothing,
        );
        expectPrimary(ProfileScreen);
        await _tapKey(tester, 'profile-back');
        expect(find.byType(SettingsScreen), findsOneWidget);

        await _tapKey(tester, 'settings-mic');
        expect(find.byType(MicScreen), car ? findsNWidgets(2) : findsOneWidget);
        expectPrimary(MicScreen);
        await _tapKey(tester, 'settings-mic-back');

        await _tapKey(tester, 'settings-legal');
        expectPrimary(LegalDocumentsScreen);
        expect(find.text('우나보 개인정보 처리방침'), findsOneWidget);
        await _tapKey(tester, 'legal-document-1');
        expect(find.text('위치정보 수집·이용 동의'), findsOneWidget);
        expect(find.byKey(const ValueKey('legal-accept')), findsNothing);
        await _tapKey(tester, 'legal-documents-back');
        expect(
          services.store.preferences.getString('legal.consent.v1'),
          consent,
        );

        await _tapKey(tester, 'settings-map');
        expect(find.byType(MapCreditsScreen), findsOneWidget);
        expectPrimary(MapCreditsScreen);
        await tester.tap(
          find.descendant(
            of: find.byType(MapCreditsScreen),
            matching: find.byTooltip('뒤로'),
          ),
        );
        await _pumpNavigation(tester);
        await _tapKey(tester, 'settings-back');
        expect(find.byType(SettingsScreen), findsNothing);
        expect(find.byType(RoomsScreen), findsOneWidget);
        expect(find.byType(RoomScreen), findsNothing);
        expectCompanion();
        _expectLobbyOnly();
        expect(services.rooms.state, same(room));
        expect(services.calls.state, same(call));

        await _tapKey(tester, 'current-room-card');
        expect(find.byType(RoomScreen), findsOneWidget);
        expect(services.rooms.state.code, 'ABC123');
        expect(services.calls.state.isActive, isTrue);
        expectCompanion();
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);

    testWidgets('${car ? '차량' : '폰'} 설정 음량은 방 슬라이더와 저장값을 공유한다', (tester) async {
      final services = await _mountApp(tester, car: car);
      try {
        await _tapKey(tester, 'open-settings');
        final slider = find.byKey(
          const ValueKey('settings-call-volume-slider'),
        );
        expect(tester.widget<Slider>(slider).max, 100);
        tester.widget<Slider>(slider).onChanged!(37);
        await pumpConsentUi(tester);
        expect(services.rooms.callVolume, 37);
        expect(services.store.callVolume, 37);
        expect(tester.widget<Slider>(slider).value, 37);
        await _tapKey(tester, 'settings-back');
        await _tapKey(tester, 'current-room-card');
        await tester.tap(find.byTooltip('통화 음량 37%'));
        await tester.pump();
        expect(
          tester
              .widget<Slider>(find.byKey(const ValueKey('call-volume-slider')))
              .value,
          37,
        );
        expect(find.byKey(const ValueKey('room-home')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);

    testWidgets('${car ? '차량' : '폰'} 서버 설정은 기존 인증 화면의 주소 편집만 사용한다', (
      tester,
    ) async {
      final services = await _mountApp(tester, car: car);
      try {
        final call = services.calls.state;
        await _tapKey(tester, 'open-settings');
        final server = find.descendant(
          of: find.byKey(const ValueKey('settings-server')),
          matching: find.byType(PanelButton),
        );
        await tester.ensureVisible(server);
        await tester.tap(server);
        await _pumpNavigation(tester);
        expect(
          tester.widget<AuthScreen>(find.byType(AuthScreen)).serverSettingsOnly,
          isTrue,
        );
        // 차량은 보조 패널의 친구 아이디 입력칸이 함께 보이므로 인증 화면 안으로 좁힌다.
        final serverField = find.descendant(
          of: find.byType(AuthScreen),
          matching: find.byType(TextField),
        );
        expect(serverField, findsOneWidget);
        expect(
          tester.widget<TextField>(serverField).controller!.text,
          services.store.baseUrl,
        );
        if (car) {
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('car-primary')),
              matching: find.byType(AuthScreen),
            ),
            findsOneWidget,
          );
          expect(_secondary, findsOneWidget);
        }
        await tester.enterText(serverField, 'ftp://example.invalid');
        await _tapKey(tester, 'server-settings-save');
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(services.store.baseUrl, 'https://example.invalid');
        await tester.enterText(serverField, 'https://new.example.invalid/');
        await _tapKey(tester, 'server-settings-save');
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(services.store.baseUrl, 'https://new.example.invalid');
        expect(find.text(services.store.baseUrl), findsOneWidget);
        expect(services.api.logins, 0);
        expect(services.api.signups, 0);
        expect(services.rooms.state.code, 'ABC123');
        expect(services.calls.state, same(call));
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);

    testWidgets('${car ? '차량' : '폰'} 설정 로그아웃은 기존 오류·세션 정리 경로를 쓴다', (
      tester,
    ) async {
      final services = await _mountApp(tester, car: car);
      try {
        await _tapKey(tester, 'open-settings');
        services.api.logoutFails = true;
        await _tapKey(tester, 'settings-logout');
        expect(services.api.logouts, 1);
        expect(services.store.session, isNotNull);
        expect(services.rooms.state.code, 'ABC123');
        expect(find.text('연결 실패'), findsOneWidget);

        services.api.logoutFails = false;
        await _tapKey(tester, 'settings-logout');
        expect(services.api.logouts, 2);
        expect(services.store.session, isNull);
        expect(services.rooms.state.code, isNull);
        expect(services.calls.state.isActive, isFalse);
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.byType(SettingsScreen), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);
  }

  testWidgets('차량 시스템 뒤로는 프로필·설정·로비 순으로 주 패널만 바꾼다', (tester) async {
    final services = await _mountApp(tester, car: true);
    try {
      final companion = tester.element(_secondary);
      await _tapKey(tester, 'open-settings');
      await _tapKey(tester, 'settings-profile');
      await tester.binding.handlePopRoute();
      await _pumpNavigation(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(ProfileScreen), findsNothing);
      await tester.binding.handlePopRoute();
      await _pumpNavigation(tester);
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(tester.element(_secondary), same(companion));
      expect(services.rooms.state.code, 'ABC123');
      expect(services.calls.state.isActive, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: _timeout);

  for (final fromSettings in [false, true]) {
    testWidgets('폰 ${fromSettings ? '프로필' : '친구 탭'}에서 알림으로 연 방도 홈은 로비로 돌아간다', (
      tester,
    ) async {
      final services = await _mountApp(tester);
      try {
        if (fromSettings) {
          await _tapKey(tester, 'open-settings');
          await _tapKey(tester, 'settings-profile');
        } else {
          await tester.tap(find.byTooltip('친구'));
          await _pumpNavigation(tester);
        }
        services.calls.onOpenRoom!('ABC123');
        await _pumpNavigation(tester);
        expect(find.byType(RoomScreen), findsOneWidget);
        await _tapKey(tester, 'room-home');
        expect(find.byType(RoomsScreen), findsOneWidget);
        expect(find.byType(ProfileScreen), findsNothing);
        expect(find.byType(SettingsScreen), findsNothing);
        expect(services.rooms.state.code, 'ABC123');
        expect(services.calls.state.isActive, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);
  }
}

Finder get _secondary => find.byKey(const ValueKey('car-secondary'));
Finder get _companionMic =>
    find.descendant(of: _secondary, matching: find.byType(MicScreen));

void _expectLobbyOnly() {
  expect(find.byType(RoomsScreen), findsOneWidget);
  expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
  for (final label in ['프로필', '내 프로필 편집', '로그아웃', '지도 출처']) {
    expect(find.byTooltip(label), findsNothing);
  }
}

Future<void> _pumpNavigation(WidgetTester tester) async {
  await pumpConsentUi(tester);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _pumpNavigation(tester);
}

Future<ConsentTestServices> _mountApp(
  WidgetTester tester, {
  bool car = false,
}) async {
  tester.view.physicalSize = car ? const Size(1320, 940) : const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    MicRouter.channel,
    (_) async => {'microphone': true, 'notifications': true},
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MicRouter.channel,
      null,
    ),
  );
  final services = await ConsentTestServices.create(
    tester,
    savedVersion: legalVersion,
    mode: car ? DeviceMode.car : DeviceMode.phone,
  );
  services.rooms.state = RoomState(
    code: 'ABC123',
    room: const Room('ABC123', '함께 가는 길'),
    isConnected: true,
    members: services.api.members,
  );
  services.rooms.mediaConnection = MediaConnectionState.connected;
  services.calls.state = const CallState(
    roomCode: 'ABC123',
    selfHandle: 'bob',
    isActive: true,
  );
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
  await _pumpNavigation(tester);
  return services;
}

Future<void> _finish(WidgetTester tester, ConsentTestServices services) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await services.finish(tester);
}
