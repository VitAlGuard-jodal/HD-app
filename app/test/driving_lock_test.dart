import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/core/driving_state.dart';
import 'package:unavo/main.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/widgets/driving_lock.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

const _timeout = Timeout(Duration(seconds: 30));
final _scrim = find.byKey(const ValueKey('driving-lock-scrim'));

void main() {
  for (final mode in DeviceMode.values) {
    testWidgets('${mode.name} 잠금·해제와 주·보조 패널 터치', (tester) async {
      final events = StreamController<Object?>.broadcast(sync: true);
      // 폰 오버레이에는 제한 상태인 차량 DrivingState를 전달해 방어도 검사한다.
      final driving = DrivingState(mode: DeviceMode.car, events: events.stream);
      var primaryTaps = 0;
      var secondaryTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => testIconBuilder(
            context,
            DrivingLockOverlay(mode: mode, driving: driving, child: child!),
          ),
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => primaryTaps++,
                    child: const Text('주 패널'),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    onPressed: () => secondaryTaps++,
                    child: const Text('보조 패널'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      try {
        expect(_scrim, findsNothing);
        await tester.tap(find.text('주 패널'));
        await tester.tap(find.text('보조 패널'));
        expect((primaryTaps, secondaryTaps), (1, 1));

        events.add({'restricted': true});
        await tester.pump();
        expect(driving.restricted, isTrue);
        expect(_scrim, mode == DeviceMode.car ? findsOneWidget : findsNothing);
        if (mode == DeviceMode.car) {
          expect(find.text('주행 중에는 조작할 수 없습니다'), findsOneWidget);
          expect(
            tester
                .widgetList<UnavoIcon>(find.byType(UnavoIcon))
                .map((i) => i.name),
            containsAll(['steering-wheel', 'lock']),
          );
          expect(tester.getSize(_scrim), tester.getSize(find.byType(Scaffold)));
        }
        // 잠금으로 hit test가 막히는 지점을 의도적으로 누른다.
        await tester.tapAt(tester.getCenter(find.text('주 패널')));
        await tester.tapAt(tester.getCenter(find.text('보조 패널')));
        final whileLocked = mode == DeviceMode.car ? 1 : 2;
        expect((primaryTaps, secondaryTaps), (whileLocked, whileLocked));

        events.add({'restricted': false});
        await tester.pump();
        expect(_scrim, findsNothing);
        await tester.tap(find.text('주 패널'));
        await tester.tap(find.text('보조 패널'));
        expect(
          (primaryTaps, secondaryTaps),
          (whileLocked + 1, whileLocked + 1),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        driving.dispose();
        await events.close();
      }
    }, timeout: _timeout);
  }

  testWidgets('실제 앱 builder는 잠금 중 도착한 다이얼로그 위를 막고 해제 후 유지한다', (tester) async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final services = await ConsentTestServices.create(
      tester,
      signedIn: false,
      mode: DeviceMode.car,
      drivingEvents: events.stream,
    );
    await tester.pumpWidget(
      Builder(
        builder: (context) => testIconBuilder(
          context,
          UnavoApp(services: services, mode: DeviceMode.car),
        ),
      ),
    );
    try {
      await pumpConsentUi(tester);
      final room = services.rooms.state;
      final call = services.calls.state;
      events.add({'restricted': true});
      await tester.pump();
      expect(_scrim, findsOneWidget);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      var responses = 0;
      final dialog = showDialog<void>(
        context: navigator.overlay!.context,
        builder: (context) => AlertDialog(
          title: const Text('따라가기 요청'),
          actions: [
            TextButton(
              onPressed: () {
                responses++;
                Navigator.pop(context);
              },
              child: const Text('수락'),
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('따라가기 요청'), findsOneWidget);
      expect(find.text('수락').hitTestable(), findsNothing);
      await tester.tapAt(tester.getCenter(find.text('수락')));
      expect(responses, 0);
      expect(services.rooms.state, same(room));
      expect(services.calls.state, same(call));

      events.add({'restricted': false});
      await tester.pump();
      expect(_scrim, findsNothing);
      expect(find.text('따라가기 요청'), findsOneWidget);
      expect(find.text('수락').hitTestable(), findsOneWidget);
      await tester.tap(find.text('수락'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await dialog;
      expect(responses, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await services.finish(tester);
      await events.close();
    }
  }, timeout: _timeout);
}
