import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:unavo/map/naver_room_map.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/map/room_map_geometry.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/ui/avatar_images.dart';
import 'package:unavo/ui/icons.dart';
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
  test('실패 마커는 30초 동안 캡처 한 번을 재사용하고 다음 sync에서 성공 아이콘으로 바뀐다', () {
    fakeAsync((clock) {
      final cache = RoomMarkerIconCache(
        now: () => DateTime.utc(2026).add(clock.elapsed),
      );
      final key = roomMarkerCacheKey(
        position: RoomMapPosition(
          _fix('alice', 37, 127),
          displayName: '앨리스',
          avatar: const Avatar(kind: 'photo', version: 1),
        ),
        self: false,
        brightness: Brightness.dark,
        car: false,
      );
      const fallback = NOverlayImage.fromAssetImage('fallback.png');
      const resolved = NOverlayImage.fromAssetImage('resolved.png');
      var captures = 0;
      var failed = true;
      NOverlayImage? sync() {
        NOverlayImage? result;
        unawaited(
          cache
              .load(key, () async {
                captures++;
                return (icon: failed ? fallback : resolved, failed: failed);
              })
              .then((icon) {
                result = icon;
              }),
        );
        clock.flushMicrotasks();
        return result;
      }

      expect(sync(), same(fallback));
      failed = false;
      for (var i = 0; i < 5; i++) expect(sync(), same(fallback));
      clock.elapse(const Duration(seconds: 29));
      expect(sync(), same(fallback));
      expect(captures, 1);
      clock.elapse(const Duration(seconds: 1));
      expect(captures, 1, reason: '시간 경과만으로 캡처하지 않는다');
      expect(sync(), same(resolved));
      expect(captures, 2);
      clock.elapse(const Duration(seconds: 30));
      expect(sync(), same(resolved));
      expect(captures, 2);
      cache.clear();
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('SDK 마커는 내 GPS 불투명·최상위, 상대 0.55와 폰36/차량48을 사용한다', () {
    for (final car in [false, true]) {
      final self = roomNaverMarker(
        handle: 'bob',
        fix: _fix('bob', 37, 127, heading: 90),
        icon: const NOverlayImage.fromAssetImage('test-only.png'),
        self: true,
        car: car,
      );
      final other = roomNaverMarker(
        handle: 'alice',
        fix: _fix('alice', 37, 127, heading: 90),
        icon: const NOverlayImage.fromAssetImage('test-only.png'),
        self: false,
        car: car,
        profile: true,
      );
      expect(self.alpha, 1);
      expect(other.alpha, .55);
      expect(self.globalZIndex, greaterThan(other.globalZIndex));
      expect(RoomMarkerStyle(self: false, car: car).diameter, car ? 48 : 36);
      expect(other.size, RoomMarkerStyle(self: false, car: car).size);
      expect(self.anchor, NPoint.relativeCenter);
      expect(self.isFlat, isTrue);
      expect(self.angle, 90, reason: '내 GPS 마커는 기존 heading 회전을 유지한다');
      expect(other.angle, 0, reason: '모든 상대는 profile 정책으로 아이콘과 이름표를 회전시키지 않는다');
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('프로필 미설정 상대는 회전 없는 기본 마스코트 1번과 입장 색 테두리를 쓴다', (tester) async {
    final position = RoomMapPosition(
      _fix('alice', 37, 127, heading: 123),
      displayName: '앨리스',
      order: 4,
    );
    for (final car in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          builder: testIconBuilder,
          home: Scaffold(
            body: Center(
              child: RoomCarMarker(position: position, self: false, car: car),
            ),
          ),
        ),
      );
      expect(
        find.byType(MemberAvatar),
        findsOneWidget,
        reason: 'null 프로필도 공통 아바타로 렌더링한다',
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is UnavoIcon && widget.name == 'car',
        ),
        findsNothing,
        reason: '프로필 미설정은 사진 로드 실패가 아니다',
      );
      final avatar = tester.widget<MemberAvatar>(find.byType(MemberAvatar));
      expect(avatar.defaultMascot, isTrue, reason: '기본 마스코트 옵션이 켜져야 한다');
      expect(avatar.diameter, car ? 48 : 36, reason: '폰·차량 마커 크기를 유지한다');
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as AssetImage).assetName,
        'assets/avatars/mascot-01.png',
        reason: '카드와 같은 1번 마스코트를 쓴다',
      );
      final decoration =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(MemberAvatar),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      expect(
        (decoration.border! as Border).top.color,
        rainbowColor(4),
        reason: '입장 순서의 무지개 색을 유지한다',
      );
      expect(
        (decoration.border! as Border).top.width,
        3,
        reason: '테두리는 기존 3dp다',
      );
      for (final transform in tester.widgetList<Transform>(
        find.descendant(
          of: find.byType(RoomCarMarker),
          matching: find.byType(Transform),
        ),
      )) {
        expect(
          transform.transform.entry(1, 0),
          0,
          reason: '기본 마스코트와 이름표는 heading 123도에도 회전하지 않는다',
        );
      }
      expect(find.text('앨리스'), findsOneWidget, reason: '표시 이름 배지를 유지한다');
      expect(tester.takeException(), isNull, reason: '폰·차량 마커 렌더링에 예외가 없어야 한다');
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('사진 디코딩 실패 시 네이버 캡처의 차 아이콘 fallback을 유지한다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: testIconBuilder,
        home: Scaffold(
          body: Center(
            child: RoomCarMarker(
              position: RoomMapPosition(
                _fix('alice', 37, 127, heading: 123),
                displayName: '앨리스',
                avatar: const Avatar(kind: 'photo', version: 2),
              ),
              self: false,
              avatarLoadFailed: true,
              rotateHeading: false,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(MemberAvatar), findsNothing, reason: '실패한 사진은 캡처하지 않는다');
    expect(
      find.byWidgetPredicate(
        (widget) => widget is UnavoIcon && widget.name == 'car',
      ),
      findsOneWidget,
      reason: '사진 로드 실패에 한해 기존 차 아이콘 fallback을 쓴다',
    );
    final transform = tester.widget<Transform>(
      find.descendant(
        of: find.byType(RoomCarMarker),
        matching: find.byType(Transform),
      ),
    );
    expect(
      transform.transform.entry(1, 0),
      0,
      reason: '네이버 fallback 캡처에도 heading을 중복 적용하지 않는다',
    );
    expect(find.text('앨리스'), findsOneWidget, reason: '사진 실패에도 이름표를 유지한다');
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('기본 마스코트는 네이버 캡처 전에 디코딩하고 기존 null 디코딩은 유지한다', (tester) async {
    const member = Member('alice', '앨리스', '');
    final unchanged = await decodeAvatar(member, bundle: rootBundle);
    expect(unchanged, isNull, reason: '옵션을 켜지 않은 기존 호출자는 null 프로필을 디코딩하지 않는다');
    final decoded = await tester.runAsync(
      () => decodeAvatar(member, bundle: rootBundle, defaultMascot: true),
    );
    try {
      expect(decoded, isNotNull, reason: '미설정 프로필도 네이버 캡처 전에 마스코트 픽셀을 준비한다');
      expect(decoded!.width, 256, reason: '기존 아바타 디코딩 크기를 유지한다');
      expect(decoded.height, 256, reason: '기존 아바타 디코딩 크기를 유지한다');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RoomCarMarker(
                position: RoomMapPosition(
                  _fix('alice', 37, 127),
                  displayName: '앨리스',
                ),
                self: false,
                avatarImage: decoded,
                rotateHeading: false,
              ),
            ),
          ),
        ),
      );
      final avatar = tester.widget<MemberAvatar>(find.byType(MemberAvatar));
      expect(
        avatar.imageResolved,
        isTrue,
        reason: '완성된 이미지로 캡처해야 빈 첫 프레임을 저장하지 않는다',
      );
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        same(decoded),
        reason: '기본 마스코트의 디코딩 결과를 그대로 캡처한다',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      decoded?.dispose();
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
