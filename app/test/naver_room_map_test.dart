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
import 'package:unavo/ui/member_colors.dart';
import 'package:unavo/ui/widgets/member_avatar.dart';

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

  test('나·상대 프로필은 회전하지 않으며 크기·투명도·GPS anchor·순서를 유지한다', () {
    for (final car in [false, true]) {
      for (final self in [false, true]) {
        final style = RoomMarkerStyle(self: self, car: car);
        final marker = roomNaverMarker(
          handle: 'alice',
          fix: _fix('alice', 37, 127, heading: 123),
          icon: const NOverlayImage.fromAssetImage('profile.png'),
          self: self,
          car: car,
        );
        expect(marker.alpha, self ? 1 : .55);
        expect(marker.globalZIndex, self ? 300000 : 200000);
        expect(style.diameter, car ? 32 : 28);
        expect(style.directionDiameter, car ? 56 : 50);
        expect(marker.size, style.size);
        expect(marker.anchor.x, .5);
        expect(marker.anchor.y * marker.size.height, style.diameter / 2);
        expect(marker.isFlat, isFalse, reason: '지도 회전·tilt에도 프로필을 똑바로 세운다');
        expect(marker.angle, 0);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('별도 방향 마커는 계산된 방향만 표시하고 지도 회전·기울임에 보정한다', () {
    const icon = NOverlayImage.fromAssetImage('direction.png');
    for (final self in [false, true]) {
      for (final direction in <double?>[null, 0, 90, 180, 270]) {
        final marker = roomNaverDirectionMarker(
          handle: 'alice',
          fix: _fix('alice', 37, 127, heading: 0),
          icon: icon,
          self: self,
          car: true,
          direction: direction,
          cameraBearing: 90,
          cameraTilt: 50,
        );
        expect(marker.isVisible, direction != null);
        expect(marker.isFlat, isFalse, reason: 'tilt에도 삼각형이 프로필 안으로 눕지 않는다');
        expect(marker.anchor, NPoint.relativeCenter);
        expect(marker.size, const Size.square(56));
        expect(marker.alpha, self ? 1 : .55);
        expect(marker.globalZIndex, self ? 300001 : 200001);
        if (direction != null) {
          expect(
            marker.angle,
            closeTo(
              roomScreenDirection(direction, cameraBearing: 90, cameraTilt: 50),
              .001,
            ),
          );
        }
        marker.setAngle(123);
        expect(marker.icon, same(icon), reason: '각도 변경은 비트맵을 교체하지 않는다');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('나·상대의 미설정 프로필은 기본 마스코트와 입장 색을 쓰며 회전하지 않는다', (tester) async {
    final position = RoomMapPosition(
      _fix('alice', 37, 127, heading: 123),
      displayName: '아주 긴 표시 이름도 프로필보다 넓어지지 않음',
      order: 4,
    );
    for (final self in [false, true]) {
      for (final car in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: RoomCarMarker(position: position, self: self, car: car),
              ),
            ),
          ),
        );
        final style = RoomMarkerStyle(self: self, car: car);
        final avatar = tester.widget<MemberAvatar>(find.byType(MemberAvatar));
        expect(avatar.defaultMascot, isTrue);
        expect(avatar.diameter, car ? 32 : 28);
        expect(
          tester.getSize(find.byType(MemberAvatar)),
          Size.square(style.diameter),
        );
        expect(tester.getSize(find.byType(RoomCarMarker)), style.size);
        final image = tester.widget<Image>(find.byType(Image));
        expect(
          (image.image as AssetImage).assetName,
          'assets/avatars/mascot-01.png',
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
        expect((decoration.border! as Border).top.color, rainbowColor(4));
        expect((decoration.border! as Border).top.width, 3);
        expect(
          tester.widget<Opacity>(find.byType(Opacity)).opacity,
          self ? 1 : .55,
        );
        for (final transform in tester.widgetList<Transform>(
          find.descendant(
            of: find.byType(RoomCarMarker),
            matching: find.byType(Transform),
          ),
        )) {
          expect(transform.transform.entry(1, 0), 0);
          expect(transform.transform.entry(0, 1), 0);
        }
        if (self) {
          expect(find.text(position.name), findsNothing);
        } else {
          expect(
            tester.getSize(find.text(position.name)).width,
            lessThanOrEqualTo(style.diameter),
          );
          expect(
            tester.getRect(find.text(position.name)).top,
            greaterThan(tester.getRect(find.byType(MemberAvatar)).bottom),
          );
          expect(
            tester.widget<Text>(find.text(position.name)).style!.fontSize,
            9,
          );
        }
        expect(
          find.byType(RoomDirectionIndicator),
          findsNothing,
          reason: '방향은 프로필 비트맵에 포함하지 않는다',
        );
        expect(tester.takeException(), isNull);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('사진 실패 시 나·상대 모두 기본 마스코트를 표시한다', (tester) async {
    for (final self in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RoomCarMarker(
                position: RoomMapPosition(
                  _fix('alice', 37, 127, heading: 123),
                  displayName: '앨리스',
                  avatar: const Avatar(kind: 'photo', version: 2),
                ),
                self: self,
                avatarLoadFailed: true,
              ),
            ),
          ),
        ),
      );
      final avatar = tester.widget<MemberAvatar>(find.byType(MemberAvatar));
      expect(avatar.member.avatar.kind, isNull);
      expect(
        (tester.widget<Image>(find.byType(Image)).image as AssetImage)
            .assetName,
        'assets/avatars/mascot-01.png',
      );
      expect(tester.takeException(), isNull);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('나·상대의 사진·마스코트 픽셀은 캡처 전에 해석되며 회전하지 않는다', (tester) async {
    const member = Member('alice', '앨리스', '');
    expect(await decodeAvatar(member, bundle: rootBundle), isNull);
    final decoded = await tester.runAsync(
      () => decodeAvatar(member, bundle: rootBundle, defaultMascot: true),
    );
    try {
      expect(decoded, isNotNull);
      expect(decoded!.width, 256);
      expect(decoded.height, 256);
      for (final self in [true, false]) {
        for (final kind in ['photo', 'mascot-05']) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: RoomCarMarker(
                    position: RoomMapPosition(
                      _fix('alice', 37, 127, heading: 90),
                      displayName: '앨리스',
                      avatar: Avatar(kind: kind, version: 2),
                      order: 5,
                    ),
                    self: self,
                    avatarImage: decoded,
                    applyOpacity: false,
                  ),
                ),
              ),
            ),
          );
          final avatar = tester.widget<MemberAvatar>(find.byType(MemberAvatar));
          expect(avatar.member.avatar.kind, kind);
          expect(avatar.member.order, 5);
          expect(avatar.imageResolved, isTrue);
          expect(
            tester.widget<RawImage>(find.byType(RawImage)).image,
            same(decoded),
          );
          expect(
            tester.widget<Opacity>(find.byType(Opacity)).opacity,
            1,
            reason: 'SDK alpha와 중복 적용하지 않는다',
          );
          final transform = tester.widget<Transform>(
            find.descendant(
              of: find.byType(MemberAvatar),
              matching: find.byType(Transform),
            ),
          );
          expect(transform.transform.entry(1, 0), 0);
          expect(transform.transform.entry(0, 1), 0);
          expect(
            transform.transform.entry(0, 0),
            kind == 'mascot-05' ? .82 : 1,
          );
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      decoded?.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('삼각형만 별도 회전하며 폰50·차량56dp 안에서 그린다', (tester) async {
    for (final car in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RoomDirectionIndicator(
              direction: 90,
              color: rainbowColor(3),
              self: false,
              car: car,
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(RoomDirectionIndicator)),
        Size.square(car ? 56 : 50),
      );
      final transform = tester.widget<Transform>(
        find.descendant(
          of: find.byType(RoomDirectionIndicator),
          matching: find.byType(Transform),
        ),
      );
      expect(transform.transform.entry(1, 0), closeTo(1, .00001));
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(RoomDirectionIndicator),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as RoomDirectionPainter;
      expect(painter.color, rainbowColor(3));
      expect(painter.car, car);
      expect(find.byType(MemberAvatar), findsNothing);
      expect(tester.takeException(), isNull);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('방향 삼각형은 흰 2dp 외곽선·옅은 대비선을 그리며 프로필과 2dp 떨어진다', () {
    for (final car in [false, true]) {
      final style = RoomMarkerStyle(self: false, car: car);
      final painter = RoomDirectionPainter(color: rainbowColor(1), car: car);
      void paint(Canvas canvas) => painter.paint(canvas, style.directionSize);
      expect(
        paint,
        paints
          ..path(
            color: const Color(0x26000000),
            strokeWidth: 3,
            style: PaintingStyle.stroke,
          )
          ..path(
            color: Colors.white,
            strokeWidth: 2,
            style: PaintingStyle.stroke,
          )
          ..path(color: rainbowColor(1), style: PaintingStyle.fill),
      );
      expect(
        paint,
        paints..something((method, arguments) {
          if (method != #drawPath) return false;
          final path = arguments[0] as Path;
          final stroke = arguments[1] as Paint;
          expect(
            path.getBounds().size,
            car ? const Size(12, 7) : const Size(10, 6),
          );
          expect(stroke.strokeJoin, StrokeJoin.round);
          final bounds = path.getBounds().inflate(stroke.strokeWidth / 2);
          final profileTop = (style.directionDiameter - style.diameter) / 2;
          expect(profileTop - bounds.bottom, closeTo(2, .001));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(style.directionDiameter));
          final center = style.directionSize.center(Offset.zero);
          final edge = path.computeMetrics().single;
          for (var offset = 0.0; offset < edge.length; offset += .5) {
            final radius =
                (edge.getTangentForOffset(offset)!.position - center).distance;
            expect(
              radius + stroke.strokeWidth / 2,
              lessThanOrEqualTo(style.directionDiameter / 2 + .001),
              reason: '어느 각도로 회전해도 외곽선이 잘리지 않는다',
            );
            expect(
              radius - stroke.strokeWidth / 2 - style.diameter / 2,
              greaterThanOrEqualTo(2 - .001),
              reason: '회전 후에도 프로필과 2dp 이상 떨어진다',
            );
          }
          return true;
        }),
      );
      for (final self in [false, true]) {
        final profile = RoomMarkerStyle(self: self, car: car);
        final profileBounds = (Offset.zero & profile.size).shift(
          -Offset(
            profile.size.width * profile.anchor.dx,
            profile.size.height * profile.anchor.dy,
          ),
        );
        final bounds = profileBounds.expandToInclude(
          Rect.fromCircle(
            center: Offset.zero,
            radius: style.directionDiameter / 2,
          ),
        );
        expect(bounds.width, lessThanOrEqualTo(56));
        expect(
          bounds.height,
          lessThanOrEqualTo(56),
          reason: 'GPS에 맞춰 겹친 방향·프로필·이름표 전체',
        );
      }
    }
  });

  test('프로필 캐시는 사진 버전·색을 구분하고 위치·heading 유무·각도는 무시한다', () async {
    RoomMarkerKey key({
      String? kind = 'photo',
      int version = 1,
      int order = 0,
      double lat = 37,
      double? heading,
      bool self = false,
    }) => roomMarkerCacheKey(
      position: RoomMapPosition(
        _fix('alice', lat, 127, heading: heading),
        displayName: '앨리스',
        avatar: Avatar(kind: kind, version: version),
        order: order,
      ),
      self: self,
      brightness: Brightness.dark,
      car: false,
    );
    expect(key(), isNot(key(kind: 'mascot-01')));
    expect(key(), isNot(key(version: 2)));
    expect(key(), isNot(key(order: 1)));
    expect(key(), isNot(key(self: true)));
    expect(key(), key(lat: 38));
    expect(key(), key(order: 7));
    expect(key().$8, rainbowColor(0));
    for (final self in [false, true]) {
      final cache = RoomMarkerIconCache();
      var captures = 0;
      for (final heading in <double?>[null, 0, 90, 180, 270, null]) {
        final next = key(heading: heading, self: self);
        expect(next, key(self: self));
        await cache.load(next, () async {
          captures++;
          return (
            icon: const NOverlayImage.fromAssetImage('profile.png'),
            failed: false,
          );
        });
      }
      expect(captures, 1);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('내비 줌 기본·상한18 하한14와 거리별 경계를 유지한다', () {
    expect(RoomFollowCameraPolicy.navigationZoom, 18);
    expect(RoomFollowCameraPolicy.minimumZoom, 14);
    expect(RoomFollowCameraPolicy.maximumZoom, 18);
    for (final (meters, zoom) in <(double, double)>[
      (0, 18),
      (199.99, 18),
      (200, 17),
      (599.99, 17),
      (600, 16),
      (1499.99, 16),
      (1500, 15),
      (3999.99, 15),
      (4000, 14),
      (100000, 14),
    ]) {
      expect(zoomForDistance(meters), zoom, reason: '$meters m');
    }
  });

  test('따라가기 카메라는 내 위치 중심·거리 줌·계산된 방향·tilt50을 사용한다', () {
    final self = _fix('self', 0, 0, heading: 0);
    for (final (latitude, zoom) in <(double, double)>[
      (.001, 18),
      (.003, 17),
      (.01, 16),
      (.02, 15),
      (.05, 14),
    ]) {
      final camera = naverFollowCamera(
        self: self,
        leader: _fix('leader', latitude, 0),
        direction: 123,
        currentBearing: 280,
      )!;
      expect(camera.target, same(self));
      expect(camera.zoom, zoom);
      expect(camera.tilt, 50);
      expect(camera.bearing, 123);
    }
  });

  test('이동 방향을 모르면 센서 heading·대상 위치를 추측하지 않고 현재 방위를 유지한다', () {
    final self = _fix('self', 0, 0, heading: 0);
    for (final leader in <LocationFix?>[null, _fix('leader', 0, .001)]) {
      final camera = naverFollowCamera(
        self: self,
        leader: leader,
        currentBearing: 217.5,
      )!;
      expect(camera.bearing, 217.5);
    }
    expect(
      naverFollowCamera(
        self: self,
        leader: null,
        direction: 360,
        currentBearing: 217.5,
      )!.bearing,
      0,
    );
  });

  test('그룹장 본인·상대 위치 없음은 내 위치·줌18을 사용한다', () {
    final self = _fix('leader', 37.5, 127, heading: 0);
    for (final leader in <LocationFix?>[self, null]) {
      final camera = naverFollowCamera(
        self: self,
        leader: leader,
        direction: 45,
        currentBearing: 180,
        isLeader: leader != null,
      )!;
      expect(camera.target, self);
      expect(camera.zoom, 18);
      expect(camera.bearing, 45);
    }
    expect(
      naverFollowCamera(self: null, leader: self, currentBearing: 80),
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
