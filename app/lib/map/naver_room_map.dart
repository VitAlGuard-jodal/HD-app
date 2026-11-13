import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';

import '../net/models.dart';
import '../net/api_client.dart';
import '../ui/avatar_images.dart';
import '../ui/member_colors.dart';
import '../ui/theme.dart';
import 'room_map.dart' show RoomMapController;
import 'room_map_geometry.dart';
import 'room_map_widgets.dart';

class NaverRoomMapController implements RoomMapController {
  _NaverRoomMapState? _state;
  @override
  void moveTo(
    double latitude,
    double longitude, {
    double zoom = RoomFollowCameraPolicy.navigationZoom,
  }) => _state?._moveTo(NLatLng(latitude, longitude), zoom);
  @override
  void follow() => _state?._queueFollow();
  @override
  void recenter() => _state?._recenter();
  @override
  void alignHeading(bool enabled) => _state?._alignHeading(enabled);
  @override
  void dispose() => _state = null;
}

NLatLng _point(LocationFix fix) => NLatLng(fix.lat, fix.lng);

/// SDK 위젯을 만들지 않고도 마커 정책을 검사할 수 있는 생성 경계.
NMarker roomNaverMarker({
  required String handle,
  required LocationFix fix,
  required NOverlayImage icon,
  required bool self,
  required bool car,
}) {
  final style = RoomMarkerStyle(self: self, car: car);
  return NMarker(
    id: handle,
    position: _point(fix),
    icon: icon,
    // 사진·이름표는 지도 회전·기울임과 무관하게 화면에서 똑바로 유지한다.
    angle: 0,
    isFlat: false,
    anchor: NPoint(style.anchor.dx, style.anchor.dy),
    size: style.size,
    alpha: style.opacity,
  )..setGlobalZIndex(style.globalZIndex);
}

NMarker roomNaverDirectionMarker({
  required String handle,
  required LocationFix fix,
  required NOverlayImage icon,
  required bool self,
  required bool car,
  required double? direction,
  double cameraBearing = 0,
  double cameraTilt = 0,
}) {
  final style = RoomMarkerStyle(self: self, car: car);
  return NMarker(
      id: 'direction:$handle',
      position: _point(fix),
      icon: icon,
      angle: roomScreenDirection(
        direction ?? 0,
        cameraBearing: cameraBearing,
        cameraTilt: cameraTilt,
      ),
      // flat 마커는 tilt 50에서 프로필 안쪽으로 눕는다. 화면 크기를 유지하며
      // SDK 카메라 스트림으로 화면 방위만 보정하여 항상 테두리 바깥에 둔다.
      isFlat: false,
      anchor: NPoint.relativeCenter,
      size: style.directionSize,
      alpha: style.opacity,
    )
    ..setIsVisible(direction != null)
    ..setGlobalZIndex(style.globalZIndex + 1);
}

typedef RoomMarkerKey = (
  String,
  String,
  bool,
  Brightness,
  bool,
  String?,
  int,
  Color,
);

RoomMarkerKey roomMarkerCacheKey({
  required RoomMapPosition position,
  required bool self,
  required Brightness brightness,
  required bool car,
}) => (
  position.fix.handle,
  position.name,
  self,
  brightness,
  car,
  position.avatar.kind,
  position.avatar.version,
  rainbowColor(position.order),
);

