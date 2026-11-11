import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../net/models.dart';
import '../ui/theme.dart';
import 'map_tiles.dart';
import 'room_map.dart' show RoomMapController;
import 'room_map_geometry.dart';
import 'room_map_widgets.dart';

class VworldRoomMapController implements RoomMapController {
  _VworldRoomMapState? _state;
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

LatLng _point(LocationFix fix) => LatLng(fix.lat, fix.lng);

class VworldRoomMap extends StatefulWidget {
  const VworldRoomMap({
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
  State<VworldRoomMap> createState() => _VworldRoomMapState();
}

class _VworldRoomMapState extends State<VworldRoomMap> {
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
    (widget.controller as VworldRoomMapController)._state = this;
  }

  @override
  void didUpdateWidget(VworldRoomMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller as VworldRoomMapController)._state = null;
      (widget.controller as VworldRoomMapController)._state = this;
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
    final controller = widget.controller as VworldRoomMapController;
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
                        child: RoomCarMarker(
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
              child: RoomMapLabel(roomDistanceLabel(_self!, _leader!)),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            left: 0,
            child: Align(
              alignment: Alignment.bottomRight,
              child: RoomMapLabel(_tiles.attribution),
            ),
          ),
        ],
      ),
    );
  }
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
