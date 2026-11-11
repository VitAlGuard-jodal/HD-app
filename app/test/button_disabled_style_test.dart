import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/floating_bar.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/icon_bundle.dart';

void main() {
  for (final car in [false, true]) {
    testWidgets('${car ? '차량' : '폰'} PanelButton은 모든 스타일에서 같은 비활성 색을 쓴다', (
      tester,
    ) async {
      for (final style in PanelButtonStyle.values) {
        await _mount(
          tester,
          car: car,
          button: PanelButton(
            label: '동의',
            icon: 'check',
            style: style,
            selected: true,
            onPressed: null,
          ),
        );
        final button = tester.widget<OutlinedButton>(
          find.byType(OutlinedButton),
        );
        expect(button.onPressed, isNull);
        _expectDisabledStyle(button.style!);
        expect(
          tester.widget<UnavoIcon>(find.byType(UnavoIcon)).color,
          UnavoColors.text.withValues(alpha: 0.4),
        );
        expect(
          tester.getSize(find.byType(PanelButton)),
          car ? const Size(80, 80) : const Size(56, 56),
        );
      }

      // 전문 펼치기처럼 별도 child로 넣은 SVG도 같은 색으로 표시한다.
      for (final enabled in [false, true]) {
        await _mount(
          tester,
          car: car,
          button: PanelButton(
            label: '전문 펼치기',
            onPressed: enabled ? () {} : null,
            child: const RotatedBox(
              quarterTurns: 2,
              child: UnavoIcon('chevron'),
            ),
          ),
        );
        final button = tester.widget<OutlinedButton>(
          find.byType(OutlinedButton),
        );
        if (enabled) {
          expect(button.child, isA<RotatedBox>());
        } else {
          _expectDisabledStyle(button.style!);
          expect(button.child, isA<ColorFiltered>());
          expect(
            (button.child! as ColorFiltered).colorFilter,
            ColorFilter.mode(
              UnavoColors.text.withValues(alpha: 0.4),
              BlendMode.srcIn,
            ),
          );
        }
        expect(
          tester.getSize(find.byType(PanelButton)),
          car ? const Size(80, 80) : const Size(56, 56),
        );
      }
      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets(
      '${car ? '차량' : '폰'} FloatingBarButton은 선택·위험 상태에서도 같은 비활성 색을 쓴다',
      (tester) async {
        for (final selected in [false, true]) {
          for (final danger in [false, true]) {
            await _mount(
              tester,
              car: car,
              button: FloatingBarButton(
                label: '나가기',
                icon: 'exit',
                selected: selected,
                danger: danger,
                onPressed: null,
              ),
            );
            final button = tester.widget<IconButton>(find.byType(IconButton));
            expect(button.onPressed, isNull);
            _expectDisabledStyle(button.style!);
            expect(
              tester.widget<UnavoIcon>(find.byType(UnavoIcon)).color,
              UnavoColors.text.withValues(alpha: 0.4),
            );
            expect(
              tester.getSize(find.byType(FloatingBarButton)),
              car ? const Size(80, 80) : const Size(48, 48),
            );
          }
        }
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}

void _expectDisabledStyle(ButtonStyle style) {
  const states = {WidgetState.disabled};
  final foreground = UnavoColors.text.withValues(alpha: 0.4);
  expect(style.backgroundColor!.resolve(states), UnavoColors.panel);
  expect(style.foregroundColor!.resolve(states), foreground);
  expect(style.side!.resolve(states)!.color, foreground);
}

Future<void> _mount(
  WidgetTester tester, {
  required bool car,
  required Widget button,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: testIconBuilder,
      home: Scaffold(
        body: ControlScale(
          car: car,
          child: Center(child: button),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}
