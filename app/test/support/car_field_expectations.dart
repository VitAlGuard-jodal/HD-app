import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/focus_ring.dart';

/// 바깥 TextField뿐 아니라 실제 채움·테두리를 그리는 영역을 검사한다.
void expectCarFieldGeometry(
  WidgetTester tester,
  Finder field, {
  Finder? alignedWith,
  bool focused = false,
}) {
  final editable = find.descendant(
    of: field,
    matching: find.byType(EditableText),
  );
  final context = tester.element(editable);
  final container = InputDecorator.containerOf(context)!;
  final origin = container.localToGlobal(Offset.zero);
  final target = ControlScale.target(context);
  expect(target, 80);
  expect(container.size.height, target);
  expect(container.size, tester.getSize(field));
  expect(origin.dx, closeTo(tester.getTopLeft(field).dx, .01));
  expect(origin.dy, closeTo(tester.getTopLeft(field).dy, .01));
  final centerY = origin.dy + container.size.height / 2;
  expect(tester.getCenter(editable).dy, closeTo(centerY, .01));
  if (alignedWith != null) {
    expect(tester.getSize(alignedWith).height, target);
    expect(tester.getCenter(alignedWith).dy, closeTo(centerY, .01));
  }
  final textField = tester.widget<TextField>(field);
  expect(textField.style, UnavoType.body);
  expect(textField.decoration!.hintStyle!.fontSize, UnavoType.body.fontSize);
  expect(textField.decoration!.hintStyle!.height, UnavoType.body.height);
  expect(textField.textAlignVertical, TextAlignVertical.center);
  expect(
    find.ancestor(of: field, matching: find.byType(FocusRing)),
    findsNothing,
  );
  final decorator = tester.widget<InputDecorator>(
    find.descendant(of: field, matching: find.byType(InputDecorator)),
  );
  if (focused) {
    expect(decorator.isFocused, isTrue);
    final border = decorator.decoration.focusedBorder!;
    expect(border.borderSide.color, UnavoColors.gold);
    expect(border.borderSide.width, 3);
    // 폭이 소수(예: 397.3)라 Rect 를 그대로 비교하면 부동소수 오차로 어긋난다.
    final bounds = border
        .getOuterPath(Offset.zero & container.size)
        .getBounds();
    final box = Offset.zero & container.size;
    expect(bounds.left, closeTo(box.left, .01));
    expect(bounds.top, closeTo(box.top, .01));
    expect(bounds.right, closeTo(box.right, .01));
    expect(bounds.bottom, closeTo(box.bottom, .01));
  }
}
