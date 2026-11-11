import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../net/models.dart';
import '../ui/icons.dart';
import '../ui/theme.dart';
import 'map_tiles.dart';

// 화면은 공급자의 카메라·좌표 타입을 알지 않는다.
abstract class RoomMapController {
  factory RoomMapController() = _FlutterRoomMapController;
  void moveTo(double latitude, double longitude, {double zoom = 16});
  void follow();
  void recenter();
  void dispose();
}

class _FlutterRoomMapController implements RoomMapController {
  _RoomMapState? _state;
  @override
  void moveTo(double latitude, double longitude, {double zoom = 16}) =>
      _state?._moveTo(LatLng(latitude, longitude), zoom);
  @override
  void follow() => _state?._queueFollow();
  @override
  void recenter() => _state?._recenter();
  @override
  void dispose() => _state = null;
}

class RoomMapPosition {
  const RoomMapPosition(this.fix, {required this.displayName});
  final LocationFix fix;
  final String displayName;
}

class RoomMapBounds {
  const RoomMapBounds(this.self, this.ahead);
  final LocationFix self, ahead;
  double get south => math.min(self.lat, ahead.lat);
  double get north => math.max(self.lat, ahead.lat);
  double get west => math.min(self.lng, ahead.lng);
  double get east => math.max(self.lng, ahead.lng);
}

const _distance = Distance(roundResult: false);
LatLng _point(LocationFix fix) => LatLng(fix.lat, fix.lng);

/// 방향이 있으면 전방 반평면에서 가장 가까운 점, 없으면 궤적의 최근접
/// 꼭짓점 다음 점을 고른다. 앞쪽 점이 없으면 그룹장의 현재 위치를 쓴다.
RoomMapBounds? followBounds({
  required LocationFix? self,
  required LocationFix? leader,
  required List<LocationFix> trail,
}) {
  if (self == null || leader == null) return null;
  LocationFix? ahead;
  var nearest = double.infinity;
  var nearestIndex = -1;
  for (var i = 0; i < trail.length; i++) {
    final point = trail[i];
    final meters = _distance(_point(self), _point(point));
    if (self.heading != null) {
      final heading = self.heading! * math.pi / 180;
      final north = point.lat - self.lat;
      final east = (point.lng - self.lng) * math.cos(self.lat * math.pi / 180);
      if (meters < 1 ||
          north * math.cos(heading) + east * math.sin(heading) <= 0)
        continue;
    }
    // 겹치는 길에서는 더 최근에 지나간 꼭짓점을 택한다.
    if (meters <= nearest) {
      nearest = meters;
      nearestIndex = i;
      ahead = point;
    }
  }
  if (self.heading == null) {
    ahead = nearestIndex >= 0 && nearestIndex + 1 < trail.length
        ? trail[nearestIndex + 1]
        : null;
  }
  return RoomMapBounds(self, ahead ?? leader);
}

String roomDistanceLabel(LocationFix self, LocationFix leader) {
  final meters = _distance(_point(self), _point(leader));
  return meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(1)} km'
      : '${meters.round()} m';
}

class RoomMap extends StatefulWidget {
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
  });
  final RoomMapController controller;
  final Map<String, RoomMapPosition> positions;
  final List<LocationFix> trail;
  final String? leaderHandle, selfHandle;
  final bool followLeader;
  final Brightness brightness;
  final VoidCallback? onInteraction;
  final MapTiles? tiles;

  @override
  State<RoomMap> createState() => _RoomMapState();
}

class _RoomMapState extends State<RoomMap> {
  final _camera = MapController();
  Timer? _resumeTimer;
  bool _ready = false, _paused = false, _followQueued = false;
  int _pointers = 0;
  MapTiles get _tiles => widget.tiles ?? mapTiles;
  LocationFix? get _self => widget.positions[widget.selfHandle]?.fix;
  LocationFix? get _leader => widget.positions[widget.leaderHandle]?.fix;
  double get _maximumZoom => _tiles.maximumZoom(widget.brightness);
  double get _minimumZoom => widget.followLeader
      ? math.min(18, _tiles.minimumZoom(widget.brightness))
      : _tiles.minimumZoom(widget.brightness);

  @override
  void initState() {
    super.initState();
    (widget.controller as _FlutterRoomMapController)._state = this;
  }

