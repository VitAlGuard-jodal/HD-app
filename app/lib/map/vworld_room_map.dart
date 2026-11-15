import '../location/meeting_plan_controller.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../net/models.dart';
import '../location/follow_route_controller.dart';
import '../net/api_client.dart';
import '../ui/member_colors.dart';
import '../ui/theme.dart';
import 'map_tiles.dart';
import 'room_map.dart' show RoomMapController;
import 'room_map_geometry.dart';
import 'room_map_widgets.dart';

class VworldRoomMapController implements RoomMapController {
  _VworldRoomMapState? _state;
  @override
  void moveTo(
    double latitude,
    double longitude, {
    double zoom = RoomFollowCameraPolicy.navigationZoom,
  }) => _state?._moveTo(LatLng(latitude, longitude), zoom);
  @override
  void follow() => _state?._queueFollow();
  @override
  void recenter() => _state?._recenter();
  @override
  void alignHeading(bool enabled) => _state?._alignHeading(enabled);
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
    required this.targetHandle,
    required this.selfHandle,
    required this.following,
    required this.brightness,
    this.onInteraction,
    this.tiles,
    this.car = false,
    this.fullscreen = false,
    this.api,
    this.guidance,
    this.meetingPins = const [],
    this.onPointSelected,
    this.pauseAutoCamera = false,
  });
  final RoomMapController controller;
  final ApiClient? api;
  final FollowRouteView? guidance;
  final List<MeetingPin> meetingPins;
  final ValueChanged<RoutePoint>? onPointSelected;
  final bool pauseAutoCamera;
  final Map<String, RoomMapPosition> positions;
  final List<LocationFix> trail;
  final String? targetHandle, selfHandle;
  final bool following;
  final Brightness brightness;
  final VoidCallback? onInteraction;
  final MapTiles? tiles;
  final bool car, fullscreen;

  @override
  State<VworldRoomMap> createState() => _VworldRoomMapState();
}

class _VworldRoomMapState extends State<VworldRoomMap> {
  final _camera = MapController();
  final _directions = RoomDirectionTracker();
  final _selfCamera = RoomSelfCameraPolicy();
  Timer? _resumeTimer;
  bool _ready = false, _paused = false, _followQueued = false;
  int _pointers = 0;
  bool? _headingAligned;
  List<LocationFix>? _trailSource;
  List<LatLng> _trailPoints = const [];
  List<List<RoutePoint>>? _guidanceTrace;
  List<List<LatLng>> _guidancePoints = const [];
  MapTiles get _tiles => widget.tiles ?? mapTiles;
  LocationFix? get _self => widget.positions[widget.selfHandle]?.fix;
  LocationFix? get _target => widget.positions[widget.targetHandle]?.fix;
  double? get _selfDirection => _directions[widget.selfHandle];
  double get _maximumZoom => _tiles.maximumZoom(widget.brightness);
  double get _minimumZoom => widget.following
      ? math.min(
          RoomFollowCameraPolicy.maximumZoom,
          _tiles.minimumZoom(widget.brightness),
        )
      : _tiles.minimumZoom(widget.brightness);

  @override
  void initState() {
    super.initState();
    (widget.controller as VworldRoomMapController)._state = this;
    _directions.update(widget.positions.values.map((position) => position.fix));
    _selfCamera.centered(_self);
  }

