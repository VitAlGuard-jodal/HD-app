import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/widgets/panel_edit_menu.dart';
import 'package:unavo/ui/widgets/panel_field.dart';

void main() {
  testWidgets('텍스트 선택 메뉴는 Material 아이콘 없이 복사·붙여넣기를 보존한다', (tester) async {
    final semantics = tester.ensureSemantics();
    // 커서 깜빡임 타이머가 프레임을 계속 예약해 pumpAndSettle 이 끝나지 않는다.
    EditableText.debugDeterministicCursor = true;
    addTearDown(() => EditableText.debugDeterministicCursor = false);
    // 위젯 테스트에는 클립보드 플랫폼 핸들러가 없어 getData 가 영원히 기다린다 → 가짜 핸들러.
    Map<Object?, Object?>? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.setData' => (clip = Map<Object?, Object?>.from(call.arguments as Map), null).$2,
        'Clipboard.getData' => clip,
        'Clipboard.hasStrings' => {'value': clip != null},
        _ => null,
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PanelField(
              controller: controller,
              label: '방 이름',
              icon: 'rooms',
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'ABC123');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.showToolbar(), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PanelEditMenu), findsOneWidget);
    expect(find.byType(Icon), findsNothing);
    expect(
      find.descendant(
        of: find.byType(PanelEditMenu),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
    final strings = MaterialLocalizations.of(
      tester.element(find.byType(PanelField)),
    );
    await tester.tap(find.byTooltip(strings.copyButtonLabel));
    await tester.pump(const Duration(milliseconds: 400));
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, 'ABC');
    controller.selection = const TextSelection.collapsed(offset: 6);
    await tester.pump();
    expect(editable.showToolbar(), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip(strings.pasteButtonLabel));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.text, 'ABC123ABC');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    semantics.dispose();
  });
}
