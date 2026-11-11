import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:unavo/map/naver_room_map.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/map/room_map_geometry.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/ui/member_colors.dart';
import 'package:unavo/ui/widgets/member_avatar.dart';

import 'support/icon_bundle.dart';

LocationFix _fix(String handle, double lat, double lng, {double? heading}) =>
    LocationFix(
      handle: handle,
      lat: lat,
      lng: lng,
      heading: heading,
      at: 0,
      seq: 0,
    );

void main() {
  test('SDK 마커는 내 GPS 불투명·최상위, 상대 0.55와 폰36/차량48을 사용한다', () {
    for (final car in [false, true]) {
      final self = roomNaverMarker(
        handle: 'bob',
        fix: _fix('bob', 37, 127),
        icon: const NOverlayImage.fromAssetImage('test-only.png'),
        self: true,
        car: car,
      );
      final other = roomNaverMarker(
        handle: 'alice',
        fix: _fix('alice', 37, 127),
        icon: const NOverlayImage.fromAssetImage('test-only.png'),
        self: false,
        car: car,
      );
      expect(self.alpha, 1);
      expect(other.alpha, .55);
      expect(self.globalZIndex, greaterThan(other.globalZIndex));
      expect(RoomMarkerStyle(self: false, car: car).diameter, car ? 48 : 36);
      expect(other.size, RoomMarkerStyle(self: false, car: car).size);
      expect(self.anchor, NPoint.relativeCenter);
      expect(self.isFlat, isTrue);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('마커 캐시는 프로필 종류·버전·무지개 색을 구분하고 좌표 변화에는 재사용한다', () {
    RoomMarkerKey key({
      String? kind = 'photo',
      int version = 1,
      int order = 0,
      double lat = 37,
    }) => roomMarkerCacheKey(
      position: RoomMapPosition(
        _fix('alice', lat, 127),
        displayName: '앨리스',
        avatar: Avatar(kind: kind, version: version),
        order: order,
      ),
      self: false,
      brightness: Brightness.dark,
      car: false,
    );
    expect(key(), isNot(key(kind: 'mascot-01')));
    expect(key(), isNot(key(version: 2)));
    expect(key(), isNot(key(order: 1)));
    expect(key(), key(lat: 38));
    expect(key(), key(order: 7));
    expect(key().$9, rainbowColor(0));
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('프로필이 있어도 나는 무지개 GPS 점, 상대는 같은 색 원형 프로필이다', (tester) async {
    final position = RoomMapPosition(
      _fix('alice', 37, 127, heading: 90),
      displayName: '앨리스',
      avatar: const Avatar(kind: 'mascot-05', version: 2),
      order: 5,
    );
    for (final self in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          home: Scaffold(
            body: Center(
              child: RoomCarMarker(position: position, self: self),
            ),
          ),
        ),
      );
      if (self) {
        final painter =
            tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('gps-marker')),
                    )
                    .painter!
                as RoomGpsPainter;
        expect(painter.color, rainbowColor(5));
        expect(painter.hasHeading, isTrue);
        expect(find.byType(MemberAvatar), findsNothing);
      } else {
        final avatar = tester.widget<MemberAvatar>(find.byType(MemberAvatar));
        expect(avatar.member.avatar.kind, 'mascot-05');
        expect(avatar.member.order, 5);
        expect(avatar.diameter, 36);
        expect(find.text('앨리스'), findsOneWidget);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('거리 줌은 모든 임계값 직전과 경계에서 지정 단계로 바뀐다', () {
    for (final (meters, zoom) in <(double, double)>[
      (0, 17),
      (199.99, 17),
      (200, 16),
      (599.99, 16),
      (600, 15),
      (1499.99, 15),
      (1500, 14),
      (3999.99, 14),
      (4000, 13),
      (100000, 13),
    ]) {
      expect(zoomForDistance(meters), zoom, reason: '$meters m');
    }
  });

  test('내 위치를 중심으로 직선 거리 줌·기울임 50·내 heading을 사용한다', () {
    final self = _fix('self', 0, 0, heading: 123);
    for (final (latitude, zoom) in <(double, double)>[
      (.001, 17),
      (.003, 16),
      (.01, 15),
      (.02, 14),
      (.05, 13),
    ]) {
      final camera = naverFollowCamera(
        self: self,
        leader: _fix('leader', latitude, 0),
        trail: [_fix('leader', 0, .001), _fix('leader', 0, .002)],
        currentBearing: 280,
      )!;
      expect(camera.target, same(self));
      expect(camera.zoom, zoom);
      expect(camera.tilt, 50);
      expect(camera.bearing, 123);
    }
  });

  test('heading이 없으면 가장 가까운 궤적점의 다음 점 방위를 사용한다', () {
    final self = _fix('self', 0, 0);
    final leader = _fix('leader', 0, .02);
    final ahead = _fix('leader', .001, 0);
    final trail = [_fix('leader', 0, 0), ahead];
    expect(roomForwardPoint(self: self, leader: leader, trail: trail), ahead);
    final camera = naverFollowCamera(
      self: self,
      leader: leader,
      trail: trail,
      currentBearing: 230,
    )!;
    expect(camera.target, self);
    expect(camera.zoom, 14);
    expect(camera.bearing, closeTo(0, .001));
  });

  test('전방 궤적이 없으면 그룹장 방위를 0~360도로 정규화한다', () {
    final self = _fix('self', 0, 0);
    for (final trail in <List<LocationFix>>[
      [],
      [_fix('leader', 0, 0)],
    ]) {
      final camera = naverFollowCamera(
        self: self,
        leader: _fix('leader', 0, -.001),
        trail: trail,
        currentBearing: 40,
      )!;
      expect(camera.bearing, closeTo(270, .001));
    }
  });

  test('그룹장 위치가 없어도 남은 궤적이 있으면 그 방위를 사용한다', () {
    final camera = naverFollowCamera(
      self: _fix('self', 0, 0),
      leader: null,
      trail: [_fix('leader', 0, 0), _fix('leader', 0, .001)],
      currentBearing: 170,
    )!;
    expect(camera.zoom, 16);
    expect(camera.bearing, closeTo(90, .001));
  });

  test('heading·전방점이 없거나 좌표가 같으면 현재 bearing을 유지한다', () {
    final self = _fix('self', 0, 0);
    for (final leader in <LocationFix?>[null, _fix('leader', 0, 0)]) {
      final camera = naverFollowCamera(
        self: self,
        leader: leader,
        trail: [],
        currentBearing: 217.5,
      )!;
      expect(camera.bearing, 217.5);
    }
    final north = naverFollowCamera(
      self: _fix('self', 0, 0, heading: 360),
      leader: null,
      trail: [],
      currentBearing: 217.5,
    )!;
    expect(north.bearing, 0);
  });

  test('그룹장 본인은 자기 위치·줌 16을 사용한다', () {
    final self = _fix('leader', 37.5, 127, heading: 45);
    final camera = naverFollowCamera(
      self: self,
      leader: self,
      trail: [],
      currentBearing: 180,
      isLeader: true,
    )!;
    expect(camera.target, self);
    expect(camera.zoom, 16);
    expect(camera.bearing, 45);
    expect(camera.tilt, 50);
  });

  test('내 위치가 없으면 따라가기 카메라를 만들지 않는다', () {
    expect(
      naverFollowCamera(
        self: null,
        leader: _fix('leader', 0, 0),
        trail: [],
        currentBearing: 80,
      ),
      isNull,
    );
  });

  test('빈 궤적·한 점 궤적은 생략하고 두 점부터 경로로 전달한다', () {
    final first = _fix('leader', 0, 0);
    final second = _fix('leader', 0, .001);
    expect(roomPathPoints([]), isEmpty);
    expect(roomPathPoints([first]), isEmpty);
    expect(roomPathPoints([first, second]), [first, second]);
    expect(roomPathPoints([first, second, first]), [first, second, first]);
  });
}
