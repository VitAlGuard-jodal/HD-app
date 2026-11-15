import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unavo/location/meeting_plan_controller.dart';
import 'package:unavo/map/naver_room_map.dart';
import 'package:unavo/map/room_map_geometry.dart';
import 'package:unavo/map/vworld_room_map.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/net/follow_route.dart';

import 'support/follow_route_fakes.dart';

class CameraFake implements NaverMapController {
  NCameraPosition position = const NCameraPosition(
    target: NLatLng(0, 0),
    zoom: 17,
    tilt: 35,
    bearing: 40,
  );
  final updates = <NCameraUpdate>[];
  final overlays = <NAddableOverlay>[];
  Completer<NCameraPosition>? nextPosition;
  Completer<bool>? nextUpdate;
  int cancellations = 0;
  @override
  Stream<OnCameraChangedParams> get nowCameraPositionStream =>
      const Stream.empty();
  @override
  Future<NCameraPosition> getCameraPosition() async {
    final pending = nextPosition;
    nextPosition = null;
    return pending == null ? position : pending.future;
  }

  @override
  Future<NPoint> latLngToScreenLocation(NLatLng point) async => NPoint(
    200 + (point.longitude - position.target.longitude) * metersPerDegree,
    200 - (point.latitude - position.target.latitude) * metersPerDegree,
  );
  @override
  Future<void> addOverlay(NAddableOverlay overlay) async =>
      overlays.add(overlay);
  @override
  Future<void> cancelTransitions({
    NCameraUpdateReason reason = NCameraUpdateReason.developer,
  }) async {
    cancellations++;
  }

