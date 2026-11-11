import 'package:flutter/material.dart';

import '../net/models.dart';
import 'map_provider.dart';
import 'map_tiles.dart';
import 'naver_room_map.dart';
import 'room_map_geometry.dart';
import 'vworld_room_map.dart';

export 'room_map_geometry.dart' show RoomMapPosition;

// 화면은 공급자의 카메라·좌표 타입을 알지 않는다.
abstract class RoomMapController {
  factory RoomMapController() = VworldRoomMapController;
  factory RoomMapController.create(MapProvider provider) => switch (provider) {
    MapProvider.naver => NaverRoomMapController(),
    MapProvider.vworld => VworldRoomMapController(),
  };
  void moveTo(double latitude, double longitude, {double zoom = 16});
  void follow();
  void recenter();
  void dispose();
}

class RoomMap extends StatelessWidget {
  const RoomMap({
    super.key,
    required this.controller,
    required this.positions,
    required this.trail,
    required this.leaderHandle,
    required this.selfHandle,
    required this.followLeader,
    required this.brightness,
    this.onInteraction,
    this.tiles,
    this.provider = MapProvider.vworld,
    this.authError,
  });
  final RoomMapController controller;
  final Map<String, RoomMapPosition> positions;
  final List<LocationFix> trail;
  final String? leaderHandle, selfHandle;
  final bool followLeader;
  final Brightness brightness;
  final VoidCallback? onInteraction;
  final MapTiles? tiles;
  final MapProvider provider;
  final String? authError;

  @override
  Widget build(BuildContext context) => switch (provider) {
    MapProvider.naver => NaverRoomMap(
      controller: controller as NaverRoomMapController,
      positions: positions,
      trail: trail,
      leaderHandle: leaderHandle,
      selfHandle: selfHandle,
      followLeader: followLeader,
      brightness: brightness,
      onInteraction: onInteraction,
      authError: authError,
    ),
    MapProvider.vworld => VworldRoomMap(
      controller: controller,
      positions: positions,
      trail: trail,
      leaderHandle: leaderHandle,
      selfHandle: selfHandle,
      followLeader: followLeader,
      brightness: brightness,
      onInteraction: onInteraction,
      tiles: tiles,
    ),
  };
}
