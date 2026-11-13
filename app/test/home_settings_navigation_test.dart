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
import 'package:unavo/screens/phone/friends.dart';
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
    testWidgets('${car ? '차량은 모든 버튼을 표시' : '폰은 가운데 홈과 좁은 바 스크롤'}', (
      tester,
    ) async {
      final services = await ConsentTestServices.create(tester);
      var homeTaps = 0;
      services.rooms.state = const RoomState(code: 'ABC123', isConnected: true);
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
          final scrollables = find.descendant(
            of: bar,
            matching: find.byType(Scrollable),
          );
          expect(tester.widget<FloatingBarButton>(home).icon, 'home');
          if (car) {
            expect(scrollables, findsNothing);
            final buttons = find.descendant(
              of: bar,
              matching: find.byType(FloatingBarButton),
            );
            expect(buttons, findsNWidgets(4));
            final bounds = tester.getRect(bar);
            for (var i = 0; i < 4; i++) {
              final rect = tester.getRect(buttons.at(i));
              expect(tester.getSize(buttons.at(i)), const Size(80, 80));
              expect(bounds.contains(rect.topLeft), isTrue);
              expect(bounds.contains(rect.bottomRight), isTrue);
              expect(buttons.at(i).hitTestable(), findsOneWidget);
            }
          } else {
            final scrollable = tester.state<ScrollableState>(scrollables);
            expect(
              scrollable.position.maxScrollExtent,
              width == 600 ? 0 : greaterThan(0),
            );
            if (width == 600) {
              expect(
                tester.getCenter(home).dx,
                closeTo(tester.getCenter(bar).dx, .01),
              );
            }
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
        if (car)
          expect(find.byKey(const ValueKey('open-settings')), findsNothing);
        await _tapKey(tester, 'room-home');
        _expectLobbyOnly();
        expect(find.byType(RoomScreen), findsNothing);
        expect(find.byKey(const ValueKey('current-room-card')), findsOneWidget);
        expect(find.byTooltip('통화 중'), findsOneWidget);
        expect(services.rooms.state, same(room));
        expect(services.calls.state, same(call));
        expect(_secondary, findsNothing);
        if (car) {
          final create = tester.getRect(
            find.byKey(const ValueKey('car-lobby-create')),
          );
          final active = tester.getRect(
            find.byKey(const ValueKey('car-lobby-active')),
          );
          expect(create.right + 24, closeTo(active.left, .01));
          expect(create.top, active.top);
          expect(find.text(joinedRoomReason), findsOneWidget);
          final primary = tester.getRect(
            find.byKey(const ValueKey('car-primary')),
          );
          expect(primary.width, closeTo(1706 - 48, .01));
          final settings = tester.getRect(
            find.byKey(const ValueKey('open-settings')),
          );
          expect(settings.right, primary.right);
          expect(settings.bottom, lessThan(primary.top));
          expect(find.byType(FriendsScreen), findsNothing);
          expect(find.byType(MicLevel), findsNothing);
        }
        await _tapKey(tester, 'current-room-card');
        expect(find.byType(RoomScreen), findsOneWidget);
        expect(services.rooms.state.code, 'ABC123');
        expect(services.calls.state, same(call));
        expect(_secondary, findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);

    testWidgets('${car ? '차량 설정 2단·9항목' : '폰 설정 7항목'}과 프로필·마이크·문서·출처', (
      tester,
    ) async {
      final services = await _mountApp(tester, car: car);
      try {
        final room = services.rooms.state;
        final call = services.calls.state;
        final consent = services.store.preferences.getString(
          'legal.consent.v1',
        );
        await _openSettings(tester);
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(find.byType(RoomScreen), findsNothing);
        var previousY = double.negativeInfinity;
        final keys = car
            ? [
                for (final name in [
                  'profile',
                  'friends',
                  'mic',
                  'volume',
                  'server',
                  'terms',
                  'consent',
                  'map',
                  'logout',
                ])
                  'car-settings-menu-$name',
              ]
            : _settingKeys;
        for (final key in keys) {
          final item = find.byKey(ValueKey(key));
          expect(item, findsOneWidget);
          final y = tester.getTopLeft(item).dy;
          expect(y, greaterThan(previousY));
          previousY = y;
        }
        for (final button in tester.widgetList<PanelButton>(
          find.descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(PanelButton),
          ),
        )) {
          expect(button.iconOnly, isTrue);
        }
        if (car) {
          final menu = find.byKey(const ValueKey('car-settings-menu-profile'));
          expect(
            tester
                .widget<PanelButton>(
                  find.descendant(of: menu, matching: find.byType(PanelButton)),
                )
                .selected,
            isTrue,
          );
          expect(find.byType(ProfileScreen), findsOneWidget);
          expect(
            tester.getRect(menu).right,
            lessThan(tester.getRect(_detail).left),
          );
        } else {
          expect(find.text(services.store.baseUrl), findsOneWidget);
          await _tapKey(tester, 'settings-profile');
        }
        expect(find.byType(ProfileScreen), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('profile-back'))).height,
          car ? 80 : 56,
        );
        expect(find.byKey(const ValueKey('profile-gallery')), findsNothing);
        expect(
          find.byKey(const ValueKey('profile-edit-badge')),
          findsOneWidget,
        );
        final profileNavigator = Navigator.of(
          tester.element(find.byType(ProfileScreen)),
        );
        await _tapKey(tester, 'profile-edit');
        final dialog = find.byKey(const ValueKey('profile-source-dialog'));
        final sourcePage = find.byKey(const ValueKey('profile-source-page'));
        expect(find.byKey(const ValueKey('profile-gallery')), findsOneWidget);
        if (car) {
          expect(dialog, findsOneWidget);
          expect(sourcePage, findsNothing);
          expect(tester.getSize(find.byTooltip('닫기')).height, 80);
          final primaryNavigator = find.descendant(
            of: find.byKey(const ValueKey('car-primary')),
            matching: find.byType(Navigator),
          );
          expect(primaryNavigator, findsOneWidget);
          final primaryRect = tester.getRect(primaryNavigator);
          final dialogCard = find
              .descendant(of: dialog, matching: find.byType(Material))
              .first;
          expect(
            tester.getCenter(dialogCard).dx,
            closeTo(primaryRect.center.dx, .01),
          );
          final barrier = find.descendant(
            of: primaryNavigator,
            matching: find.byWidgetPredicate(
              (w) => w is ModalBarrier && w.color != null,
            ),
          );
          expect(barrier, findsOneWidget);
          expect(tester.getRect(barrier), primaryRect);
          expect(Navigator.of(tester.element(dialog)), same(profileNavigator));
          await tester.tap(find.byTooltip('닫기'));
          await _pumpNavigation(tester);
          await _tapKey(tester, 'car-settings-menu-friends');
          expect(find.byType(FriendsScreen), findsOneWidget);
          expect(
            find.descendant(of: _detail, matching: find.byType(FriendsScreen)),
            findsOneWidget,
          );
          expect(find.byTooltip('친구 추가'), findsOneWidget);
          expect(find.byTooltip('목록 새로고침'), findsOneWidget);
        } else {
          expect(sourcePage, findsOneWidget);
          expect(dialog, findsNothing);
          expect(
            Navigator.of(tester.element(sourcePage)),
            same(profileNavigator),
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('profile-source-back')))
                .height,
            56,
          );
          await _tapKey(tester, 'profile-source-back');
          await _tapKey(tester, 'profile-back');
        }
        await _tapKey(tester, 'settings-mic');
        expect(find.byType(MicScreen), findsOneWidget);
        expect(find.byType(MicLevel), findsOneWidget);
        if (car) {
          expect(
            find.descendant(of: _detail, matching: find.byType(MicScreen)),
            findsOneWidget,
          );
        } else {
          await _tapKey(tester, 'settings-mic-back');
        }
        await _tapKey(tester, 'settings-legal');
        expect(find.byType(LegalDocumentsScreen), findsOneWidget);
        expect(find.text('우나보 개인정보 처리방침'), findsOneWidget);
        await _tapKey(tester, 'legal-document-1');
        expect(find.text('위치정보 수집·이용 동의'), findsOneWidget);
        expect(find.byKey(const ValueKey('legal-accept')), findsNothing);
        if (car) {
          await _tapKey(tester, 'car-settings-menu-consent');
          expect(find.text('위치정보 수집·이용 동의'), findsOneWidget);
        } else {
          await _tapKey(tester, 'legal-documents-back');
        }
        expect(
          services.store.preferences.getString('legal.consent.v1'),
          consent,
        );
        await _tapKey(tester, 'settings-map');
        expect(find.byType(MapCreditsScreen), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(MapCreditsScreen),
            matching: find.byTooltip('뒤로'),
          ),
        );
        await _pumpNavigation(tester);
        if (car) await _openSettings(tester);
        await _tapKey(tester, 'settings-back');
        expect(find.byType(SettingsScreen), findsNothing);
        _expectLobbyOnly();
        expect(_secondary, findsNothing);
        expect(services.rooms.state, same(room));
        expect(services.calls.state, same(call));
        await _tapKey(tester, 'current-room-card');
        expect(find.byType(RoomScreen), findsOneWidget);
        expect(services.calls.state.isActive, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _finish(tester, services);
      }
    }, timeout: _timeout);

    testWidgets('${car ? '차량' : '폰'} 설정 음량은 방 슬라이더와 저장값을 공유한다', (tester) async {
      final services = await _mountApp(tester, car: car);
      try {
        await _openSettings(tester);
        if (car) await _tapKey(tester, 'car-settings-menu-volume');
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

    testWidgets(
      '${car ? '차량' : '폰'} 서버 설정은 같은 출처의 방·통화를 유지하고 다른 출처는 옛 서버 로그아웃 뒤 로그인 화면으로 간다',
      (tester) async {
        final services = await _mountApp(tester, car: car);
        try {
          final call = services.calls.state;
          services.api.httpLogout = true;
          services.api.http.requests.clear();
          services.api.http.jsonResponse = (_) => <String, Object?>{};
          await _openSettings(tester);
          final server = find.descendant(
            of: find.byKey(const ValueKey('settings-server')),
            matching: find.byType(PanelButton),
          );
          await tester.ensureVisible(server);
          await tester.tap(server);
          await _pumpNavigation(tester);
          expect(
            tester
                .widget<AuthScreen>(find.byType(AuthScreen))
                .serverSettingsOnly,
            isTrue,
          );
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
            expect(_secondary, findsNothing);
            addTearDown(tester.view.resetViewInsets);
            tester.view.viewInsets = const FakeViewPadding(bottom: 648);
            await _pumpNavigation(tester);
            for (final target in [
              serverField,
              find.byKey(const ValueKey('server-settings-save')),
            ]) {
              expect(tester.getRect(target).bottom, lessThan(1206 - 648));
              expect(target.hitTestable(), findsOneWidget);
            }
          }
          await tester.enterText(serverField, 'ftp://example.invalid');
          await _tapKey(tester, 'server-settings-save');
          expect(find.byType(AuthScreen), findsOneWidget);
          expect(services.store.baseUrl, 'https://example.invalid');
          await tester.enterText(serverField, 'https://example.invalid:443/');
          await _tapKey(tester, 'server-settings-save');
          expect(find.byType(SettingsScreen), findsOneWidget);
          expect(services.store.baseUrl, 'https://example.invalid:443');
          if (!car) expect(find.text(services.store.baseUrl), findsOneWidget);
          expect(find.byType(AuthScreen), car ? findsOneWidget : findsNothing);
          expect(services.api.logouts, 0);
          expect(services.api.logins, 0);
          expect(services.api.signups, 0);
          expect(services.rooms.state.code, 'ABC123');
          expect(services.calls.state, same(call));
          await tester.ensureVisible(server);
          await tester.tap(server);
          await _pumpNavigation(tester);
          await tester.enterText(serverField, 'https://new.example.invalid/');
          await _tapKey(tester, 'server-settings-save');
          expect(services.api.logouts, 1);
          final logout = services.api.http.requests
              .where((request) => request.uri.path.endsWith('/v1/auth/logout'))
              .map(
                (request) => (
                  method: request.method,
                  uri: request.uri,
                  sentHeaders: request.sentHeaders,
                ),
              )
              .single;
          expect(logout.method, 'POST');
          expect(logout.uri.origin, 'https://example.invalid');
          expect(logout.sentHeaders['authorization'], 'Bearer test');
          expect(services.store.baseUrl, 'https://new.example.invalid');
          expect(services.store.session, isNull);
          expect(services.rooms.state.code, isNull);
          expect(services.calls.state.isActive, isFalse);
          expect(find.byType(SettingsScreen), findsNothing);
          expect(
            tester
                .widget<AuthScreen>(find.byType(AuthScreen))
                .serverSettingsOnly,
            isFalse,
          );
          await completeConsentFuture(
            tester,
            services.api.avatarPhoto('alice', 1),
          );
          final nextRequests = services.api.http.requests
              .where((request) => request.uri.host == 'new.example.invalid')
              .toList();
          expect(nextRequests, isNotEmpty);
          expect(
            nextRequests.every(
              (request) => !request.sentHeaders.containsKey('authorization'),
            ),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await _finish(tester, services);
        }
      },
      timeout: _timeout,
    );

    testWidgets(
      '${car ? '차량' : '폰'} 다른 출처 저장 중 로그아웃 실패는 주소·세션·방을 유지하고 오류를 표시한다',
      (tester) async {
        final services = await _mountApp(tester, car: car);
        try {
          final session = services.store.session;
          final call = services.calls.state;
          services.api.logoutFails = true;
          await _openSettings(tester);
          final server = find.descendant(
            of: find.byKey(const ValueKey('settings-server')),
            matching: find.byType(PanelButton),
          );
          await tester.ensureVisible(server);
          await tester.tap(server);
          await _pumpNavigation(tester);
          await tester.enterText(
            find.descendant(
              of: find.byType(AuthScreen),
              matching: find.byType(TextField),
            ),
            'https://new.example.invalid',
          );
          await _tapKey(tester, 'server-settings-save');
          expect(services.api.logouts, 1);
          expect(services.store.baseUrl, 'https://example.invalid');
          expect(services.store.session, same(session));
          expect(services.rooms.state.code, 'ABC123');
          expect(services.calls.state, same(call));
          expect(
            tester
                .widget<AuthScreen>(find.byType(AuthScreen))
                .serverSettingsOnly,
            isTrue,
          );
          expect(find.text('연결 실패'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await _finish(tester, services);
        }
      },
      timeout: _timeout,
    );

    testWidgets('${car ? '차량' : '폰'} 설정 로그아웃은 기존 오류·세션 정리 경로를 쓴다', (
      tester,
    ) async {
      final services = await _mountApp(tester, car: car);
      try {
        await _openSettings(tester);
        if (car) {
          expect(find.byKey(const ValueKey('settings-logout')), findsNothing);
          await _tapKey(tester, 'car-settings-menu-logout');
          expect(services.api.logouts, 0);
          expect(services.store.session, isNotNull);
          expect(
            find.descendant(
              of: _detail,
              matching: find.byKey(const ValueKey('settings-logout')),
            ),
            findsOneWidget,
          );
          await _tapKey(tester, 'car-settings-menu-profile');
          expect(services.api.logouts, 0);
          await _tapKey(tester, 'car-settings-menu-logout');
        }
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

  testWidgets('차량 빈 로비도 만들기·참여 중인 방을 가로로 나누고 빈 상태를 표시한다', (tester) async {
    final services = await _mountApp(tester, car: true);
    try {
      await _tapKey(tester, 'room-home');
      await completeConsentFuture(tester, services.rooms.forget());
      await _pumpNavigation(tester);
      expect(find.byKey(const ValueKey('car-lobby-create')), findsOneWidget);
      final active = find.byKey(const ValueKey('car-lobby-active'));
      expect(
        find.descendant(of: active, matching: find.byTooltip('참여 중인 방이 없습니다.')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('current-room-card')), findsNothing);
      expect(find.text(joinedRoomReason), findsNothing);
      expect(
        tester
            .widget<PanelButton>(
              find.byWidgetPredicate(
                (w) => w is PanelButton && w.label == '방 만들기',
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, services);
    }
  }, timeout: _timeout);

  testWidgets('차량 시스템 뒤로는 선택 모달을 닫고 설정에서 로비로 복귀한다', (tester) async {
    final services = await _mountApp(tester, car: true);
    try {
      await _openSettings(tester);
      await _tapKey(tester, 'profile-edit');
      expect(
        find.byKey(const ValueKey('profile-source-dialog')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await _pumpNavigation(tester);
      expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(
        tester
            .widget<PanelButton>(find.byKey(const ValueKey('profile-save')))
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await _pumpNavigation(tester);
      expect(find.byType(RoomsScreen), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(_secondary, findsNothing);
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
          await _openSettings(tester);
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
Finder get _detail => find.byKey(const ValueKey('car-settings-detail'));

Future<void> _openSettings(WidgetTester tester) async {
  if (find.byType(RoomScreen).evaluate().isNotEmpty) {
    await _tapKey(tester, 'room-home');
  }
  await _tapKey(tester, 'open-settings');
}

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
  tester.view.physicalSize = car
      ? const Size(1706, 1206)
      : const Size(412, 915);
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
