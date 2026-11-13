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
  double? speed,
  int seq = 0,
}) => LocationFix(
  handle: handle,
  stream: '0123456789abcdef',
  lat: lat,
  lng: lng,
  at: 1000 + seq * 1000,
  seq: seq,
  heading: heading,
  speed: speed,
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
      direction: 90,
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

  testWidgets('키 없는 지도도 나·상대 기본 프로필·작은 이름표·궤적·출처를 표시한다', (tester) async {
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
    final avatars = tester.widgetList<MemberAvatar>(find.byType(MemberAvatar));
    expect(avatars, hasLength(2));
    for (final avatar in avatars) {
      expect(avatar.defaultMascot, isTrue, reason: '나·상대 모두 기본 마스코트를 사용한다');
      expect(avatar.member.avatar.kind, isNull, reason: '저장된 프로필을 바꾸지 않는다');
      expect(avatar.diameter, 28);
    }
    expect(stars, findsNothing);
    expect(find.byKey(const ValueKey('gps-marker')), findsNothing);
    expect(find.text('보비'), findsNothing);
    expect(find.text('앨리스'), findsOneWidget);
    expect(
      find.byType(RoomDirectionIndicator),
      findsNothing,
      reason: '첫 표본만으로 방향을 표시하지 않는다',
    );
    for (final marker in markers) {
      expect(marker.rotate, isTrue, reason: '사진·이름표는 지도 회전을 상쇄한다');
    }
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
    expect(camera().zoom, 18);
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
    expect(camera().zoom, 15);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('지도 버튼은 줌 유지·계산된 이동 방향 정렬·북쪽 복귀, 상대만 반투명이다', (tester) async {
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
    expect(camera().rotation, 0, reason: '아직 이동하지 않았으면 센서 heading을 쓰지 않는다');
    final movedSelf = _fix(
      'bob',
      _self.lat,
      _self.lng + .0001,
      seq: 1,
      heading: 0,
      speed: 10,
    );
    await _pumpMap(tester, controller, self: movedSelf);
    expect((camera().rotation + 360) % 360, closeTo(270, .001));
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

  testWidgets('기본 카메라·moveTo 줌18과 차량 프로필32·방향 포함40을 사용한다', (tester) async {
    final controller = RoomMapController();
    await _pumpMap(tester, controller, car: true);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.options.initialZoom, 18);
    expect(map.mapController!.camera.zoom, 18);
    controller.moveTo(_self.lat, _self.lng);
    await tester.pump();
    expect(map.mapController!.camera.zoom, 18);
    for (final avatar in tester.widgetList<MemberAvatar>(
      find.byType(MemberAvatar),
    )) {
      expect(avatar.diameter, 32);
    }
    for (final marker
        in tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers) {
      expect(marker.width, 40);
      final self = marker.key == const ValueKey<String>('map-marker-bob');
      expect(
        marker.alignment,
        RoomMarkerStyle(self: self, car: true).alignment,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('브이월드 나·상대 방향은 독립적이며 지도 회전에도 사진은 서 있고 삼각형은 이동을 가리킨다', (
    tester,
  ) async {
    final controller = RoomMapController();
    await _pumpMap(tester, controller);
    final movedSelf = _fix(
      'bob',
      _self.lat,
      _self.lng + .0001,
      seq: 1,
      heading: 0,
      speed: 10,
    );
    final movedOther = _fix('alice', _leader.lat + .00005, _leader.lng, seq: 1);
    await _pumpMap(tester, controller, self: movedSelf, leader: movedOther);
    final markers = tester
        .widget<MarkerLayer>(find.byType(MarkerLayer))
        .markers;
    expect(markers.map((marker) => marker.key), [
      const ValueKey<String>('map-direction-alice'),
      const ValueKey<String>('map-marker-alice'),
      const ValueKey<String>('map-direction-bob'),
      const ValueKey<String>('map-marker-bob'),
    ]);
    for (final marker in markers) {
      expect(marker.rotate, marker.child is RoomCarMarker);
    }
    Offset directionVector(bool self) {
      final indicator = find.byWidgetPredicate(
        (widget) => widget is RoomDirectionIndicator && widget.self == self,
      );
      final box = tester.renderObject<RenderBox>(
        find.descendant(of: indicator, matching: find.byType(CustomPaint)),
      );
      final center = box.size.center(Offset.zero);
      return box.localToGlobal(Offset(center.dx, 0)) -
          box.localToGlobal(center);
    }

    expect(directionVector(true).dx, greaterThan(0));
    expect(directionVector(true).dy, closeTo(0, .001));
    expect(directionVector(false).dx, closeTo(0, .001));
    expect(directionVector(false).dy, lessThan(0));
    controller.alignHeading(true);
    await tester.pump();
    expect(directionVector(true).dx, closeTo(0, .001));
    expect(directionVector(true).dy, lessThan(0));
    expect(directionVector(false).dx, lessThan(0));
    expect(directionVector(false).dy, closeTo(0, .001));
    for (final avatar in find.byType(MemberAvatar).evaluate()) {
      final box = avatar.renderObject! as RenderBox;
      final horizontal =
          box.localToGlobal(const Offset(1, 0)) -
          box.localToGlobal(Offset.zero);
      expect(horizontal.dx, closeTo(1, .001));
      expect(horizontal.dy, closeTo(0, .001), reason: '프로필 사진 자체는 항상 똑바로 유지한다');
    }
    final previous = directionVector(true);
    await _pumpMap(
      tester,
      controller,
      self: _fix(
        'bob',
        movedSelf.lat,
        movedSelf.lng,
        seq: 2,
        heading: 180,
        speed: 0,
      ),
      leader: movedOther,
      brightness: Brightness.dark,
    );
    expect(directionVector(true).dx, closeTo(previous.dx, .001));
    expect(directionVector(true).dy, closeTo(previous.dy, .001));
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
  LocationFix? self,
  bool car = false,
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
                    'bob': RoomMapPosition(self ?? _self, displayName: '보비'),
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
              car: car,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}