  @override
  void didUpdateWidget(VworldRoomMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _directions.update(widget.positions.values.map((position) => position.fix));
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller as VworldRoomMapController)._state = null;
      (widget.controller as VworldRoomMapController)._state = this;
    }
    if (oldWidget.following && !widget.following) _selfCamera.centered(_self);
    if (widget.pauseAutoCamera) {
      _resumeTimer?.cancel();
      _resumeTimer = null;
      return;
    }
    if (oldWidget.pauseAutoCamera) {
      _paused = true;
      _resumeLater();
      return;
    }
    _queueFollow();
  }

  void _queueFollow() {
    if (!_ready ||
        widget.pauseAutoCamera ||
        _paused ||
        _followQueued ||
        _self == null)
      return;
    _followQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followQueued = false;
      if (!mounted || _paused || widget.pauseAutoCamera) return;
      if (!widget.following) {
        final self = _self;
        if (self == null) return;
        if (_selfCamera.needsCenter(
          self,
          _camera.camera.latLngToScreenOffset(_point(self)),
          _camera.camera.nonRotatedSize,
        )) {
          _camera.move(_point(self), _camera.camera.zoom);
          _selfCamera.centered(self);
        }
        if (_headingAligned == true &&
            _selfDirection != null &&
            (-_camera.camera.rotation - _selfDirection!) % 360 != 0) {
          _camera.rotate(-_selfDirection!);
        }
        return;
      }
      final next = naverFollowCamera(
        self: _self,
        leader: _target,
        direction: _selfDirection,
        currentBearing: -_camera.camera.rotation,
        isLeader: widget.selfHandle == widget.targetHandle,
      );
      if (next == null) return;
      _camera.move(
        _point(next.target),
        next.zoom.clamp(_minimumZoom, _maximumZoom),
      );
      _camera.rotate(_headingAligned == false ? 0 : -next.bearing);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _interaction() {
    _paused = true;
    widget.onInteraction?.call();
    _resumeLater();
  }

  void _resumeLater() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    if (_pointers != 0 || widget.pauseAutoCamera) return;
    _resumeTimer = Timer(const Duration(seconds: 5), () {
      _resumeTimer = null;
      if (!mounted || widget.pauseAutoCamera || _pointers != 0) return;
      _paused = false;
      _queueFollow();
    });
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
    if (self != null && _ready) {
      _selfCamera.centered(self);
      _moveTo(_point(self), _camera.camera.zoom);
    }
  }

  void _alignHeading(bool enabled) {
    _headingAligned = enabled;
    if (!_ready) return;
    _resumeTimer?.cancel();
    _paused = false;
    if (!enabled || _selfDirection != null) {
      _camera.rotate(enabled ? -_selfDirection! : 0);
    }
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
    final guidance = widget.guidance;
    if (!identical(_trailSource, widget.trail)) {
      _trailSource = widget.trail;
      _trailPoints = widget.trail.map(_point).toList(growable: false);
    }
    if (!identical(_guidanceTrace, guidance?.trace)) {
      _guidanceTrace = guidance?.trace;
      _guidancePoints =
          guidance?.trace
              .map((trace) => trace.map((p) => LatLng(p.lat, p.lng)).toList())
              .toList() ??
          const [];
    }
    final traces = guidance == null ? [_trailPoints] : _guidancePoints;
    final alpha = guidance?.subdued == true ? .35 : 1.0;
    final initial =
        _self ?? _target ?? widget.positions.values.firstOrNull?.fix;
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
                initialZoom: RoomFollowCameraPolicy.navigationZoom.clamp(
                  _minimumZoom,
                  _maximumZoom,
                ),
                minZoom: _minimumZoom,
                maxZoom: _maximumZoom,
                backgroundColor: widget.brightness == Brightness.dark
                    ? UnavoColors.ink
                    : UnavoColors.text,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
                onLongPress: (_, point) {
                  _interaction();
                  widget.onPointSelected?.call(
                    RoutePoint(point.latitude, point.longitude),
                  );
                },
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
                    if (guidance != null && guidance.connector.length >= 2)
                      Polyline(
                        points: guidance.connector
                            .map((p) => LatLng(p.lat, p.lng))
                            .toList(),
                        color: guidance.rejoining
                            ? const Color(0x80808080)
                            : const Color(0xff1a9eb5).withValues(alpha: alpha),
                        borderColor: Colors.white.withValues(alpha: alpha),
                        borderStrokeWidth: guidance.rejoining ? 0 : 2,
                        pattern: guidance.rejoining
                            ? StrokePattern.dashed(segments: const [12, 8])
                            : const StrokePattern.solid(),
                        strokeWidth: 6,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                      ),
                    for (final trace in traces)
                      if (trace.length >= 2)
                        Polyline(
                          points: trace,
                          color: UnavoColors.gold.withValues(alpha: alpha),
                          strokeWidth: 6,
                          borderColor: UnavoColors.ink.withValues(alpha: alpha),
                          borderStrokeWidth: 1,
                          strokeCap: StrokeCap.round,
                          strokeJoin: StrokeJoin.round,
                        ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (final pin in widget.meetingPins)
                      Marker(
                        point: LatLng(pin.point.lat, pin.point.lng),
                        width: 180,
                        height: 42,
                        child: Semantics(
                          label: pin.label,
                          child: RoomMapLabel(pin.label, maxLines: 2),
                        ),
                      ),
                    if (guidance?.anchor case final anchor?)
                      Marker(
                        key: const ValueKey('follow-anchor'),
                        point: LatLng(anchor.lat, anchor.lng),
                        width: 110,
                        height: 28,
                        rotate: true,
                        child: RoomMapLabel(guidance!.anchorLabel, maxLines: 1),
                      ),
                    for (final entry in [
                      ...widget.positions.entries.where(
                        (entry) => entry.key != widget.selfHandle,
                      ),
                      ...widget.positions.entries.where(
                        (entry) => entry.key == widget.selfHandle,
                      ),
                    ])
                      ..._memberMarkers(entry.key, entry.value),
                  ],
                ),
              ],
            ),
          ),
          if (_self != null &&
              _target != null &&
              widget.selfHandle != widget.targetHandle)
            Positioned(
              left: 8,
              top: widget.fullscreen ? (widget.car ? 80 : 64) : 8,
              child: RoomMapLabel(roomDistanceLabel(_self!, _target!)),
            ),
          Positioned(
            right: 0,
            bottom: widget.fullscreen ? (widget.car ? 120 : 88) : 0,
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

  Iterable<Marker> _memberMarkers(
    String handle,
    RoomMapPosition position,
  ) sync* {
    final self = handle == widget.selfHandle;
    final style = RoomMarkerStyle(self: self, car: widget.car);
    final direction = _directions[handle];
    yield Marker(
      key: ValueKey<String>('map-marker-$handle'),
      point: _point(position.fix),
      width: style.size.width,
      height: style.size.height,
      alignment: style.alignment,
      rotate: true,
      child: RoomCarMarker(
        api: widget.api,
        position: position,
        self: self,
        car: widget.car,
      ),
    );
    if (direction != null) {
      // 네이버의 globalZIndex + 1과 같이 방향 표시를 프로필 위에 둔다.
      yield Marker(
        key: ValueKey<String>('map-direction-$handle'),
        point: _point(position.fix),
        width: style.directionSize.width,
        height: style.directionSize.height,
        // 지도와 함께 회전: 실제 방위 + camera.rotation이 화면 방위가 된다.
        rotate: false,
        child: RoomDirectionIndicator(
          direction: direction,
          color: rainbowColor(position.order),
          self: self,
          car: widget.car,
        ),
      );
    }
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
