import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/widgets/panel_button.dart';
import 'package:unavo/ui/widgets/unavo_dialog.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  for (final car in [false, true]) {
    testWidgets(
      '${car ? '차량' : '폰'} 모달은 가운데 표시되며 바깥 탭·시스템 back을 막고 선택값을 반환한다',
      (tester) async {
        tester.view.physicalSize = car
            ? const Size(1320, 940)
            : const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final results = <bool>[];
        var backgroundTaps = 0;
        await _mount(
          tester,
          car: car,
          onBackground: () => backgroundTaps++,
          onOpen: (context) {
            unawaited(
              showConsentDialog(
                context,
                title: '위치 공유',
                lines: const ['앨리스', '같은 방 참여자에게 내 차 위치를 보여 줍니다'],
              ).then(results.add),
            );
          },
        );
        for (final accepted in [true, false]) {
          await tester.tap(find.byTooltip('열기'));
          await pumpConsentUi(tester);
          final dialog = find.byType(Dialog);
          expect(dialog, findsOneWidget);
          final card = find.descendant(
            of: dialog,
            matching: find.byType(Material),
          );
          final rect = tester.getRect(card.first);
          expect(
            (rect.center - tester.view.physicalSize.center(Offset.zero))
                .distance,
            lessThan(.1),
          );
          expect(rect.width, closeTo(car ? 560 : 412 * .9, .1));
          final buttons = find.descendant(
            of: dialog,
            matching: find.byType(PanelButton),
          );
          expect(buttons, findsNWidgets(2));
          for (final button in tester.widgetList<PanelButton>(buttons)) {
            expect(button.iconOnly, isTrue);
            expect(button.icon, anyOf('back', 'check'));
          }
          expect(
            tester.getSize(find.byTooltip('동의')),
            car ? const Size(80, 80) : const Size(56, 56),
          );
          final before = results.length;
          await tester.tapAt(const Offset(28, 28));
          await tester.binding.handlePopRoute();
          await pumpConsentUi(tester);
          expect(dialog, findsOneWidget);
          expect(backgroundTaps, 0);
          expect(results, hasLength(before));
          await tester.tap(find.byTooltip(accepted ? '동의' : '미동의'));
          await pumpConsentUi(tester);
          expect(dialog, findsNothing);
          expect(results.last, accepted);
        }
        expect(results, [true, false]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets('넓은 폰 카드 상한은 420이고 긴 상세는 스크롤하며 버튼은 유지된다', (tester) async {
    await _mount(
      tester,
      onOpen: (context) {
        unawaited(
          showConsentDialog(
            context,
            title: '문서',
            lines: const ['설명'],
            detail: Column(
              children: [for (var i = 0; i < 40; i++) Text('상세 $i')],
            ),
          ),
        );
      },
    );
    await tester.tap(find.byTooltip('열기'));
    await pumpConsentUi(tester);
    final card = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(Material),
    );
    expect(tester.getSize(card.first).width, 420);
    final before = tester.getRect(find.byTooltip('동의'));
    await tester.scrollUntilVisible(
      find.text('상세 39'),
      200,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('상세 39').hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byTooltip('동의')), before);
    await tester.tap(find.byTooltip('동의'));
    await pumpConsentUi(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('안내 모달은 check 버튼 하나로만 닫힌다', (tester) async {
    var closed = false;
    await _mount(
      tester,
      onOpen: (context) {
        unawaited(
          showNoticeDialog(
            context,
            message: '동의하지 않아 위치 공유 기능을 사용할 수 없습니다',
          ).then((_) => closed = true),
        );
      },
    );
    await tester.tap(find.byTooltip('열기'));
    await pumpConsentUi(tester);
    final buttons = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(PanelButton),
    );
    expect(buttons, findsOneWidget);
    expect(tester.widget<PanelButton>(buttons).icon, 'check');
    await tester.tapAt(const Offset(5, 5));
    await tester.binding.handlePopRoute();
    await pumpConsentUi(tester);
    expect(closed, isFalse);
    expect(find.byType(Dialog), findsOneWidget);
    await tester.tap(find.byTooltip('닫기'));
    await pumpConsentUi(tester);
    expect(closed, isTrue);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Future<void> _mount(
  WidgetTester tester, {
  bool car = false,
  VoidCallback? onBackground,
  required ValueChanged<BuildContext> onOpen,
}) => tester.pumpWidget(
  MaterialApp(
    builder: testIconBuilder,
    home: ControlScale(
      car: car,
      child: Builder(
        builder: (context) => Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: PanelButton(
                  label: '배경 조작',
                  icon: 'check',
                  onPressed: onBackground,
                ),
              ),
              Center(
                child: PanelButton(
                  label: '열기',
                  icon: 'check',
                  onPressed: () => onOpen(context),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);
