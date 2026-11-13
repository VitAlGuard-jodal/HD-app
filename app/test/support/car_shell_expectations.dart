import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void expectCarShellSemantics(
  WidgetTester tester, {
  required bool settingsEnabled,
  bool settingsSelected = false,
}) {
  expect(find.semantics.byLabel('우나보'), findsOne);
  expect(find.semantics.byLabel('UNAVO'), findsOne);
  final settings = find.semantics.byLabel('설정');
  expect(settings, findsOne);
  expect(
    tester.getSemantics(find.byKey(const ValueKey('open-settings'))),
    same(settings.evaluate().single),
  );
  expect(
    settings.evaluate().single,
    isSemantics(
      label: '설정',
      isButton: true,
      hasEnabledState: true,
      isEnabled: settingsEnabled,
      hasSelectedState: true,
      isSelected: settingsSelected,
      hasTapAction: settingsEnabled,
    ),
  );
}