  @override
  Future<bool> updateCamera(NCameraUpdate update) async {
    updates.add(update);
    final values = update.toNPayload().map;
    final target = values['target'] as Map?;
    position = NCameraPosition(
      target: target == null
          ? position.target
          : NLatLng(
              (target['lat'] as num).toDouble(),
              (target['lng'] as num).toDouble(),
            ),
      zoom: (values['zoom'] as num?)?.toDouble() ?? position.zoom,
      tilt: (values['tilt'] as num?)?.toDouble() ?? position.tilt,
      bearing: (values['bearing'] as num?)?.toDouble() ?? position.bearing,
    );
    final pending = nextUpdate;
    nextUpdate = null;
    return pending == null ? true : pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class NaverRig {
  final controller = NaverRoomMapController();
  final camera = CameraFake();
  late NaverMap map;
  Future<void> show(
    WidgetTester tester,
    LocationFix self, {
    bool following = false,
    bool paused = false,
    LocationFix? target,
    List<MeetingPin> pins = const [],
    Map<String, RoomMapPosition>? positions,
    ValueChanged<RoutePoint>? onPointSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: NaverRoomMap(
              controller: controller,
              positions:
                  positions ??
                  {
                    'self': RoomMapPosition(self, displayName: '나'),
                    if (target != null)
                      target.handle: RoomMapPosition(target, displayName: '앞차'),
                  },
              trail: const [],
              targetHandle: target?.handle,
              selfHandle: 'self',
              following: following,
              brightness: Brightness.light,
              pauseAutoCamera: paused,
              meetingPins: pins,
              onPointSelected: onPointSelected,
              mapBuilder: (value) {
                map = value;
                return const ColoredBox(
                  key: ValueKey('map-surface'),
                  color: Colors.transparent,
                  child: SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'R22b.1 Naver restores aligned bearing after a stationary manual rotation',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.map.onMapReady!(f.camera);
      f.controller.alignHeading(true);
      await tester.pump();
      await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.position.bearing, closeTo(90, .01));
      final target = f.camera.position.target;
      f.camera.position = NCameraPosition(
        target: target,
        zoom: 17,
        tilt: 35,
        bearing: 180,
      );
      f.camera.updates.clear();
      f.map.onCameraChange!(NCameraUpdateReason.gesture, false);
      await f.show(tester, testFix(20, handle: 'self', seq: 2, speed: 0));
      await tester.pump(const Duration(milliseconds: 4999));
      expect(f.camera.updates, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      // Drain the existing camera throttle (Stopwatch is not the widget clock).
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.position.bearing, closeTo(90, .01));
      expect(f.camera.updates, hasLength(1));
      expect(f.camera.updates.single.toNPayload().map['target'], isNull);
      expect(f.camera.position.target, target);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22b.1 Naver updates heading without recentering and combines both when needed',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.map.onMapReady!(f.camera);
      f.controller.alignHeading(true);
      await tester.pump();
      await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
      await tester.pump(const Duration(milliseconds: 1100));
      f.camera.updates.clear();
      await f.show(tester, testFix(20, y: 4, handle: 'self', seq: 2, speed: 0));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.updates, hasLength(1));
      expect(f.camera.updates.single.toNPayload().map['target'], isNull);
      expect(f.camera.position.bearing, closeTo(0, .01));
      f.camera.updates.clear();
      await f.show(
        tester,
        testFix(40, y: 4, handle: 'self', seq: 3, speed: 20),
      );
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.updates, hasLength(1));
      expect(f.camera.updates.single.toNPayload().map['target'], isNotNull);
      expect(f.camera.position.bearing, closeTo(90, .01));
      await f.show(tester, testFix(40, y: 4, handle: 'self', seq: 4, speed: 0));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(
        f.camera.updates,
        hasLength(1),
        reason: 'same bearing is not resent',
      );
      final target = f.camera.position.target;
      f.camera.position = NCameraPosition(
        target: target,
        zoom: 17,
        tilt: 35,
        bearing: 180,
      );
      f.camera.updates.clear();
      await f.show(
        tester,
        testFix(40, y: 8, handle: 'self', seq: 5, speed: 0),
        paused: true,
      );
      await tester.pump(const Duration(seconds: 6));
      expect(f.camera.updates, isEmpty);
      await f.show(tester, testFix(40, y: 8, handle: 'self', seq: 5, speed: 0));
      await tester.pump(const Duration(milliseconds: 4999));
      expect(f.camera.updates, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.updates, hasLength(1));
      expect(f.camera.updates.single.toNPayload().map['target'], isNull);
      expect(f.camera.position.bearing, closeTo(0, .01));
      expect(f.camera.position.target, target);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22b.1 VWorld restores heading on resume and on direction change without recentering',
    (tester) async {
      final controller = VworldRoomMapController();
      Future<void> show(LocationFix self, {bool paused = false}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VworldRoomMap(
              controller: controller,
              positions: {'self': RoomMapPosition(self, displayName: '나')},
              trail: const [],
              targetHandle: null,
              selfHandle: 'self',
              following: false,
              brightness: Brightness.light,
              pauseAutoCamera: paused,
            ),
          ),
        );
        await tester.pump();
      }

      FlutterMap map() => tester.widget<FlutterMap>(find.byType(FlutterMap));
      await show(testFix(0, handle: 'self', speed: 0));
      controller.alignHeading(true);
      await show(testFix(20, handle: 'self', seq: 1, speed: 20));
      final target = map().mapController!.camera.center;
      map().mapController!.rotate(180);
      map().options.onPositionChanged!(map().mapController!.camera, true);
      await show(testFix(20, handle: 'self', seq: 2, speed: 0));
      await tester.pump(const Duration(milliseconds: 4999));
      expect(map().mapController!.camera.rotation % 360, 180);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(map().mapController!.camera.rotation % 360, closeTo(270, .01));
      await show(testFix(20, y: 4, handle: 'self', seq: 3, speed: 0));
      expect(map().mapController!.camera.rotation % 360, closeTo(0, .01));
      expect(map().mapController!.camera.center, target);
      map().mapController!.rotate(180);
      await show(
        testFix(24, y: 4, handle: 'self', seq: 4, speed: 0),
        paused: true,
      );
      await tester.pump(const Duration(seconds: 6));
      expect(map().mapController!.camera.rotation % 360, 180);
      await show(testFix(24, y: 4, handle: 'self', seq: 4, speed: 0));
      await tester.pump(const Duration(milliseconds: 4999));
      expect(map().mapController!.camera.rotation % 360, 180);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(map().mapController!.camera.rotation % 360, closeTo(270, .01));
      expect(map().mapController!.camera.center, target);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22b.2 VWorld resets self-camera reference when following ends',
    (tester) async {
      final controller = VworldRoomMapController();
      Future<void> show(double x, int seq, bool following) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VworldRoomMap(
              controller: controller,
              positions: {
                'self': RoomMapPosition(
                  testFix(x, handle: 'self', seq: seq, speed: 0),
                  displayName: '나',
                ),
              },
              trail: const [],
              targetHandle: null,
              selfHandle: 'self',
              following: following,
              brightness: Brightness.light,
            ),
          ),
        );
        await tester.pump();
      }

      FlutterMap map() => tester.widget<FlutterMap>(find.byType(FlutterMap));
      await show(0, 0, true);
      await show(100, 1, true);
      // Leave the current camera close enough to keep the marker safely inside.
      final nearby = testPoint(105);
      map().mapController!.move(LatLng(nearby.lat, nearby.lng), 18);
      await show(100, 1, false);
      expect(
        map().mapController!.camera.center,
        LatLng(nearby.lat, nearby.lng),
      );
      await show(104, 2, false);
      expect(
        map().mapController!.camera.center,
        LatLng(nearby.lat, nearby.lng),
      );
      await show(111, 3, false);
      expect(
        map().mapController!.camera.center,
        LatLng(testPoint(111).lat, testPoint(111).lng),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'R22 a late Naver ready event cannot rotate during a held gesture',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.controller.alignHeading(true);
      await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('map-surface'))),
      );
      f.map.onMapReady!(f.camera);
      await tester.pump();
      expect(f.camera.updates, isEmpty);
      await gesture.cancel();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22 tapping during a leader camera animation cancels that transition',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.map.onMapReady!(f.camera);
      await tester.pump();
      final pending = Completer<bool>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(false);
      });
      f.camera.nextUpdate = pending;
      await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.updates, hasLength(1));
      f.map.onMapTapped!(const NPoint(200, 200), const NLatLng(0, 0));
      expect(f.camera.cancellations, 1);
      pending.complete(false);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22 multiple held pointers prevent resume until five seconds after the last release',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.map.onMapReady!(f.camera);
      await tester.pump();
      final center = tester.getCenter(
        find.byKey(const ValueKey('map-surface')),
      );
      final first = await tester.startGesture(center, pointer: 1);
      final second = await tester.startGesture(
        center + const Offset(20, 0),
        pointer: 2,
      );
      await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
      await tester.pump(const Duration(seconds: 6));
      expect(f.camera.updates, isEmpty);
      await first.cancel();
      await tester.pump(const Duration(seconds: 6));
      expect(f.camera.updates, isEmpty);
      await second.cancel();
      await tester.pump(const Duration(milliseconds: 4999));
      expect(f.camera.updates, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        f.camera.position.target,
        NLatLng(testPoint(20).lat, testPoint(20).lng),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'R22 Naver tracks a moving leader while retaining zoom, tilt and unaligned bearing',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.map.onMapReady!(f.camera);
      await tester.pump();
      for (var n = 1; n <= 2; n++) {
        await f.show(
          tester,
          testFix(n * 20, handle: 'self', seq: n, speed: 20),
        );
        await tester.pump(const Duration(milliseconds: 1100));
        final point = testPoint(n * 20);
        expect(f.camera.position.target, NLatLng(point.lat, point.lng));
        expect(f.camera.position.zoom, 17);
        expect(f.camera.position.tilt, 35);
        expect(f.camera.position.bearing, 40);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22 VWorld tracks a moving leader without following another vehicle',
    (tester) async {
      final controller = VworldRoomMapController();
      Future<void> show(LocationFix self) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 400,
              height: 400,
              child: VworldRoomMap(
                controller: controller,
                positions: {'self': RoomMapPosition(self, displayName: '나')},
                trail: const [],
                targetHandle: null,
                selfHandle: 'self',
                following: false,
                brightness: Brightness.light,
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await show(testFix(0, handle: 'self', speed: 0));
      await show(testFix(20, handle: 'self', seq: 1, speed: 20));
      final camera = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!
          .camera;
      final point = testPoint(20);
      expect(camera.center, LatLng(point.lat, point.lng));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'R22 Naver editor suppresses resume timers and resumes five seconds after closing',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0), paused: true);
      f.map.onMapReady!(f.camera);
      f.controller.moveTo(testPoint(500).lat, testPoint(500).lng);
      await tester.pump();
      final selected = f.camera.position.target;
      await f.show(
        tester,
        testFix(20, handle: 'self', seq: 1, speed: 20),
        paused: true,
      );
      await tester.pump(const Duration(seconds: 6));
      expect(f.camera.position.target, selected);
      await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
      await tester.pump(const Duration(milliseconds: 4999));
      expect(f.camera.position.target, selected);
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        f.camera.position.target,
        NLatLng(testPoint(20).lat, testPoint(20).lng),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22 entering the editor cancels an in-flight Naver camera query',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.map.onMapReady!(f.camera);
      await tester.pump();
      final pending = Completer<NCameraPosition>();
      f.camera.nextPosition = pending;
      await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
      await tester.pump(const Duration(milliseconds: 1100));
      await f.show(
        tester,
        testFix(40, handle: 'self', seq: 2, speed: 20),
        paused: true,
      );
      pending.complete(f.camera.position);
      await tester.pump(const Duration(seconds: 6));
      expect(f.camera.updates, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22 VWorld editor holds a selected point beyond the resume timeout',
    (tester) async {
      final controller = VworldRoomMapController();
      Future<void> show(bool paused, double x, int seq) async {
        await tester.pumpWidget(
          MaterialApp(
            home: VworldRoomMap(
              controller: controller,
              positions: {
                'self': RoomMapPosition(
                  testFix(x, handle: 'self', seq: seq, speed: 20),
                  displayName: '나',
                ),
              },
              trail: const [],
              targetHandle: null,
              selfHandle: 'self',
              following: false,
              brightness: Brightness.light,
              pauseAutoCamera: paused,
            ),
          ),
        );
        await tester.pump();
      }

      LatLng center() => tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!
          .camera
          .center;
      await show(true, 0, 0);
      controller.moveTo(testPoint(500).lat, testPoint(500).lng);
      await tester.pump();
      final selected = center();
      await show(true, 20, 1);
      await tester.pump(const Duration(seconds: 6));
      expect(center(), selected);
      await show(false, 20, 1);
      await tester.pump(const Duration(milliseconds: 4999));
      expect(center(), selected);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(center(), LatLng(testPoint(20).lat, testPoint(20).lng));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final interaction in ['pan', 'tap', 'long press']) {
    testWidgets(
      'R22 Naver $interaction pauses leader tracking for five seconds',
      (tester) async {
        final f = NaverRig();
        RoutePoint? picked;
        await f.show(
          tester,
          testFix(0, handle: 'self', speed: 0),
          onPointSelected: (p) => picked = p,
        );
        f.map.onMapReady!(f.camera);
        await tester.pump();
        if (interaction == 'pan') {
          f.map.onCameraChange!(NCameraUpdateReason.gesture, false);
        } else if (interaction == 'tap') {
          expect(f.map.onMapTapped, isNotNull);
          f.map.onMapTapped!(const NPoint(200, 200), const NLatLng(0, 0));
        } else {
          f.map.onMapLongTapped!(const NPoint(200, 200), const NLatLng(0, .01));
          expect(picked, const RoutePoint(0, .01));
        }
        await f.show(tester, testFix(20, handle: 'self', seq: 1, speed: 20));
        await tester.pump(const Duration(milliseconds: 4999));
        expect(f.camera.updates, isEmpty);
        await tester.pump(const Duration(milliseconds: 1));
        expect(
          f.camera.position.target,
          NLatLng(testPoint(20).lat, testPoint(20).lng),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'R22 Naver pending and recommendation pins register native tap interaction',
    (tester) async {
      final f = NaverRig();
      await f.show(
        tester,
        testFix(0, handle: 'self'),
        paused: true,
        positions: {},
        pins: [
          MeetingPin('pending', testPoint(500), '후보 확인', draft: true),
          MeetingPin('recommendation', testPoint(800), '추천 결과', draft: true),
        ],
      );
      f.map.onMapReady!(f.camera);
      await tester.pump();
      await tester.pump();
      final markers = f.camera.overlays.whereType<NMarker>().toList();
      expect(markers, hasLength(2));
      for (final marker in markers) {
        expect(marker.toNPayload().map['hasOnTapListener'], isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22 Naver stationary jitter does not recenter while aligned heading can rotate',
    (tester) async {
      final f = NaverRig();
      await f.show(tester, testFix(0, handle: 'self', speed: 0));
      f.map.onMapReady!(f.camera);
      f.controller.alignHeading(true);
      await tester.pump();
      var seq = 0;
      for (final x in [1.0, -1.0, 4.0, -4.0, 2.0, 0.0]) {
        await f.show(tester, testFix(x, handle: 'self', seq: ++seq, speed: 0));
        await tester.pump(const Duration(milliseconds: 1100));
      }
      expect(
        f.camera.updates.where((u) => u.toNPayload().map['target'] != null),
        isEmpty,
      );
      expect(f.camera.position.target, const NLatLng(0, 0));
      f.camera.updates.clear();
      await f.show(tester, testFix(11, handle: 'self', seq: ++seq, speed: 0));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.updates, hasLength(1));
      expect(
        f.camera.position.target,
        NLatLng(testPoint(11).lat, testPoint(11).lng),
      );
      expect(f.camera.position.bearing, closeTo(90, .01));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'R22 Naver follower retains distance zoom, tilt and per-sample following',
    (tester) async {
      final f = NaverRig();
      final target = testFix(3000, handle: 'leader');
      await f.show(
        tester,
        testFix(0, handle: 'self', speed: 0),
        following: true,
        target: target,
      );
      f.map.onMapReady!(f.camera);
      f.controller.alignHeading(true);
      await tester.pump(const Duration(milliseconds: 1100));
      f.camera.updates.clear();
      await f.show(
        tester,
        testFix(20, handle: 'self', seq: 1, speed: 20),
        following: true,
        target: target,
      );
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.updates, hasLength(1));
      expect(f.camera.updates.single.toNPayload().map['target'], isNotNull);
      expect(f.camera.position.zoom, 15);
      expect(f.camera.position.tilt, 50);
      expect(f.camera.position.bearing, closeTo(90, .01));
      await f.show(
        tester,
        testFix(21, handle: 'self', seq: 2, speed: 0),
        following: true,
        target: target,
      );
      await tester.pump(const Duration(milliseconds: 1100));
      expect(f.camera.updates, hasLength(2));
      expect(
        f.camera.position.target,
        NLatLng(testPoint(21).lat, testPoint(21).lng),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'R22 camera thresholds suppress parked jitter and retain slow accumulated movement',
    () {
      final policy = RoomSelfCameraPolicy();
      const center = Offset(200, 200), size = Size(400, 400);
      policy.centered(testFix(0));
      expect(policy.needsCenter(testFix(2.9, speed: 2), center, size), isFalse);
      expect(policy.needsCenter(testFix(3.1, speed: 2), center, size), isTrue);
      expect(policy.needsCenter(testFix(5, speed: 0), center, size), isFalse);
      expect(policy.needsCenter(testFix(9.9), center, size), isFalse);
      expect(policy.needsCenter(testFix(10.1), center, size), isTrue);
      policy.centered(testFix(10.1));
      expect(
        policy.needsCenter(testFix(10.5, speed: 0), center, size),
        isFalse,
      );
    },
  );

  test(
    'R22 stationary self near any viewport edge is brought back into view',
    () {
      final policy = RoomSelfCameraPolicy()..centered(testFix(0));
      const size = Size(400, 400);
      for (final point in [
        const Offset(80, 200),
        const Offset(320, 200),
        const Offset(200, 80),
        const Offset(200, 320),
      ]) {
        expect(policy.needsCenter(testFix(0, speed: 0), point, size), isTrue);
      }
      expect(
        policy.needsCenter(testFix(0, speed: 0), const Offset(81, 319), size),
        isFalse,
      );
    },
  );
}