  @override
  void didUpdateWidget(RoomMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller as _FlutterRoomMapController)._state = null;
      (widget.controller as _FlutterRoomMapController)._state = this;
    }
    _queueFollow();
  }

  void _queueFollow() {
    if (!_ready || !widget.followLeader || _paused || _followQueued) return;
    _followQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followQueued = false;
      if (!mounted || !widget.followLeader || _paused) return;
      final bounds = followBounds(
        self: _self,
        leader: _leader,
        trail: widget.trail,
      );
      if (bounds == null) return;
      final size = _camera.camera.nonRotatedSize;
      // 160px보다 작은 패널에서도 양쪽 여백이 뷰포트를 넘어가지 않게 한다.
      final padding = math.min(
        80.0,
        math.max(0.0, (size.shortestSide - 1) / 2),
      );
      _camera.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds(
            LatLng(bounds.south, bounds.west),
            LatLng(bounds.north, bounds.east),
          ),
          padding: EdgeInsets.all(padding),
          minZoom: _minimumZoom,
          maxZoom: math.min(18, _maximumZoom),
        ),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _interaction() {
    _paused = true;
    _resumeTimer?.cancel();
    widget.onInteraction?.call();
    if (_pointers == 0) {
      _resumeTimer = Timer(const Duration(seconds: 5), () {
        _paused = false;
        if (mounted) _queueFollow();
      });
    }
  }

  void _releasePointer() {
    _pointers = math.max(0, _pointers - 1);
    _interaction();
  }

  void _moveTo(LatLng point, double zoom) {
    if (!_ready) return;
    _interaction();
    _camera.move(point, zoom.clamp(_minimumZoom, _maximumZoom));
  }

  void _recenter() {
    final self = _self;
    if (self != null) _moveTo(_point(self), math.min(18, _maximumZoom));
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    final controller = widget.controller as _FlutterRoomMapController;
    if (controller._state == this) controller._state = null;
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial =
        _self ?? _leader ?? widget.positions.values.firstOrNull?.fix;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerDown: (_) {
              _pointers++;
              _interaction();
            },
            onPointerUp: (_) => _releasePointer(),
            onPointerCancel: (_) => _releasePointer(),
            child: FlutterMap(
              mapController: _camera,
              options: MapOptions(
                initialCenter: initial == null
                    ? const LatLng(37.5665, 126.978)
                    : _point(initial),
                initialZoom: 16.0.clamp(_minimumZoom, _maximumZoom),
                minZoom: _minimumZoom,
                maxZoom: _maximumZoom,
                backgroundColor: widget.brightness == Brightness.dark
                    ? UnavoColors.ink
                    : UnavoColors.text,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onMapReady: () {
                  _ready = true;
                  _queueFollow();
                },
                onPositionChanged: (_, hasGesture) {
                  if (hasGesture) _interaction();
                },
              ),
              children: [
                if (_tiles.enabled)
                  _RoomTiles(tiles: _tiles, brightness: widget.brightness),
                PolylineLayer(
                  polylines: [
                    if (widget.trail.length >= 2)
                      Polyline(
                        points: widget.trail.map(_point).toList(),
                        color: UnavoColors.gold,
                        strokeWidth: 6,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                      ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (final entry in widget.positions.entries)
                      Marker(
                        key: ValueKey('map-marker-${entry.key}'),
                        point: _point(entry.value.fix),
                        width: 56,
                        height: 56,
                        child: _CarMarker(
                          position: entry.value,
                          self: entry.key == widget.selfHandle,
                          leader: entry.key == widget.leaderHandle,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_self != null &&
              _leader != null &&
              widget.selfHandle != widget.leaderHandle)
            Positioned(
              left: 8,
              top: 8,
              child: _MapLabel(roomDistanceLabel(_self!, _leader!)),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            left: 0,
            child: Align(
              alignment: Alignment.bottomRight,
              child: _MapLabel(_tiles.attribution),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarMarker extends StatelessWidget {
  const _CarMarker({
    required this.position,
    required this.self,
    required this.leader,
  });
  final RoomMapPosition position;
  final bool self, leader;

  @override
  Widget build(BuildContext context) {
    final name = position.displayName.trim().isEmpty
        ? position.fix.handle
        : position.displayName;
    return Semantics(
      label: '$name${self ? ", 나" : ""}${leader ? ", 그룹장" : ""}',
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: UnavoColors.ink,
                shape: BoxShape.circle,
                border: Border.all(
                  color: self ? UnavoColors.gold : UnavoColors.line,
                  width: self ? 3 : 1,
                ),
              ),
              child: Transform.rotate(
                angle: (position.fix.heading ?? 0) * math.pi / 180,
                child: const Center(child: UnavoIcon('car', size: 28)),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              color: UnavoColors.input,
              child: Text(
                name.characters.first,
                style: UnavoType.body.copyWith(fontSize: 12),
              ),
            ),
          ),
          if (leader)
            const Positioned(
              right: 0,
              top: 0,
              child: UnavoIcon('star', size: 18, color: UnavoColors.gold),
            ),
        ],
      ),
    );
  }
}

class _MapLabel extends StatelessWidget {
  const _MapLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      color: UnavoColors.ink,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(text, style: UnavoType.body.copyWith(fontSize: 12)),
    ),
  );
}

class _RoomTiles extends StatefulWidget {
  const _RoomTiles({required this.tiles, required this.brightness});
  final MapTiles tiles;
  final Brightness brightness;
  @override
  State<_RoomTiles> createState() => _RoomTilesState();
}

class _RoomTilesState extends State<_RoomTiles> {
  // flutter_map 8.3의 기본값은 디스크 캐시이므로 명시적으로 끈다.
  final _provider = NetworkTileProvider(
    cachingProvider: const DisabledMapCachingProvider(),
    attemptDecodeOfHttpErrorResponses: false,
  );
  static bool _loggedError = false;

  @override
  Widget build(BuildContext context) => TileLayer(
    urlTemplate: widget.tiles.template(widget.brightness),
    userAgentPackageName: MapTiles.userAgentPackageName,
    tileProvider: _provider,
    minZoom: widget.tiles.minimumZoom(widget.brightness),
    maxZoom: widget.tiles.maximumZoom(widget.brightness),
    maxNativeZoom: widget.brightness == Brightness.dark ? 18 : 19,
    tileDisplay: const TileDisplay.instantaneous(),
    errorTileCallback: (_, _, _) {
      if (_loggedError) return;
      _loggedError = true;
      // 키가 포함된 URL이나 예외 본문을 기록하지 않는다.
      debugPrint('map: 배경지도를 불러오지 못했습니다');
    },
  );
}
