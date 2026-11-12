import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unavo/map/map_tiles.dart';
import 'package:unavo/map/room_map.dart';
import 'package:unavo/map/room_map_geometry.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/member_avatar.dart';

import 'support/icon_bundle.dart';

LocationFix _fix(
  String handle,
  double lat,
  double lng, {
  double? heading,
  int seq = 0,
}) => LocationFix(
  handle: handle,
  stream: '0123456789abcdef',
  lat: lat,
  lng: lng,
  at: 1000 + seq * 1000,
  seq: seq,
  heading: heading,
);

final _self = _fix('bob', 37.5, 127, heading: 90);
final _leader = _fix('alice', 37.5, 127.001);

void main() {
  test('방향이 있으면 뒤쪽 점을 제외하고 가장 가까운 앞쪽 점을 포함한다', () {
    final behind = _fix('alice', 37.5, 126.99999);
    final ahead = _fix('alice', 37.5, 127.0003);
    final farther = _fix('alice', 37.5, 127.0005);
    final bounds = followBounds(
      self: _self,
      leader: _leader,
      trail: [behind, farther, ahead],
    )!;
    expect(bounds.self, _self);
    expect(bounds.ahead, ahead);
    expect(bounds.south, 37.5);
    expect(bounds.north, 37.5);
    expect(bounds.west, 127);
    expect(bounds.east, 127.0003);
  });

  test('방향이 없으면 최근접점 다음 궤적을, 다음 점이 없으면 그룹장을 고른다', () {
    final self = _fix('bob', 37.5, 127);
    final nearest = _fix('alice', 37.5, 127.00001);
    final next = _fix('alice', 37.501, 127.0003);
    final bounds = followBounds(
      self: self,
      leader: _leader,
      trail: [nearest, next],
    )!;
    expect(bounds.ahead, next);
    expect(bounds.north, 37.501);
    expect(
      followBounds(self: self, leader: _leader, trail: [nearest])!.ahead,
      _leader,
    );
    expect(
      followBounds(self: _self, leader: _leader, trail: [])!.ahead,
      _leader,
    );
    expect(followBounds(self: null, leader: _leader, trail: []), isNull);
    expect(followBounds(self: _self, leader: null, trail: []), isNull);
  });

  test('앞쪽 점이 없거나 위치가 같아도 유효하고 직선 거리는 m/km로 표시한다', () {
    expect(
      followBounds(
        self: _self,
        leader: _leader,
        trail: [_fix('alice', 37.5, 126)],
      )!.ahead,
      _leader,
    );
    final same = followBounds(self: _self, leader: _self, trail: [])!;
    expect(same.south, same.north);
    expect(same.west, same.east);
    expect(roomDistanceLabel(_self, _self), '0 m');
    expect(roomDistanceLabel(_self, _leader), matches(RegExp(r'^\d+ m$')));
    expect(
      roomDistanceLabel(_self, _fix('alice', 37.52, 127)),
      matches(RegExp(r'^\d+\.\d km$')),
    );
  });

  testWidgets('빈 위치·궤적과 한 점 궤적은 선 없이 표시한다', (tester) async {
    final controller = RoomMapController();
    await _pumpMap(tester, controller, positions: const {}, follow: true);
    expect(
      tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers,
      isEmpty,
    );
    expect(
      tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines,
      isEmpty,
    );
    expect(find.text(MapTiles.defaultAttribution), findsOneWidget);
    controller.follow();
    controller.recenter();
    await tester.pump();
    expect(tester.takeException(), isNull);

    await _pumpMap(tester, controller, trail: [_leader], follow: true);
    expect(
      tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers,
      hasLength(2),
    );
    expect(
      tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines,
      isEmpty,
    );
    expect(find.text(roomDistanceLabel(_self, _leader)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('같은 궤적 스냅샷이면 Polyline 점 목록을 다시 만들지 않는다', (tester) async {
    final controller = RoomMapController();
    final trail = List<LocationFix>.unmodifiable(
      List.generate(
        7200,
        (seq) => _fix('alice', 37.5, 127 + seq / 1000000, seq: seq),
      ),
    );
    List<LatLng> points() => tester
        .widget<PolylineLayer>(find.byType(PolylineLayer))
        .polylines
        .single
        .points;
    await _pumpMap(tester, controller, trail: trail);
    final original = points();
    expect(original, hasLength(7200));
    for (var i = 0; i < 4; i++) {
      await _pumpMap(
        tester,
        controller,
        trail: trail,
        brightness: i.isEven ? Brightness.dark : Brightness.light,
        follow: i.isEven,
      );
      expect(points(), same(original));
    }

    final next = _fix('alice', 37.5, 127.0072, seq: 7200);
    await _pumpMap(
      tester,
      controller,
      trail: List<LocationFix>.unmodifiable([...trail, next]),
      leader: next,
    );
    expect(points(), isNot(same(original)));
    expect(points(), hasLength(7201));
    expect(points().last, LatLng(next.lat, next.lng));
    expect(original, hasLength(7200));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('키 없는 지도는 GPS 점·상대 기본 마스코트·상대 이름·궤적·출처를 표시한다', (tester) async {
    final controller = RoomMapController();
    final trail = [_fix('alice', 37.5, 127.0002), _leader];
    await _pumpMap(tester, controller, trail: trail);
    final markers = tester
        .widget<MarkerLayer>(find.byType(MarkerLayer))
        .markers;
    expect(markers, hasLength(2));
    expect(
      markers.map((marker) => marker.key),
      contains(const ValueKey('map-marker-bob')),
    );
    final cars = find.byWidgetPredicate(
      (widget) => widget is UnavoIcon && widget.name == 'car',
    );
    final stars = find.byWidgetPredicate(
      (widget) => widget is UnavoIcon && widget.name == 'star',
    );
    expect(cars, findsNothing, reason: '프로필 미설정 상대도 차 아이콘 대신 기본 마스코트를 쓴다');
    final avatar = tester.widget<MemberAvatar>(find.byType(MemberAvatar));
    expect(avatar.defaultMascot, isTrue, reason: '브이월드도 공통 마커의 기본 마스코트를 사용한다');
    expect(
      avatar.member.avatar.kind,
      isNull,
      reason: '기본 렌더링은 저장된 프로필을 바꾸지 않는다',
    );
    expect(stars, findsNothing);
    expect(find.byKey(const ValueKey('gps-marker')), findsOneWidget);
    expect(find.text('보비'), findsNothing);
    expect(find.text('앨리스'), findsOneWidget);
    final rotations = tester.widgetList<Transform>(find.byType(Transform));
    expect(
      rotations.any(
        (rotation) =>
            (rotation.transform.entry(1, 0) - math.sin(math.pi / 2)).abs() <
            .0001,
      ),
      isTrue,
    );
    final line = tester
        .widget<PolylineLayer>(find.byType(PolylineLayer))
        .polylines
        .single;
    expect(line.points, hasLength(2));
    expect(line.strokeWidth, 6);
    expect(line.strokeCap, StrokeCap.round);
    expect(line.color, UnavoColors.gold);
    expect(find.byType(TileLayer), findsNothing);
    expect(find.text(MapTiles.defaultAttribution), findsOneWidget);
    expect(find.text(roomDistanceLabel(_self, _leader)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('따라가기는 내 위치 중심·거리 줌, 제스처 동안 정지하고 종료 5초 후 재개한다', (tester) async {
    final controller = RoomMapController();
    await _pumpMap(tester, controller, follow: true);
    MapCamera camera() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    expect(camera().zoom, 17);
    expect(camera().center, LatLng(_self.lat, _self.lng));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FlutterMap)),
    );
    await gesture.moveBy(const Offset(100, 70));
    await tester.pump();
    final dragged = camera().center;
    final moved = _fix('alice', 37.51, 127.02);
    await _pumpMap(tester, controller, follow: true, leader: moved);
    await tester.pump(const Duration(seconds: 6));
    expect(camera().center, dragged);
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 4999));
    expect(camera().center, dragged);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(camera().center, isNot(dragged));
    expect(camera().center, LatLng(_self.lat, _self.lng));
    expect(camera().zoom, 14);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('지도 버튼은 재중심 줌 유지·heading 회전·북쪽 복귀, 상대만 반투명이다', (tester) async {
    final controller = RoomMapController();
    await _pumpMap(tester, controller);
    MapCamera camera() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    controller.moveTo(37.6, 127.1, zoom: 14);
    await tester.pump();
    await tester.tap(find.byTooltip('내 위치로'));
    await tester.pump();
    expect(camera().zoom, 14);
    expect(camera().center, LatLng(_self.lat, _self.lng));
    await tester.tap(find.byTooltip('방향 정렬'));
    await tester.pump();
    expect((camera().rotation + 360) % 360, 270);
    await tester.tap(find.byTooltip('방향 정렬'));
    await tester.pump();
    expect(camera().rotation, 0);
    expect(find.byType(RoomMapButton), findsNWidgets(4));
    final markers = tester
        .widget<MarkerLayer>(find.byType(MarkerLayer))
        .markers;
    expect(markers.last.key, const ValueKey('map-marker-bob'));
    for (final self in [false, true]) {
      final marker = find.byWidgetPredicate(
        (w) => w is RoomCarMarker && w.self == self,
      );
      expect(
        tester
            .widget<Opacity>(
              find.descendant(of: marker, matching: find.byType(Opacity)),
            )
            .opacity,
        self ? 1 : .55,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('따라가기 꺼짐은 카메라를 유지하고 재중심은 내 위치로 이동한다', (tester) async {
    final controller = RoomMapController();
    await _pumpMap(tester, controller);
    MapCamera camera() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    controller.moveTo(37.6, 127.1, zoom: 15);
    await tester.pump();
    final manual = camera().center;
    await _pumpMap(
      tester,
      controller,
      leader: _fix('alice', 37.7, 127.2),
      brightness: Brightness.dark,
    );
    await tester.pump(const Duration(seconds: 6));
    expect(camera().center, manual);
    controller.recenter();
    await tester.pump();
    expect(camera().center.latitude, closeTo(_self.lat, .000001));
    expect(camera().center.longitude, closeTo(_self.lng, .000001));
    expect(camera().zoom, 15);
    expect(find.text(MapTiles.defaultAttribution), findsOneWidget);
    expect(find.byType(TileLayer), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}

final _icons = TestIconBundle();
Future<void> _pumpMap(
  WidgetTester tester,
  RoomMapController controller, {
  bool follow = false,
  Map<String, RoomMapPosition>? positions,
  LocationFix? leader,
  List<LocationFix> trail = const [],
  Brightness brightness = Brightness.light,
  MapTiles tiles = const MapTiles(),
}) async {
  await tester.pumpWidget(
    DefaultAssetBundle(
      bundle: _icons,
      child: MaterialApp(
        home: Center(
          child: SizedBox(
            width: 600,
            height: 500,
            child: RoomMap(
              controller: controller,
              positions:
                  positions ??
                  {
                    'bob': RoomMapPosition(_self, displayName: '보비'),
                    'alice': RoomMapPosition(
                      leader ?? _leader,
                      displayName: '앨리스',
                    ),
                  },
              trail: trail,
              targetHandle: 'alice',
              selfHandle: 'bob',
              following: follow,
              brightness: brightness,
              tiles: tiles,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}
