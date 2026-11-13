import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/focus_ring.dart';
import 'package:unavo/ui/widgets/panel_button.dart';
import 'package:unavo/ui/widgets/panel_field.dart';

import 'support/car_field_expectations.dart';
import 'support/icon_bundle.dart';

void main() {
  for (final obscure in [false, true]) {
    testWidgets('차량 ${obscure ? '비밀번호' : '일반'} 입력의 실제 상자·포커스·버튼은 80dp로 정렬된다', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      try {
        await _mount(tester, controller, focus, car: true, obscure: obscure);
        final field = find.byType(TextField);
        final button = find.byType(PanelButton);
        expectCarFieldGeometry(tester, field, alignedWith: button);
        final hint = find.text('입력');
        expect(
          tester.getCenter(hint).dy,
          closeTo(tester.getCenter(button).dy, .01),
        );
        final icon = find.descendant(
          of: field,
          matching: find.byType(UnavoIcon),
        );
        expect(tester.getSize(icon), const Size(36, 36));
        expect(
          tester.getCenter(icon).dy,
          closeTo(tester.getCenter(button).dy, .01),
        );
        final before = tester.getRect(field);
        focus.requestFocus();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expectCarFieldGeometry(
          tester,
          field,
          alignedWith: button,
          focused: true,
        );
        controller.text = '차량 Alice123';
        await tester.pump();
        expectCarFieldGeometry(
          tester,
          field,
          alignedWith: button,
          focused: true,
        );
        expect(tester.getRect(field), before);
        focus.unfocus();
        await tester.pump();
        await _mount(
          tester,
          controller,
          focus,
          car: true,
          obscure: obscure,
          enabled: false,
        );
        expectCarFieldGeometry(tester, field, alignedWith: button);
        expect(tester.widget<TextField>(field).enabled, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        focus.dispose();
        controller.dispose();
      }
    });
  }

  testWidgets('폰 입력은 기존 56dp 영역·48dp 상자·글꼴·외부 포커스 링을 유지한다', (tester) async {
    final controller = TextEditingController(text: 'alice');
    final focus = FocusNode();
    try {
      await _mount(tester, controller, focus, car: false);
      final field = find.byType(TextField);
      final editable = find.byType(EditableText);
      expect(tester.getSize(field).height, 56);
      expect(
        InputDecorator.containerOf(tester.element(editable))!.size.height,
        48,
      );
      expect(
        find.ancestor(of: field, matching: find.byType(FocusRing)),
        findsOneWidget,
      );
      final widget = tester.widget<TextField>(field);
      expect(widget.style, UnavoType.body);
      expect(widget.textAlignVertical, isNull);
      expect(
        widget.decoration!.hintStyle,
        const TextStyle(fontSize: 16, color: UnavoColors.muted),
      );
      expect(
        widget.decoration!.prefixIconConstraints,
        const BoxConstraints(minWidth: 52, maxWidth: 52),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        InputDecorator.containerOf(tester.element(editable))!.size.height,
        48,
      );
      expect(widget.decoration!.focusedBorder!.borderSide.width, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      controller.dispose();
    }
  });
}

Future<void> _mount(
  WidgetTester tester,
  TextEditingController controller,
  FocusNode focus, {
  required bool car,
  bool obscure = false,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: testIconBuilder,
      theme: unavoTheme(Brightness.dark),
      home: Scaffold(
        body: ControlScale(
          car: car,
          child: Center(
            child: SizedBox(
              width: 500,
              child: Row(
                children: [
                  Expanded(
                    child: PanelField(
                      controller: controller,
                      focusNode: focus,
                      label: '입력',
                      icon: 'user',
                      obscureText: obscure,
                      enabled: enabled,
                    ),
                  ),
                  PanelButton(label: '저장', icon: 'check', onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}
