import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
  void moveTo(double latitude, double longitude, {double zoom = 16}) =>
      _state?._moveTo(NLatLng(latitude, longitude), zoom);
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
  bool profile = false,
}) {
  final style = RoomMarkerStyle(self: self, car: car);
  return NMarker(
    id: handle,
    position: _point(fix),
    icon: icon,
    angle: !self && profile ? 0 : fix.heading ?? 0,
    isFlat: true,
    anchor: NPoint.relativeCenter,
    size: style.size,
    alpha: style.opacity,
  )..setGlobalZIndex(style.globalZIndex);
}

typedef RoomMarkerKey = (
  String,
  String,
  bool,
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
  position.fix.heading != null,
  brightness,
  car,
  position.avatar.kind,
  position.avatar.version,
  rainbowColor(position.order),
);

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
  final _markerKeys = <String, RoomMarkerKey>{};
  final _icons = <RoomMarkerKey, NOverlayImage>{};
  final _assetImages = <String, ui.Image>{};
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
    final initial =
        _self ?? _target ?? widget.positions.values.firstOrNull?.fix;
    _initialCamera = NCameraPosition(
      target: initial == null
          ? const NLatLng(37.5665, 126.978)
          : _point(initial),
      zoom: 16,
    );
  }

  @override
  void didUpdateWidget(NaverRoomMap oldWidget) {
    super.didUpdateWidget(oldWidget);
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
        oldWidget.positions[oldWidget.selfHandle]?.fix.heading !=
            _self?.heading) {
      unawaited(_rotateCamera(_self?.heading ?? 0));
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
    _markerKeys.clear();
    _path = null;
    _pathPoints = const [];
    unawaited(_syncOverlays());
    _queueFollow();
  }

  RoomMarkerKey _keyFor(String handle, RoomMapPosition position) =>
      roomMarkerCacheKey(
        position: position,
        self: handle == widget.selfHandle,
        brightness: widget.brightness,
        car: widget.car,
      );

  // fromWidget는 첫 paint 직후 캡처한다. 비동기 SvgPicture의 빈 첫 프레임을
  // 피하려고 기존 SVG를 먼저 디코딩하고 같은 마커 위젯에 RawImage로 넣는다.
  Future<ui.Image?> _markerAsset(String name, double size) async {
    final assetKey = '$name-$size';
    final cached = _assetImages[assetKey];
    if (cached != null) return cached;
    final pixels = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    final picture = await vg.loadPicture(
      SvgAssetLoader('assets/icons/ui-$name.svg'),
      context,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(pixels / picture.size.width, pixels / picture.size.height);
    canvas.drawPicture(picture.picture);
    final scaled = recorder.endRecording();
    try {
      final image = await scaled.toImage(pixels, pixels);
      if (!mounted) {
        image.dispose();
        return null;
      }
      return _assetImages[assetKey] = image;
    } finally {
      scaled.dispose();
      picture.picture.dispose();
    }
  }

  Future<NOverlayImage?> _markerIcon(
    RoomMarkerKey key,
    RoomMapPosition position,
  ) async {
    final cached = _icons[key];
    if (cached != null) return cached;
    final style = RoomMarkerStyle(self: key.$3, car: key.$6);
    final avatar = key.$3 || position.avatar.kind == null
        ? null
        : await _markerAvatar(position);
    final failed = !key.$3 && position.avatar.kind != null && avatar == null;
    final car = key.$3 || avatar != null
        ? null
        : await _markerAsset('car', style.diameter);
    if (!mounted || (!key.$3 && avatar == null && car == null)) return null;
    final icon = await NOverlayImage.fromWidget(
      context: context,
      size: style.size,
      widget: RoomCarMarker(
        position: position,
        self: key.$3,
        car: key.$6,
        avatarImage: avatar,
        avatarLoadFailed: failed,
        // SDK 회전·alpha를 한 번만 적용한다. 이름은 전체 표시 이름별로 캐시한다.
        rotateHeading: false,
        applyOpacity: false,
        carIcon: car == null
            ? null
            : RawImage(
                image: car,
                width: style.diameter,
                height: style.diameter,
                color: UnavoColors.ink,
                colorBlendMode: BlendMode.srcIn,
              ),
      ),
    );
    if (!mounted) return null;
    // 실패한 사진의 임시 차 아이콘을 영구 캐시하지 않는다.
    if (!failed) _icons[key] = icon;
    return icon;
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
    _icons.removeWhere((key, _) {
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
          profile: current.avatar.kind != null,
        );
        await camera.addOverlay(added);
        if (!_isCurrent(camera)) return;
        _markers[entry.key] = added;
      } else {
        final point = _point(current.fix);
        if (marker.position != point) marker.setPosition(point);
        final angle =
            entry.key != widget.selfHandle && current.avatar.kind != null
            ? 0.0
            : current.fix.heading ?? 0;
        if (marker.angle != angle) {
          marker.setAngle(angle);
        }
        if (_markerKeys[entry.key] != key || marker.icon != icon) {
          marker.setIcon(icon);
          marker.setSize(style.size);
          marker.setAlpha(style.opacity);
          marker.setGlobalZIndex(style.globalZIndex);
        }
      }
      if (_icons.containsKey(key)) {
        _markerKeys[entry.key] = key;
        _icons.removeWhere((old, _) => old.$1 == entry.key && old != key);
      } else {
        _markerKeys.remove(entry.key);
      }
    }

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
        trail: widget.trail,
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
      if (_headingAligned == true && !widget.following) {
        unawaited(_rotateCamera(_self?.heading ?? 0));
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
    unawaited(_rotateCamera(enabled ? (_self?.heading ?? 0) : 0));
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
  }

  @override
  void dispose() {
    _cancelFollow();
    _resumeTimer?.cancel();
    _clock.stop();
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
