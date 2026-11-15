import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/map/room_map_geometry.dart';
import 'package:unavo/net/models.dart';

LocationFix _fix(
  String handle,
  double north,
  double east, {
  int seq = 0,
  String stream = '0123456789abcdef',
  double? heading,
  double? speed,
}) => LocationFix(
  handle: handle,
  stream: stream,
  // 적도 부근에서 약 1 m를 0.000009도로 표현한다.
  lat: north * .000009,
  lng: east * .000009,
  at: seq * 1000,
  seq: seq,
  heading: heading,
  speed: speed,
);

void main() {
  test(
    'R22c default and enabled heading-up share the follower bearing rule',
    () {
      for (final enabled in [null, true]) {
        expect(
          roomCameraBearing(
            currentBearing: 217.5,
            direction: 90,
            headingAligned: enabled,
          ),
          90,
        );
        expect(
          roomCameraBearing(currentBearing: 217.5, headingAligned: enabled),
          217.5,
        );
      }
      expect(
        roomCameraBearing(
          currentBearing: 217.5,
          direction: 90,
          headingAligned: false,
        ),
        0,
      );
      expect(
        roomCameraBearing(currentBearing: 217.5, headingAligned: false),
        0,
      );
      expect(roomCameraBearing(currentBearing: 40, direction: 360), 0);
    },
  );
  test('첫 표본은 고속 heading이 있어도 방향을 추측하지 않는다', () {
    final directions = RoomDirectionTracker();
    directions.update([_fix('self', 0, 0, speed: 10, heading: 90)]);
    expect(directions['self'], isNull);
    expect(directions['missing'], isNull);
    expect(directions[null], isNull);
  });

  test('3 m 미만은 무시하고 기준점에서 누적 3 m 이상 이동하면 방위를 계산한다', () {
    final directions = RoomDirectionTracker();
    directions.update([_fix('self', 0, 0)]);
    directions.update([_fix('self', 0, 1, seq: 1)]);
    directions.update([_fix('self', 0, 2.9, seq: 2)]);
    expect(directions['self'], isNull);
    directions.update([_fix('self', 0, 3.1, seq: 3)]);
    expect(directions['self'], closeTo(90, .001));
    directions.update([_fix('self', 2, 3.1, seq: 4)]);
    expect(directions['self'], closeTo(90, .001));
    directions.update([_fix('self', 3.1, 3.1, seq: 5)]);
    expect(directions['self'], closeTo(0, .001));
  });

  test('정지·작은 흔들림에서는 heading이 바뀌어도 마지막 이동 방향을 유지한다', () {
    final directions = RoomDirectionTracker();
    directions.update([_fix('self', 0, 0)]);
    directions.update([_fix('self', 0, -5, seq: 1)]);
    for (var seq = 2; seq < 10; seq++) {
      directions.update([
        _fix('self', seq.isEven ? 1 : 0, -5, seq: seq, speed: 0, heading: 0),
      ]);
      expect(directions['self'], closeTo(270, .001));
    }
    directions.update([_fix('self', 0, -5, seq: 10, speed: 10, heading: 90)]);
    expect(directions['self'], closeTo(270, .001));
  });

  test('이동과 다른 heading 0은 고속에서도 무시하고 실제 북진 0은 허용한다', () {
    for (final (north, east, expected) in <(double, double, double)>[
      (0, 5, 90),
      (0, -5, 270),
      (-5, 0, 180),
      (5, 0, 0),
    ]) {
      final directions = RoomDirectionTracker();
      directions.update([_fix('self', 0, 0)]);
      directions.update([
        _fix('self', north, east, seq: 1, heading: 0, speed: 10),
      ]);
      expect(directions['self'], closeTo(expected, .001));
    }
  });

  test('heading은 1.5 m/s 이상이며 이동 방위와 45도 이내일 때만 20% 보조한다', () {
    for (final speed in <double?>[null, 0, 1.49, 1.5, 10]) {
      final directions = RoomDirectionTracker();
      directions.update([_fix('self', 0, 0)]);
      directions.update([
        _fix('self', 0, 5, seq: 1, heading: 100, speed: speed),
      ]);
      expect(directions['self'], closeTo((speed ?? 0) >= 1.5 ? 92 : 90, .001));
    }
    final directions = RoomDirectionTracker();
    directions.update([_fix('self', 0, 0)]);
    directions.update([_fix('self', 5, 0, seq: 1, heading: 350, speed: 10)]);
    expect(directions['self'], closeTo(358, .001), reason: '북쪽 경계에서 최단 각도 보간');
    directions.update([_fix('self', 5, 5, seq: 2, heading: 180, speed: 10)]);
    expect(directions['self'], closeTo(90, .001));
  });

  test('나·상대의 기준점은 독립적이고 중복·역순 표본은 방향을 바꾸지 않는다', () {
    final directions = RoomDirectionTracker();
    directions.update([_fix('self', 0, 0), _fix('other', 10, 10)]);
    final self = _fix('self', 0, 5, seq: 2);
    final other = _fix('other', 5, 10, seq: 2);
    directions.update([self, other]);
    expect(directions['self'], closeTo(90, .001));
    expect(directions['other'], closeTo(180, .001));
    directions.update([self, other]);
    directions.update([_fix('self', 20, 20, seq: 1), other]);
    expect(directions['self'], closeTo(90, .001));
    expect(directions['other'], closeTo(180, .001));
  });

  test('사라진 참여자와 새 stream은 이전 이동 기준·방향을 재사용하지 않는다', () {
    final directions = RoomDirectionTracker();
    directions.update([_fix('self', 0, 0)]);
    directions.update([_fix('self', 0, 5, seq: 1)]);
    directions.update([_fix('self', 30, 30, stream: 'fedcba9876543210')]);
    expect(directions['self'], isNull);
    directions.update([
      _fix('self', 35, 30, seq: 1, stream: 'fedcba9876543210'),
    ]);
    expect(directions['self'], closeTo(0, .001));
    directions.update([]);
    expect(directions['self'], isNull);
    directions.update([_fix('self', 100, 100)]);
    expect(directions['self'], isNull);
  });

  test('화면 방향은 지도 방위를 빼고 기울임을 투영하며 0~360도로 정규화한다', () {
    expect(roomScreenDirection(90, cameraBearing: 90), closeTo(0, .001));
    expect(roomScreenDirection(0, cameraBearing: 90), closeTo(270, .001));
    expect(roomScreenDirection(180, cameraBearing: 90), closeTo(90, .001));
    expect(roomScreenDirection(360), closeTo(0, .001));
    expect(roomScreenDirection(45, cameraTilt: 60), closeTo(63.4349, .001));
    expect(roomScreenDirection(135, cameraTilt: 60), closeTo(116.5651, .001));
    expect(
      roomScreenDirection(90, cameraBearing: 90, cameraTilt: 50),
      closeTo(0, .001),
    );
  });

  test('방향 필터 기준값은 정차 GPS 흔들림과 저속 heading을 걸러낸다', () {
    expect(RoomDirectionTracker.minimumMovementMeters, 3);
    expect(RoomDirectionTracker.minimumHeadingSpeed, 1.5);
    expect(RoomDirectionTracker.maximumHeadingDifference, 45);
    expect(RoomDirectionTracker.headingWeight, .2);
  });
}