/// 캡처와 분리하여 SDK 없이도 실패 아이콘의 재시도 간격을 검사한다.
class RoomMarkerIconCache {
  RoomMarkerIconCache({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _icons = <RoomMarkerKey, NOverlayImage>{};
  final _failedIcons = <RoomMarkerKey, ({NOverlayImage icon, DateTime at})>{};

  Future<NOverlayImage?> load(
    RoomMarkerKey key,
    Future<({NOverlayImage icon, bool failed})?> Function() capture,
  ) async {
    final icon = _icons[key];
    if (icon != null) return icon;
    final failure = _failedIcons[key];
    if (failure != null &&
        _now().difference(failure.at) < const Duration(seconds: 30)) {
      return failure.icon;
    }
    _failedIcons.remove(key);
    final result = await capture();
    if (result == null) return null;
    if (result.failed) {
      _failedIcons[key] = (icon: result.icon, at: _now());
    } else {
      _icons[key] = result.icon;
      _failedIcons.remove(key);
    }
    return result.icon;
  }

  bool hasResolved(RoomMarkerKey key) => _icons.containsKey(key);

  void removeWhere(bool Function(RoomMarkerKey) test) {
    _icons.removeWhere((key, _) => test(key));
    _failedIcons.removeWhere((key, _) => test(key));
  }

  void clear() {
    _icons.clear();
    _failedIcons.clear();
  }
}

class NaverRoomMap extends StatefulWidget {
  const NaverRoomMap({
    super.key,
    required this.controller,
    required this.positions,
    required this.trail,
    required this.targetHandle,
    required this.selfHandle,
    required this.following,
    required this.brightness,
    this.onInteraction,
    this.authError,
    this.car = false,
    this.fullscreen = false,
    this.api,
  });
  final NaverRoomMapController controller;
  final ApiClient? api;
  final Map<String, RoomMapPosition> positions;
  final List<LocationFix> trail;
  final String? targetHandle, selfHandle;
  final bool following;
  final Brightness brightness;
  final VoidCallback? onInteraction;
  final String? authError;
  final bool car, fullscreen;

  @override
  State<NaverRoomMap> createState() => _NaverRoomMapState();
}

class _NaverRoomMapState extends State<NaverRoomMap> {
  NaverMapController? _camera;
  late final NCameraPosition _initialCamera;
  final _markers = <String, NMarker>{};
  final _directionMarkers = <String, NMarker>{};
  final _markerKeys = <String, RoomMarkerKey>{};
  final _icons = RoomMarkerIconCache();
  // 7가지 입장 색 × 폰/차량의 북쪽 삼각형만 캡처한다. 방위는 키에 없다.
  final _directionIcons = <(Color, bool), NOverlayImage>{};
  final _directions = RoomDirectionTracker();
  final _assetImages = <String, ui.Image>{};
  StreamSubscription<OnCameraChangedParams>? _cameraSubscription;
  double _cameraBearing = 0, _cameraTilt = 0;
  NPathOverlay? _path;
  List<LocationFix> _pathPoints = const [];
  bool _syncing = false, _syncAgain = false, _loggedError = false;
  final _clock = Stopwatch()..start();
  Duration? _lastFollow;
  Timer? _followTimer, _resumeTimer;
  bool _paused = false, _followPending = false, _following = false;
  int _pointers = 0, _cameraRevision = 0;
  bool? _headingAligned;

  LocationFix? get _self => widget.positions[widget.selfHandle]?.fix;
  LocationFix? get _target => widget.positions[widget.targetHandle]?.fix;
  double? get _selfDirection => _directions[widget.selfHandle];
  bool get _canFollow =>
      mounted &&
      _camera != null &&
      widget.following &&
      !_paused &&
      _self != null;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
    _directions.update(widget.positions.values.map((position) => position.fix));
    final initial =
        _self ?? _target ?? widget.positions.values.firstOrNull?.fix;
    _initialCamera = NCameraPosition(
      target: initial == null
          ? const NLatLng(37.5665, 126.978)
          : _point(initial),
      zoom: RoomFollowCameraPolicy.navigationZoom,
    );
  }

  @override
  void didUpdateWidget(NaverRoomMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousDirection = _selfDirection;
    _directions.update(widget.positions.values.map((position) => position.fix));
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller._state == this)
        oldWidget.controller._state = null;
      widget.controller._state = this;
    }
    final trailChanged = !listEquals(oldWidget.trail, widget.trail);
    final rolesChanged =
        oldWidget.targetHandle != widget.targetHandle ||
        oldWidget.selfHandle != widget.selfHandle;
    final positionsChanged =
        oldWidget.positions.length != widget.positions.length ||
        widget.positions.entries.any((entry) {
          final old = oldWidget.positions[entry.key];
          return old?.fix != entry.value.fix ||
              old?.displayName != entry.value.displayName ||
              old?.avatar != entry.value.avatar ||
              old?.order != entry.value.order;
        });
    if (positionsChanged ||
        trailChanged ||
        rolesChanged ||
        oldWidget.car != widget.car ||
        oldWidget.brightness != widget.brightness) {
      unawaited(_syncOverlays());
    }
    if (!widget.following &&
        _headingAligned == true &&
        !_paused &&
        previousDirection != _selfDirection &&
        _selfDirection != null) {
      unawaited(_rotateCamera(_selfDirection!));
    }
    if (!widget.following || _self == null) {
      _cancelFollow();
      if (oldWidget.following && !widget.following) {
        unawaited(_cancelTransition());
      }
    } else if (!oldWidget.following ||
        rolesChanged ||
        trailChanged ||
        oldWidget.positions[oldWidget.selfHandle]?.fix != _self ||
        oldWidget.positions[oldWidget.targetHandle]?.fix != _target) {
      _queueFollow();
    }
  }

  bool _isCurrent(NaverMapController camera) => mounted && _camera == camera;

  void _logError(Object error) {
    if (!mounted || _loggedError) return;
    _loggedError = true;
    debugPrint('map: 네이버 지도 갱신 실패 (${error.runtimeType})');
  }

  void _onMapReady(NaverMapController camera) {
    if (!mounted) return;
    _camera = camera;
    _markers.clear();
    _directionMarkers.clear();
    _markerKeys.clear();
    _cameraBearing = _initialCamera.bearing;
    _cameraTilt = _initialCamera.tilt;
    unawaited(_cameraSubscription?.cancel());
    _cameraSubscription = camera.nowCameraPositionStream.listen((event) {
      if (!_isCurrent(camera)) return;
      _cameraBearing = event.position.bearing;
      _cameraTilt = event.position.tilt;
      _updateDirectionAngles();
    });
    _path = null;
    _pathPoints = const [];
    unawaited(_syncOverlays());
    if (_headingAligned == true &&
        !widget.following &&
        _selfDirection != null) {
      unawaited(_rotateCamera(_selfDirection!));
    }
    _queueFollow();
  }

  RoomMarkerKey _keyFor(String handle, RoomMapPosition position) =>
      roomMarkerCacheKey(
        position: position,
        self: handle == widget.selfHandle,
        brightness: widget.brightness,
        car: widget.car,
      );

  Future<NOverlayImage?> _markerIcon(
    RoomMarkerKey key,
    RoomMapPosition position,
  ) => _icons.load(key, () async {
    final style = RoomMarkerStyle(self: key.$3, car: key.$5);
    var avatar = await _markerAvatar(position);
    final failed = avatar == null;
    avatar ??= await _defaultMarkerAvatar();
    if (!mounted || avatar == null) return null;
    final icon = await NOverlayImage.fromWidget(
      context: context,
      size: style.size,
      widget: RoomCarMarker(
        position: position,
        self: key.$3,
        car: key.$5,
        avatarImage: avatar,
        avatarLoadFailed: failed,
        // SDK alpha만 적용한다. 사진과 이름의 비트맵은 방향에 의존하지 않는다.
        applyOpacity: false,
      ),
    );
    if (!mounted) return null;
    return (icon: icon, failed: failed);
  });

  Future<ui.Image?> _defaultMarkerAvatar() async {
    final cached = _assetImages['default-avatar'];
    if (cached != null) return cached;
    if (!mounted) return null;
    final image = await decodeAvatar(
      const Member('', '', ''),
      bundle: DefaultAssetBundle.of(context),
      defaultMascot: true,
    );
    if (!mounted) {
      image?.dispose();
      return null;
    }
    if (image != null) _assetImages['default-avatar'] = image;
    return image;
  }

  Future<NOverlayImage?> _directionIcon(Color color, bool car) async {
    final key = (color, car);
    final cached = _directionIcons[key];
    if (cached != null) return cached;
    final icon = await NOverlayImage.fromWidget(
      context: context,
      size: RoomMarkerStyle(self: false, car: car).directionSize,
      widget: RoomDirectionIndicator(
        direction: 0,
        color: color,
        self: false,
        car: car,
        applyOpacity: false,
      ),
    );
    if (!mounted) return null;
    return _directionIcons[key] = icon;
  }

  void _updateDirectionAngles() {
    for (final entry in _directionMarkers.entries) {
      final direction = _directions[entry.key];
      final marker = entry.value;
      final visible = direction != null;
      if (marker.isVisible != visible) marker.setIsVisible(visible);
      if (direction == null) continue;
      final angle = roomScreenDirection(
        direction,
        cameraBearing: _cameraBearing,
        cameraTilt: _cameraTilt,
      );
      if (marker.angle != angle) marker.setAngle(angle);
    }
  }

  Future<ui.Image?> _markerAvatar(RoomMapPosition position) async {
    final avatar = position.avatar;
    final assetKey =
        'avatar:${position.fix.handle}:${avatar.kind}:${avatar.version}';
    final cached = _assetImages[assetKey];
    if (cached != null) return cached;
    try {
      final image = await decodeAvatar(
        Member(position.fix.handle, position.name, '', avatar: avatar),
        api: widget.api,
        bundle: DefaultAssetBundle.of(context),
        defaultMascot: true,
      );
      if (image == null) return null;
      if (!mounted) {
        image.dispose();
        return null;
      }
      _assetImages.removeWhere((key, oldImage) {
        if (!key.startsWith('avatar:${position.fix.handle}:')) return false;
        oldImage.dispose();
        return true;
      });
      return _assetImages[assetKey] = image;
    } catch (error) {
      _logError(error);
      return null;
    }
  }

  Future<void> _syncOverlays() async {
    if (!mounted || _camera == null) return;
    _syncAgain = true;
    if (_syncing) return;
    _syncing = true;
    try {
      // 이미지 생성·네이티브 추가/삭제 중 받은 표본은 최신 상태로 합친다.
      while (mounted && _camera != null && _syncAgain) {
        _syncAgain = false;
        await _applyOverlays(_camera!);
      }
    } catch (error) {
      _logError(error);
    } finally {
      _syncing = false;
      if (!mounted) _disposeImages();
    }
  }

  Future<void> _applyOverlays(NaverMapController camera) async {
    for (final handle in _markers.keys.toList()) {
      if (widget.positions.containsKey(handle)) continue;
      await camera.deleteOverlay(_markers[handle]!.info);
      if (!_isCurrent(camera)) return;
      _markers.remove(handle);
      _markerKeys.remove(handle);
    }
    for (final handle in _directionMarkers.keys.toList()) {
      if (widget.positions.containsKey(handle)) continue;
      await camera.deleteOverlay(_directionMarkers[handle]!.info);
      if (!_isCurrent(camera)) return;
      _directionMarkers.remove(handle);
    }
    _icons.removeWhere((key) {
      final current = widget.positions[key.$1];
      return current == null || _keyFor(key.$1, current) != key;
    });
    final activeAvatars = {
      for (final position in widget.positions.values)
        'avatar:${position.fix.handle}:${position.avatar.kind}:${position.avatar.version}',
    };
    for (final key in _assetImages.keys.toList()) {
      if (key.startsWith('avatar:') && !activeAvatars.contains(key)) {
        _assetImages.remove(key)?.dispose();
      }
    }
    for (final entry in widget.positions.entries.toList()) {
      final key = _keyFor(entry.key, entry.value);
      final icon = await _markerIcon(key, entry.value);
      if (!_isCurrent(camera) || icon == null) return;
      final current = widget.positions[entry.key];
      if (current == null || _keyFor(entry.key, current) != key) continue;
      final style = RoomMarkerStyle(
        self: entry.key == widget.selfHandle,
        car: widget.car,
      );
      final marker = _markers[entry.key];
      if (marker == null) {
        final added = roomNaverMarker(
          handle: entry.key,
          fix: current.fix,
          icon: icon,
          self: entry.key == widget.selfHandle,
          car: widget.car,
        );
        await camera.addOverlay(added);
        if (!_isCurrent(camera)) return;
        _markers[entry.key] = added;
      } else {
        final point = _point(current.fix);
        if (marker.position != point) marker.setPosition(point);
        if (_markerKeys[entry.key] != key || marker.icon != icon) {
          marker.setIcon(icon);
          marker.setSize(style.size);
          marker.setAlpha(style.opacity);
          marker.setGlobalZIndex(style.globalZIndex);
          marker.setAnchor(NPoint(style.anchor.dx, style.anchor.dy));
        }
      }
      if (_icons.hasResolved(key)) {
        _markerKeys[entry.key] = key;
        _icons.removeWhere((old) => old.$1 == entry.key && old != key);
      } else {
        _markerKeys.remove(entry.key);
      }

      final direction = _directions[entry.key];
      var arrow = _directionMarkers[entry.key];
      if (direction == null) {
        if (arrow?.isVisible == true) arrow!.setIsVisible(false);
        continue;
      }
      final directionIcon = await _directionIcon(
        rainbowColor(current.order),
        widget.car,
      );
      if (!_isCurrent(camera) || directionIcon == null) return;
      final latest = widget.positions[entry.key];
      if (latest == null || _keyFor(entry.key, latest) != key) continue;
      if (arrow == null) {
        arrow = roomNaverDirectionMarker(
          handle: entry.key,
          fix: latest.fix,
          icon: directionIcon,
          self: entry.key == widget.selfHandle,
          car: widget.car,
          direction: _directions[entry.key],
          cameraBearing: _cameraBearing,
          cameraTilt: _cameraTilt,
        );
        await camera.addOverlay(arrow);
        if (!_isCurrent(camera)) return;
        _directionMarkers[entry.key] = arrow;
      } else {
        final point = _point(latest.fix);
        if (arrow.position != point) arrow.setPosition(point);
        if (arrow.icon != directionIcon) arrow.setIcon(directionIcon);
        if (arrow.size != style.directionSize)
          arrow.setSize(style.directionSize);
        if (arrow.alpha != style.opacity) arrow.setAlpha(style.opacity);
        if (arrow.globalZIndex != style.globalZIndex + 1)
          arrow.setGlobalZIndex(style.globalZIndex + 1);
      }
    }
    _updateDirectionAngles();

    final points = roomPathPoints(widget.trail);
    if (points.isEmpty) {
      if (_path != null) {
        await camera.deleteOverlay(_path!.info);
        if (!_isCurrent(camera)) return;
        _path = null;
      }
    } else {
      final outline = widget.brightness == Brightness.dark
          ? UnavoColors.text
          : UnavoColors.ink;
      if (_path == null) {
        final path = NPathOverlay(
          id: 'trail',
          coords: points.map(_point).toList(),
          width: 8,
          color: UnavoColors.gold,
          outlineWidth: 2,
          outlineColor: outline,
        );
        await camera.addOverlay(path);
        if (!_isCurrent(camera)) return;
        _path = path;
      } else {
        if (!listEquals(_pathPoints, points)) {
          _path!.setCoords(points.map(_point).toList());
        }
        if (_path!.outlineColor != outline) _path!.setOutlineColor(outline);
      }
    }
    _pathPoints = points;
  }

  void _queueFollow() {
    if (!_canFollow) return;
    _followPending = true;
    if (_following || _followTimer != null) return;
    final delay = _lastFollow == null
        ? Duration.zero
        : const Duration(seconds: 1) - (_clock.elapsed - _lastFollow!);
    _followTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _followTimer = null;
      unawaited(_applyFollow());
    });
  }

  Future<void> _applyFollow() async {
    if (!_canFollow || !_followPending) return;
    _followPending = false;
    _following = true;
    final camera = _camera!;
    final revision = _cameraRevision;
    try {
      final current = await camera.getCameraPosition();
      if (!_isCurrent(camera) || !_canFollow || revision != _cameraRevision)
        return;
      final next = naverFollowCamera(
        self: _self,
        leader: _target,
        direction: _selfDirection,
        currentBearing: current.bearing,
        isLeader: widget.selfHandle == widget.targetHandle,
      );
      if (next == null) return;
      _lastFollow = _clock.elapsed;
      await camera.updateCamera(
        NCameraUpdate.withParams(
          target: _point(next.target),
          zoom: next.zoom,
          tilt: next.tilt,
          bearing: _headingAligned == false ? 0 : next.bearing,
        )..setAnimation(
          animation: NCameraAnimation.linear,
          duration: const Duration(milliseconds: 800),
        ),
      );
    } catch (error) {
      _logError(error);
    } finally {
      _following = false;
      if (_followPending) _queueFollow();
    }
  }

  void _cancelFollow() {
    _cameraRevision++;
    _followTimer?.cancel();
    _followTimer = null;
    _followPending = false;
  }

  Future<void> _cancelTransition() async {
    try {
      await _camera?.cancelTransitions();
    } catch (error) {
      _logError(error);
    }
  }

  void _resumeLater() {
    _resumeTimer?.cancel();
    if (_pointers != 0) return;
    _resumeTimer = Timer(const Duration(seconds: 5), () {
      _paused = false;
      if (_headingAligned == true &&
          !widget.following &&
          _selfDirection != null) {
        unawaited(_rotateCamera(_selfDirection!));
      }
      _queueFollow();
    });
  }

  void _interaction() {
    _paused = true;
    _cancelFollow();
    widget.onInteraction?.call();
    _resumeLater();
  }

  void _releasePointer() {
    _pointers = math.max(0, _pointers - 1);
    _interaction();
  }

  void _onCameraIdle() {
    if (_paused) _resumeLater();
  }

  void _moveTo(NLatLng point, double zoom) {
    final camera = _camera;
    if (camera == null) return;
    _interaction();
    unawaited(_moveCamera(camera, point, zoom));
  }

  Future<void> _moveCamera(
    NaverMapController camera,
    NLatLng point,
    double? zoom,
  ) async {
    try {
      // 생략한 tilt와 bearing은 현재값을 유지한다.
      await camera.updateCamera(
        NCameraUpdate.withParams(target: point, zoom: zoom),
      );
    } catch (error) {
      _logError(error);
    }
  }

  void _recenter() {
    final self = _self;
    final camera = _camera;
    if (self == null || camera == null) return;
    _interaction();
    unawaited(_moveCamera(camera, _point(self), null)); // 줌·기울임·방위 유지.
  }

  void _alignHeading(bool enabled) {
    _headingAligned = enabled;
    _cancelFollow();
    _resumeTimer?.cancel();
    _paused = false;
    if (!enabled || _selfDirection != null) {
      unawaited(_rotateCamera(enabled ? _selfDirection! : 0));
    }
  }

  Future<void> _rotateCamera(double bearing) async {
    try {
      await _camera?.updateCamera(NCameraUpdate.withParams(bearing: bearing));
    } catch (error) {
      _logError(error);
    }
  }

  void _disposeImages() {
    for (final image in _assetImages.values) {
      image.dispose();
    }
    _assetImages.clear();
    _icons.clear();
    _directionIcons.clear();
  }

  @override
  void dispose() {
    _cancelFollow();
    _resumeTimer?.cancel();
    _clock.stop();
    unawaited(_cameraSubscription?.cancel());
    _camera = null;
    if (widget.controller._state == this) widget.controller._state = null;
    // 네이티브 컨트롤러는 NaverMap.dispose가 소유한다.
    if (!_syncing) _disposeImages();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final distance =
        _self != null &&
            _target != null &&
            widget.selfHandle != widget.targetHandle
        ? roomDistanceLabel(_self!, _target!)
        : null;
    final logoInset = widget.fullscreen ? (widget.car ? 120.0 : 88.0) : 16.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 작은 지도에서도 로고가 위쪽 상태 라벨이나 뷰포트 밖으로 밀리지 않는다.
        final logoBottom = math.min(
          logoInset,
          math.max(0.0, constraints.maxHeight - 80),
        );
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
                child: NaverMap(
                  // 1.4.4는 build의 _updateOptionsIfNeeded에서 옵션을 갱신한다.
                  options: NaverMapViewOptions(
                    initialCameraPosition: _initialCamera,
                    mapType: NMapType.navi,
                    nightModeEnable: widget.brightness == Brightness.dark,
                    scaleBarEnable: false,
                    locationButtonEnable: false,
                    indoorEnable: false,
                    activeLayerGroups: const [NLayerGroup.building],
                    logoClickEnable: true,
                    logoAlign: NLogoAlign.leftBottom,
                    logoMargin: EdgeInsets.fromLTRB(12, 16, 12, logoBottom),
                    contentPadding: EdgeInsets.zero,
                    maxTilt: 63,
                    rotationGesturesEnable: true,
                    tiltGesturesEnable: true,
                  ),
                  onMapReady: _onMapReady,
                  onCameraChange: (reason, animated) {
                    if (reason == NCameraUpdateReason.gesture) _interaction();
                  },
                  onCameraIdle: _onCameraIdle,
                ),
              ),
              if (widget.authError != null || distance != null)
                Positioned(
                  left: 8,
                  top: widget.fullscreen ? (widget.car ? 80 : 64) : 8,
                  right: widget.car ? 88 : 68,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.authError != null)
                        RoomMapLabel(widget.authError!, maxLines: 1),
                      if (widget.authError != null && distance != null)
                        const SizedBox(height: 4),
                      if (distance != null) RoomMapLabel(distance),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
