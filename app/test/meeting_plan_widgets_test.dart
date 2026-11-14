import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/meeting_plan_controller.dart';
import 'package:unavo/net/meeting_plan.dart';
import 'package:unavo/map/map_tiles.dart';
import 'package:unavo/map/room_map.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/screens/phone/meeting_plan_panel.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/panel_button.dart';
import 'support/follow_route_fakes.dart';
import 'support/meeting_plan_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  testWidgets(
    'r8 waiting group shows the approaching driver ETA, expiry and delay',
    (tester) async {
      final f = MeetingFixture();
      f.stop();
      final runtime = runtimeJson(followerPhase: 'atJoinWaiting');
      final leader = Map<String, dynamic>.from(
        (runtime['vehicles'] as List).first as Map,
      );
      (runtime['vehicles'] as List)[0] = leader;
      leader.addAll({
        'reportedStage': 'toJoin',
        'etaSeconds': 120,
        'calculatedAtMs': routeEpoch,
      });
      await f.enroll(runtime: runtime);
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          home: Scaffold(
            body: MeetingPlanPanel(
              controller: f.controller,
              onClose: () {},
              onShowPoint: (_, __) {},
              displayName: (h) => h == 'leader' ? '앞차' : '나',
            ),
          ),
        ),
      );
      await mount();
      expect(
        find.textContaining('앞차 · 합류 지점으로 이동 · 계산 당시 약 2분'),
        findsOneWidget,
      );
      f.time = 60000;
      f.update();
      leader['etaSeconds'] = null;
      runtime['runtimeRevision'] = 2;
      f.controller.applyRuntime(MeetingRuntime.fromJson(runtime));
      await tester.pump();
      expect(find.textContaining('예상 시간 갱신 필요'), findsOneWidget);
      expect(find.textContaining('약 2분'), findsNothing);
      leader['condition'] = 'locationDelayed';
      runtime['runtimeRevision'] = 3;
      f.controller.applyRuntime(MeetingRuntime.fromJson(runtime));
      await tester.pump();
      expect(find.textContaining('예상 시간 갱신 필요'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      f.dispose();
    },
  );
  for (final car in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets('합류 편집 $car/$brightness 는 아이콘과 한국어 설명을 유지하고 정차 해제 시 닫힌다', (
        tester,
      ) async {
        final f = MeetingFixture(
          account: 'leader',
          target: null,
          relationship: null,
        );
        f.stop();
        f.controller.beginEditing();
        await flush();
        var closed = 0;
        await tester.pumpWidget(
          MaterialApp(
            builder: testIconBuilder,
            theme: unavoTheme(brightness),
            home: Scaffold(
              body: ControlScale(
                car: car,
                child: Center(
                  child: SizedBox(
                    width: car ? 340 : 240,
                    height: 450,
                    child: MeetingPlanPanel(
                      controller: f.controller,
                      onClose: () {
                        closed++;
                      },
                      onShowPoint: (_, __) {},
                      displayName: (h) => h,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('목적지 선택'), findsOneWidget);
        for (final b in tester.widgetList<PanelButton>(
          find.byType(PanelButton),
        )) {
          expect(b.iconOnly, isTrue);
        }
        expect(tester.takeException(), isNull);
        f.drive(10, speed: 10);
        await tester.pump();
        expect(f.controller.editing, isFalse);
        expect(closed, greaterThan(0));
        await tester.pumpWidget(const SizedBox.shrink());
        f.dispose();
      });
    }
  }
  testWidgets(
    'VWorld renders named confirmed and draft pins, removes them, and exposes mode ② only with capability',
    (tester) async {
      final camera = RoomMapController();
      final f = MeetingFixture();
      f.stop();
      await f.enroll();
      Future<void> mount(List<MeetingPin> pins) => tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 500,
              child: RoomMap(
                controller: camera,
                positions: const {},
                trail: const [],
                targetHandle: 'leader',
                selfHandle: 'self',
                following: false,
                brightness: Brightness.light,
                tiles: const MapTiles(),
                guidance: f.controller.view,
                meetingAvailable: true,
                meetingPins: pins,
                onModeChanged: (_) {},
                onPointSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await mount([
        MeetingPin('destination', testPoint(1000), '목적지'),
        MeetingPin('pending', testPoint(100), '합류 지점 후보', draft: true),
      ]);
      await tester.pump();
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.onLongPress, isNotNull);
      final markers = tester
          .widget<MarkerLayer>(find.byType(MarkerLayer))
          .markers;
      expect(markers.length, 2);
      final button = tester.widget<RoomMapButton>(
        find.byWidgetPredicate(
          (w) => w is RoomMapButton && w.label == '합류 지점 따라가기',
        ),
      );
      expect(button.selected, isTrue);
      expect(button.onPressed, isNotNull);
      await mount([]);
      await tester.pump();
      expect(
        tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      f.dispose();
      camera.dispose();
    },
  );
}
