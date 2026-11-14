import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/map/map_tiles.dart';
import 'package:unavo/map/naver_room_map.dart';
import 'package:unavo/map/room_map.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/ui/theme.dart';

import 'support/follow_route_fakes.dart';
import 'support/icon_bundle.dart';

FollowRouteView view({
  bool merged = false,
  bool failed = false,
  bool delayed = false,
  bool rejoining = false,
}) => FollowRouteView(
  mode: FollowMode.a,
  rejoining: rejoining,
  phase: merged ? FollowPhase.onTrace : FollowPhase.approaching,
  condition: failed
      ? FollowRouteCondition.noRoute
      : delayed
      ? FollowRouteCondition.locationDelayed
      : FollowRouteCondition.ready,
  connector: merged || failed
      ? []
      : [testPoint(-100), testPoint(-20, 10), testPoint(0)],
  trace: [
    [testPoint(0), testPoint(100)],
    [testPoint(120), testPoint(200)],
  ],
  anchor: merged ? null : testPoint(0),
  confirmed: !failed,
  subdued: delayed,
  status: failed
      ? '추천 경로를 찾지 못했습니다'
      : delayed
      ? '위치 갱신 대기'
      : '앞차가 지나간 경로를 따라갑니다',
);

void main() {
  for (final car in [false, true]) {
    for (final brightness in Brightness.values) {
      for (final fullscreen in [false, true]) {
        testWidgets(
          'VWorld $car/$brightness/$fullscreen connector and broken trace remain separate',
          (tester) async {
            final controller = RoomMapController();
            Future<void> pump(FollowRouteView state) => tester.pumpWidget(
              MaterialApp(
                builder: testIconBuilder,
                theme: unavoTheme(brightness),
                home: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: car ? 460 : 280,
                      height: car ? 420 : 320,
                      child: RoomMap(
                        controller: controller,
                        // 지도는 화면 밖 표식을 그리지 않는다. 내 위치를 기준점 옆에 둬 카메라가 그곳을 비추게 한다.
                        positions: {
                          'self': RoomMapPosition(
                            testFix(-50, handle: 'self'),
                            displayName: '나',
                          ),
                        },
                        trail: const [],
                        targetHandle: 'leader',
                        selfHandle: 'self',
                        following: false,
                        brightness: brightness,
                        car: car,
                        fullscreen: fullscreen,
                        guidance: state,
                        tiles: const MapTiles(),
                        onModeChanged: (_) {},
                        onResetGuidance: () {},
                      ),
                    ),
                  ),
                ),
              ),
            );
            await pump(view());
            await tester.pump();
            List<Polyline> lines() => tester
                .widget<PolylineLayer>(find.byType(PolylineLayer))
                .polylines;
            expect(lines(), hasLength(3));
            expect(lines()[0].color, isNot(lines()[1].color));
            expect(lines()[1].color, UnavoColors.gold);
            expect(find.byKey(const ValueKey('follow-anchor')), findsOneWidget);
            final selected = tester.widget<RoomMapButton>(
              find.byWidgetPredicate(
                (widget) => widget is RoomMapButton && widget.label == '따라가기',
              ),
            );
            expect(selected.selected, isTrue);
            final container = tester.widget<Container>(
              find
                  .descendant(
                    of: find.byWidget(selected),
                    matching: find.byType(Container),
                  )
                  .first,
            );
            expect(
              (container.decoration! as BoxDecoration).color,
              UnavoColors.gold,
            );
            expect(find.byTooltip('합류 후 따라가기'), findsNothing);
            final reserved = tester.widget<RoomMapButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is RoomMapButton &&
                    widget.label == '합류 지점 따라가기 · 사용할 수 없음',
              ),
            );
            expect(reserved.onPressed, isNull);
            expect(reserved.selected, isFalse);
            await pump(view(rejoining: true));
            expect(lines()[0].color, const Color(0x80808080));
            expect(lines()[0].color.a, closeTo(.5, .01));
            expect(lines()[0].pattern.segments, [12, 8]);
            await pump(view(delayed: true));
            expect(lines()[0].color.a, closeTo(.35, .01));
            await pump(view(merged: true));
            expect(lines(), hasLength(2));
            expect(find.byKey(const ValueKey('follow-anchor')), findsNothing);
            await pump(view(failed: true));
            expect(lines(), hasLength(2));
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            controller.dispose();
          },
        );
      }
    }
  }
  testWidgets(
    'locked route controls are icon-only, selected and disabled in semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          home: const SizedBox(
            width: 300,
            height: 400,
            child: RoomMapControls(
              car: false,
              fullscreen: false,
              headingAligned: false,
              mode: FollowMode.a,
            ),
          ),
        ),
      );
      final button = find.byWidgetPredicate(
        (widget) => widget is RoomMapButton && widget.label == '따라가기',
      );
      final state = tester.getSemantics(button);
      expect(
        state,
        matchesSemantics(
          label: '따라가기',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      expect(tester.widget<RoomMapButton>(button).onPressed, isNull);
      semantics.dispose();
    },
  );
  test(
    'Naver uses route geometry in lat/lng order with distinct colors and delayed opacity',
    () {
      for (final brightness in Brightness.values) {
        final data = view();
        final rejoin = roomNaverRejoinPath(data.connector);
        expect(rejoin.coords[1].latitude, data.connector[1].lat);
        expect(rejoin.coords[1].longitude, data.connector[1].lng);
        expect(rejoin.color, const Color(0x80808080));
        expect(rejoin.color.a, closeTo(.5, .01));
        expect(rejoin.pattern, [12, 8]);
        final connector = roomNaverRoutePath(
          id: 'connector',
          points: data.connector,
          connector: true,
          subdued: false,
          brightness: brightness,
        );
        final trace = roomNaverRoutePath(
          id: 'trace:0',
          points: data.trace.first,
          connector: false,
          subdued: false,
          brightness: brightness,
        );
        expect(connector.coords.length, 3);
        expect(connector.coords[1].latitude, data.connector[1].lat);
        expect(connector.coords[1].longitude, data.connector[1].lng);
        expect(connector.color, isNot(trace.color));
        expect(trace.color, UnavoColors.gold);
        final delayed = roomNaverRoutePath(
          id: 'connector',
          points: data.connector,
          connector: true,
          subdued: true,
          brightness: brightness,
        );
        expect(delayed.color.a, closeTo(.35, .01));
      }
    },
  );
}
