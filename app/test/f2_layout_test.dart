import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/call/mesh_coordinator.dart';
import 'package:unavo/core/app_services.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/map/map_provider.dart';
import 'package:unavo/map/room_map.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/ui/widgets/floating_bar.dart';
import 'package:unavo/ui/widgets/panel_scroll.dart';
import 'package:unavo/ui/widgets/room_code.dart';
import 'package:unavo/ui/widgets/status_chip.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/screens/car/car_shell.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/bottom_nav.dart';
import 'package:unavo/ui/widgets/member_tile.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/icon_bundle.dart';

void main() {
  testWidgets('아이콘 버튼·탭은 글자 없이 라벨과 선택 상태를 유지한다', (tester) async {
    final semantics = tester.ensureSemantics();
    var pressed = 0;
    for (final car in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ControlScale(
              car: car,
              child: Center(
                child: PanelButton(
                  label: '음소거',
                  icon: 'phone',
                  selected: true,
                  onPressed: () => pressed++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('음소거'), findsNothing);
      expect(find.byTooltip('음소거'), findsOneWidget);
      final button = find.byType(OutlinedButton);
      expect(
        tester.getSize(button),
        car ? const Size(80, 80) : const Size(56, 56),
      );
      expect(
        tester.getSize(find.byType(UnavoIcon)),
        car ? const Size(36, 36) : const Size(24, 24),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('음소거')),
        matchesSemantics(
          label: '음소거',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(button);
    }
    expect(pressed, 2);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: BottomNav(index: 1, onChanged: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['방', '친구', '마이크']) {
      expect(find.text(label), findsNothing);
      expect(find.byTooltip(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('폰 필 바 3초 숨김·탭 토글·스크롤 방향 전환·탭 선택', (tester) async {
    final semantics = tester.ensureSemantics();
    var index = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => FloatingBarOverlay(
              bar: BottomNav(
                index: index,
                onChanged: (value) => update(() => index = value),
              ),
              child: PanelScroll(
                child: SizedBox(
                  height: 1800,
                  child: Column(children: const [Text('ABC123')]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double opacity() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey('floating-bar-opacity')),
        )
        .opacity;
    expect(opacity(), 1);
    await tester.tap(find.byTooltip('친구'));
    await tester.pump();
    expect(index, 1);
    for (final label in ['방', '친구', '마이크'])
      expect(find.text(label), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacity(), 0);
    await tester.tapAt(const Offset(150, 180));
    await tester.pump();
    expect(opacity(), 1);
    await tester.tapAt(const Offset(150, 180));
    await tester.pump();
    expect(opacity(), 0);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -180),
    );
    await tester.pump();
    expect(opacity(), 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 120));
    await tester.pump();
    expect(opacity(), 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('오류와 차량 고정 도크는 시간이 지나도 표시한다', (tester) async {
    final semantics = tester.ensureSemantics();
    for (final fixed in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingBarOverlay(
              fixed: fixed,
              bar: BottomNav(index: 0, onChanged: (_) {}),
              child: fixed ? const SizedBox.expand() : const ErrorText('연결 오류'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('floating-bar-opacity')),
            )
            .opacity,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
    semantics.dispose();
  });

  testWidgets('폰 음성·방 관리 버튼 4개·볼륨 확장, 차량은 80dp 버튼 3개', (tester) async {
    final semantics = tester.ensureSemantics();
    SharedPreferences.setMockInitialValues({
      'token': 'test',
      'handle': 'alice',
    });
    final services = AppServices(
      SessionStore(await SharedPreferences.getInstance()),
      mapProvider: MapProvider.vworld,
      mediaEngine: NoopMediaEngine(),
    );
    services.rooms.state = const RoomState(
      code: 'ABC123',
      isConnected: true,
      members: [Member('alice', 'Alice', '')],
    );
    services.calls.state = const CallState(
      roomCode: 'ABC123',
      selfHandle: 'alice',
      isActive: true,
    );
    for (final car in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          home: Scaffold(
            body: ControlScale(
              car: car,
              child: RoomScreen(
                services: services,
                mode: car ? DeviceMode.car : DeviceMode.phone,
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final controls = find.byKey(const ValueKey('room-controls'));
      expect(
        find.descendant(of: controls, matching: find.byType(FloatingBarButton)),
        findsNWidgets(car ? 3 : 4),
      );
      expect(
        find.descendant(of: controls, matching: find.byType(Text)),
        findsNothing,
      );
      expect(find.byTooltip('방 나가기'), findsOneWidget);
      expect(find.byTooltip('통화 참여'), findsNothing);
      expect(find.byTooltip('통화 끊기'), findsNothing);
      expect(find.byType(RoomMap), findsNothing);
      final icons = tester
          .widgetList<FloatingBarButton>(
            find.descendant(
              of: controls,
              matching: find.byType(FloatingBarButton),
            ),
          )
          .map((button) => button.icon);
      expect(
        icons,
        isNot(contains(anyOf('locationoff', 'navigation', 'focus'))),
      );
      expect(
        tester.getRect(controls).bottom,
        closeTo(tester.getRect(find.byType(RoomScreen)).bottom - 8, .01),
      );
      if (car) {
        expect(find.byType(Slider), findsNothing);
        expect(find.byTooltip('통화 음량 100%'), findsOneWidget);
        expect(find.byTooltip(services.rooms.outputLabel), findsNothing);
        for (final label in ['음소거', '방 나가기']) {
          final button = find.byTooltip(label);
          expect(tester.getSize(button), const Size(80, 80));
        }
        services.rooms.mediaConnection = MediaConnectionState.failed;
        await tester.pumpWidget(
          MaterialApp(
            builder: testIconBuilder,
            home: Scaffold(
              body: ControlScale(
                car: true,
                child: RoomScreen(
                  services: services,
                  mode: DeviceMode.car,
                  embedded: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.descendant(
            of: controls,
            matching: find.byType(FloatingBarButton),
          ),
          findsNWidgets(3),
        );
        expect(find.bySemanticsLabel(RegExp('다시 연결')), findsOneWidget);
        await tester.pump(const Duration(seconds: 10));
        expect(find.byType(FloatingBarOverlay), findsNothing);
        expect(find.byTooltip('방 나가기'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        continue;
      }
      await tester.tap(find.byTooltip('통화 음량 100%'));
      await tester.pump();
      final slider = find.byKey(const ValueKey('call-volume-slider'));
      expect(slider, findsOneWidget);
      expect(tester.widget<Slider>(slider).min, 0);
      expect(tester.widget<Slider>(slider).max, 100);
      expect(tester.widget<Slider>(slider).divisions, 100);
      final drag = await tester.startGesture(tester.getCenter(slider));
      await drag.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('room-controls')), findsOneWidget);
      await drag.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1999));
      expect(slider, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(slider, findsNothing);
      await tester.pump(const Duration(seconds: 4));
      if (car) expect(find.byType(FloatingBarOverlay), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await services.rooms.setCallVolume(100);
    }
    services.dispose();
    semantics.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('참여자 연결 중·실패는 작은 SVG와 semantics, 연결·발화는 기존 표시', (tester) async {
    final semantics = tester.ensureSemantics();
    for (final state in MeshPeerState.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemberTile(
              member: const Member('bob', 'Bob', ''),
              connection: state,
            ),
          ),
        ),
      );
      final pending = state == MeshPeerState.connecting;
      final failed =
          state == MeshPeerState.failed || state == MeshPeerState.closed;
      final icons = tester
          .widgetList<UnavoIcon>(find.byType(UnavoIcon))
          .map((icon) => icon.name);
      expect(icons.contains('refresh'), pending);
      expect(icons.contains('hangup'), failed);
      if (pending || failed) {
        expect(
          find.bySemanticsLabel(RegExp(pending ? '연결 중' : '연결 실패')),
          findsOneWidget,
        );
      }
      expect(find.text('연결 중'), findsNothing);
      expect(find.text('연결 실패'), findsNothing);
    }
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MemberTile(
            member: Member('bob', 'Bob', ''),
            connection: MeshPeerState.connected,
            speaking: true,
          ),
        ),
      ),
    );
    expect(
      tester
          .widgetList<UnavoIcon>(find.byType(UnavoIcon))
          .map((icon) => icon.name),
      contains('wave'),
    );
    expect(find.bySemanticsLabel(RegExp('말하는 중')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('5번째 상태 칩은 사유를 semantics에만 남긴다', (tester) async {
    final semantics = tester.ensureSemantics();
    SharedPreferences.setMockInitialValues({'token': 'test', 'handle': 'eve'});
    final services = AppServices(
      SessionStore(await SharedPreferences.getInstance()),
      mapProvider: MapProvider.vworld,
      mediaEngine: NoopMediaEngine(),
    );
    services.rooms.state = RoomState(
      code: 'ABC123',
      isConnected: true,
      members: [
        for (final name in ['alice', 'bob', 'charlie', 'david', 'eve'])
          Member(name, name, ''),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: testIconBuilder,
        home: Scaffold(
          body: RoomScreen(
            services: services,
            mode: DeviceMode.phone,
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pump();
    final chip = tester.widget<StatusChip>(find.byType(StatusChip));
    expect(chip.showLabel, isFalse);
    expect(chip.label, services.rooms.callJoinBlockedReason);
    expect(find.text(chip.label), findsNothing);
    expect(find.bySemanticsLabel(chip.label), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    services.dispose();
    semantics.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('방 코드 formatter는 대문자로 변환하고 한글·혼합 붙여넣기를 거부한다', () {
    const formatter = RoomCodeFormatter();
    const old = TextEditingValue(text: 'AB12');
    expect(
      formatter
          .formatEditUpdate(old, const TextEditingValue(text: 'ab12cd'))
          .text,
      'AB12CD',
    );
    expect(
      formatter.formatEditUpdate(old, const TextEditingValue(text: 'AB한글12')),
      old,
    );
    expect(
      formatter.formatEditUpdate(
        old,
        const TextEditingValue(
          text: '한',
          composing: TextRange(start: 0, end: 1),
        ),
      ),
      old,
    );
  });

  testWidgets('참여자 이름은 폰에서도 생략되지 않고 차량 카드는 80dp 이상이다', (tester) async {
    for (final car in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ControlScale(
              car: car,
              child: Center(
                child: SizedBox(
                  width: car ? 580 : 260,
                  child: const MemberTile(
                    member: Member('R6C_Tester', 'R6C_Tester 아주 긴 이름', ''),
                    self: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final name = find.text('R6C_Tester 아주 긴 이름');
      final paragraph = tester.renderObject<RenderParagraph>(name);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(
        tester.getRect(name).right,
        lessThanOrEqualTo(tester.getRect(find.byType(MemberTile)).right),
      );
      expect(find.text('@R6C_Tester'), findsOneWidget);
      if (car)
        expect(
          tester.getSize(find.byType(MemberTile)).height,
          greaterThanOrEqualTo(80),
        );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('차량 1320×940의 두 패널은 IME에도 열과 폭을 유지하며 키보드 위에 놓인다', (tester) async {
    tester.view.physicalSize = const Size(1320, 940);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final appearance = AppearanceController();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(
      UnavoAppearance(
        controller: appearance,
        child: MaterialApp(
          theme: unavoTheme(Brightness.dark),
          home: CarShell(
            primary: Column(
              children: [
                const Expanded(
                  child: SingleChildScrollView(child: Text('방 ABC123')),
                ),
                PanelButton(label: '음소거', icon: 'phone', onPressed: () {}),
              ],
            ),
            secondary: const Column(
              children: [
                TextField(),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final primary = find.byKey(const ValueKey('car-primary'));
    final secondary = find.byKey(const ValueKey('car-secondary'));
    final beforeLeft = tester.getRect(primary);
    final beforeRight = tester.getRect(secondary);
    expect(beforeLeft.right, lessThan(beforeRight.left));
    expect(beforeLeft.width, greaterThan(beforeRight.width));
    await tester.tap(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();
    expect(tester.getRect(primary).width, beforeLeft.width);
    expect(tester.getRect(secondary).left, beforeRight.left);
    expect(tester.getRect(primary).bottom, lessThanOrEqualTo(580));
    expect(tester.getRect(secondary).bottom, lessThanOrEqualTo(580));
    expect(
      tester.getRect(find.byTooltip('음소거')).bottom,
      lessThanOrEqualTo(580),
    );
    expect(tester.takeException(), isNull);
  });
}
