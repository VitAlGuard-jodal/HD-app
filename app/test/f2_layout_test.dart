import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/screens/car/car_shell.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/bottom_nav.dart';
import 'package:unavo/ui/widgets/member_tile.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

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
                  label: '통화 참여',
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
      expect(find.text('통화 참여'), findsNothing);
      expect(find.byTooltip('통화 참여'), findsOneWidget);
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
        tester.getSemantics(find.bySemanticsLabel('통화 참여')),
        matchesSemantics(
          label: '통화 참여',
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
                PanelButton(label: '통화 참여', icon: 'phone', onPressed: () {}),
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
      tester.getRect(find.byTooltip('통화 참여')).bottom,
      lessThanOrEqualTo(580),
    );
    expect(tester.takeException(), isNull);
  });
}
