import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ui/icons.dart';
import '../net/api_client.dart';
import '../net/models.dart';
import '../ui/widgets/member_avatar.dart';
import '../ui/theme.dart';
import 'room_map_geometry.dart';

class RoomMarkerStyle {
  const RoomMarkerStyle({required this.self, required this.car});
  // 줌 18의 도로를 가리지 않도록 나·상대 모두 같은 작은 프로필을 쓴다.
  static const phoneDiameter = 28.0;
  static const carDiameter = 32.0;
  static const directionInset = 4.0;
  static const labelHeight = 12.0;
  static const labelFontSize = 9.0;
  final bool self, car;
  double get diameter => car ? carDiameter : phoneDiameter;
  double get directionDiameter => diameter + directionInset * 2;
  double get opacity => self ? 1 : .55;
  int get globalZIndex => self ? 300000 : 200000;
  Size get directionSize => Size.square(directionDiameter);
  Size get size =>
      Size(directionDiameter, directionDiameter + (self ? 0 : labelHeight));
  // 아래 이름표까지 포함한 비트맵의 중심이 아닌, 프로필의 중심이 GPS 좌표다.
  Offset get anchor => Offset(.5, directionDiameter / 2 / size.height);
  Alignment get alignment => Alignment(0, 1 - 2 * anchor.dy);
}

class RoomCarMarker extends StatelessWidget {
  const RoomCarMarker({
    super.key,
    required this.position,
    required this.self,
    this.car = false,
    this.applyOpacity = true,
    this.api,
    this.avatarImage,
    this.avatarLoadFailed = false,
  });
  final RoomMapPosition position;
  final bool self, car, applyOpacity;
  final ApiClient? api;
  final ui.Image? avatarImage;
  final bool avatarLoadFailed;

  @override
  Widget build(BuildContext context) {
    final style = RoomMarkerStyle(self: self, car: car);
    return Semantics(
      label: '${position.name}${self ? ", 나" : ""}',
      child: Opacity(
        opacity: applyOpacity ? style.opacity : 1,
        child: SizedBox.fromSize(
          size: style.size,
          child: Stack(
            children: [
              Positioned(
                left: RoomMarkerStyle.directionInset,
                top: RoomMarkerStyle.directionInset,
                child: MemberAvatar(
                  member: Member(
                    position.fix.handle,
                    position.name,
                    '',
                    avatar: avatarLoadFailed ? const Avatar() : position.avatar,
                    order: position.order,
                  ),
                  diameter: style.diameter,
                  api: api,
                  defaultMascot: true,
                  decodedImage: avatarImage,
                  imageResolved: avatarImage != null,
                  // 브이월드 사진 로딩·실패 중에도 프로필 규칙을 유지한다.
                  fallback: Image.asset(
                    'assets/avatars/mascot-01.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              if (!self)
                Positioned(
                  left: RoomMarkerStyle.directionInset,
                  top: style.directionDiameter + 1,
                  width: style.diameter,
                  child: Container(
                    color: UnavoColors.text,
                    child: Text(
                      position.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(
                        fontSize: RoomMarkerStyle.labelFontSize,
                        height: 1.1,
                        color: UnavoColors.ink,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 프로필과 별도 레이어다. 네이버는 북쪽 그림을 한 번 캡처한 뒤 SDK angle만
/// 갱신하고, 브이월드는 지도와 함께 회전하는 마커 안에서 이동 방위를 적용한다.
class RoomDirectionIndicator extends StatelessWidget {
  const RoomDirectionIndicator({
    super.key,
    required this.direction,
    required this.color,
    required this.self,
    this.car = false,
    this.applyOpacity = true,
  });
  final double direction;
  final Color color;
  final bool self, car, applyOpacity;

  @override
  Widget build(BuildContext context) {
    final style = RoomMarkerStyle(self: self, car: car);
    return IgnorePointer(
      child: Opacity(
        opacity: applyOpacity ? style.opacity : 1,
        child: SizedBox.fromSize(
          size: style.directionSize,
          child: Transform.rotate(
            angle: direction * math.pi / 180,
            child: CustomPaint(painter: RoomDirectionPainter(color: color)),
          ),
        ),
      ),
    );
  }
}

class RoomDirectionPainter extends CustomPainter {
  const RoomDirectionPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    canvas.drawPath(
      Path()
        ..moveTo(x, .5)
        ..lineTo(x + 3, RoomMarkerStyle.directionInset - .5)
        ..lineTo(x - 3, RoomMarkerStyle.directionInset - .5)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(RoomDirectionPainter oldDelegate) =>
      color != oldDelegate.color;
}

class RoomMapControls extends StatelessWidget {
  const RoomMapControls({
    super.key,
    required this.car,
    required this.fullscreen,
    required this.headingAligned,
    this.onRecenter,
    this.onAlign,
    this.onStopSharing,
    this.onFullscreen,
  });
  final bool car, fullscreen, headingAligned;
  final VoidCallback? onRecenter, onAlign, onStopSharing, onFullscreen;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        top: 12,
        right: 12,
        bottom: 12,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RoomMapButton(
                icon: 'focus',
                label: '내 위치로',
                car: car,
                onPressed: onRecenter,
              ),
              const SizedBox(height: 10),
              RoomMapButton(
                icon: 'compass',
                label: '방향 정렬',
                car: car,
                selected: headingAligned,
                onPressed: onAlign,
              ),
              const SizedBox(height: 10),
              RoomMapButton(
                icon: 'locationoff',
                label: '위치 공유 중지',
                car: car,
                onPressed: onStopSharing,
              ),
              if (fullscreen) ...[
                const SizedBox(height: 10),
                RoomMapButton(
                  icon: 'collapse',
                  label: '지도 축소',
                  car: car,
                  onPressed: onFullscreen,
                ),
              ],
            ],
          ),
        ),
      ),
      if (!fullscreen)
        Positioned(
          left: 12,
          bottom: 44,
          child: RoomMapButton(
            icon: 'expand',
            label: '지도 전체 화면',
            car: car,
            translucent: true,
            onPressed: onFullscreen,
          ),
        ),
    ],
  );
}

class RoomMapButton extends StatelessWidget {
  const RoomMapButton({
    super.key,
    required this.icon,
    required this.label,
    required this.car,
    required this.onPressed,
    this.selected = false,
    this.translucent = false,
  });
  final String icon, label;
  final bool car, selected, translucent;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final diameter = car ? 64.0 : 44.0;
    return Semantics(
      button: true,
      onTap: onPressed,
      label: label,
      selected: selected,
      enabled: onPressed != null,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: ExcludeSemantics(
          child: Container(
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: translucent ? .6 : 1),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: IconButton(
                onPressed: onPressed,
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(shape: const CircleBorder()),
                icon: UnavoIcon(
                  icon,
                  size: car ? 32 : 24,
                  color: UnavoColors.ink.withValues(
                    alpha: onPressed == null ? .4 : 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RoomMapLabel extends StatelessWidget {
  const RoomMapLabel(this.text, {this.maxLines});
  final String text;
  final int? maxLines;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      color: UnavoColors.ink,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: UnavoType.body.copyWith(fontSize: 12),
      ),
    ),
  );
}
