import 'package:flutter/material.dart';

import '../net/models.dart';
import '../location/follow_route_controller.dart';
import '../net/api_client.dart';
import 'map_provider.dart';
import 'map_tiles.dart';
import 'naver_room_map.dart';
import 'room_map_geometry.dart';
import 'room_map_widgets.dart';
import 'vworld_room_map.dart';

export 'room_map_geometry.dart' show RoomMapPosition;

// 화면은 공급자의 카메라·좌표 타입을 알지 않는다.
abstract class RoomMapController {
  factory RoomMapController() = VworldRoomMapController;
  factory RoomMapController.create(MapProvider provider) => switch (provider) {
    MapProvider.naver => NaverRoomMapController(),
    MapProvider.vworld => VworldRoomMapController(),
  };
  void moveTo(
    double latitude,
    double longitude, {
    double zoom = RoomFollowCameraPolicy.navigationZoom,
  });
  void follow();
  void recenter();
  void alignHeading(bool enabled);
  void dispose();
}

class RoomMap extends StatefulWidget {
  const RoomMap({
    super.key,
    required this.controller,
    required this.positions,
    required this.trail,
    required this.targetHandle,
    required this.selfHandle,
    required this.following,
    required this.brightness,
    this.onInteraction,
    this.tiles,
    this.provider = MapProvider.vworld,
    this.authError,
    this.car = false,
    this.fullscreen = false,
    this.onFullscreen,
    this.onStopSharing,
    this.api,
    this.guidance,
    this.onModeChanged,
    this.onResetGuidance,
  });
  final RoomMapController controller;
  final ApiClient? api;
  final FollowRouteView? guidance;
  final ValueChanged<FollowMode>? onModeChanged;
  final VoidCallback? onResetGuidance;
  final Map<String, RoomMapPosition> positions;
  final List<LocationFix> trail;
  final String? targetHandle, selfHandle;
  final bool following;
  final Brightness brightness;
  final VoidCallback? onInteraction;
  final MapTiles? tiles;
  final MapProvider provider;
  final String? authError;
  final bool car, fullscreen;
  final VoidCallback? onFullscreen, onStopSharing;

  @override
  State<RoomMap> createState() => _RoomMapState();
}

class _RoomMapState extends State<RoomMap> {
  bool _headingAligned = false;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      switch (widget.provider) {
        MapProvider.naver => NaverRoomMap(
          api: widget.api,
          guidance: widget.guidance,
          controller: widget.controller as NaverRoomMapController,
          positions: widget.positions,
          trail: widget.trail,
          targetHandle: widget.targetHandle,
          selfHandle: widget.selfHandle,
          following: widget.following,
          brightness: widget.brightness,
          onInteraction: widget.onInteraction,
          authError: widget.authError,
          car: widget.car,
          fullscreen: widget.fullscreen,
        ),
        MapProvider.vworld => VworldRoomMap(
          api: widget.api,
          guidance: widget.guidance,
          controller: widget.controller,
          positions: widget.positions,
          trail: widget.trail,
          targetHandle: widget.targetHandle,
          selfHandle: widget.selfHandle,
          following: widget.following,
          brightness: widget.brightness,
          onInteraction: widget.onInteraction,
          tiles: widget.tiles,
          car: widget.car,
          fullscreen: widget.fullscreen,
        ),
      },
      RoomMapControls(
        mode: widget.guidance?.mode,
        guidanceLabel: switch (widget.guidance) {
          final guidance? =>
            '${guidance.mode == FollowMode.a ? '따라가기' : '합류 지점 따라가기'} · ${guidance.status}\n'
                '${guidance.condition == FollowRouteCondition.disabled ? '추천 경로 제공 비활성' : '안내 시작·재계산 시 네이버 Maps에 좌표 제공'}',
          null => null,
        },
        onModeChanged: widget.onModeChanged,
        onResetGuidance: widget.onResetGuidance,
        car: widget.car,
        fullscreen: widget.fullscreen,
        headingAligned: _headingAligned,
        onRecenter: widget.positions.containsKey(widget.selfHandle)
            ? widget.controller.recenter
            : null,
        onAlign: () {
          setState(() => _headingAligned = !_headingAligned);
          widget.controller.alignHeading(_headingAligned);
        },
        onStopSharing: widget.onStopSharing,
        onFullscreen: widget.onFullscreen,
      ),
    ],
  );
}
