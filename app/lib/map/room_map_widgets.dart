import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../location/follow_route_controller.dart';

import '../ui/icons.dart';
import '../net/api_client.dart';
import '../net/models.dart';
import '../ui/widgets/floating_bar.dart';
import '../ui/widgets/member_avatar.dart';
import '../ui/theme.dart';
import 'room_map_geometry.dart';

class RoomMarkerStyle {
  const RoomMarkerStyle({required this.self, required this.car});
  // 줌 18의 도로를 가리지 않도록 나·상대 모두 같은 작은 프로필을 쓴다.
  static const phoneDiameter = 28.0;
  static const carDiameter = 32.0;
  static const labelHeight = 12.0;
  static const labelFontSize = 9.0;
  static const directionGap = 2.0;
  static const directionOutlineWidth = 2.0;
  static const directionShadowWidth = 3.0;
  static const directionShadowColor = Color(0x26000000);
  final bool self, car;
  double get diameter => car ? carDiameter : phoneDiameter;
  // 흰 외곽선까지 차량 14×9dp·폰 12×8dp다. 더 바깥의 옅은
  // 0.5dp 대비선까지 포함해도 프로필에서 2dp 떨어지며 56dp 안에 든다.
  Size get directionTriangleSize => car ? const Size(12, 7) : const Size(10, 6);
  double get directionDiameter =>
      diameter +
      2 * (directionGap + directionTriangleSize.height + directionShadowWidth);
  double get opacity => self ? 1 : .55;
  int get globalZIndex => self ? 300000 : 200000;
  Size get directionSize => Size.square(directionDiameter);
  // 프로필 비트맵에는 회전용 빈 여백을 중복으로 넣지 않는다.
  // 아래 12dp 이름표까지 GPS에 맞춰 겹치면 전체 영역은 차량 56dp 이하다.
  Size get size => Size(diameter, diameter + (self ? 0 : labelHeight));
  // 아래 이름표까지 포함한 비트맵의 중심이 아닌, 프로필의 중심이 GPS 좌표다.
  Offset get anchor => Offset(.5, diameter / 2 / size.height);
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
                left: 0,
                top: 0,
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
                  left: 0,
                  top: style.diameter + 1,
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
            child: CustomPaint(
              painter: RoomDirectionPainter(color: color, car: car),
            ),
          ),
        ),
      ),
    );
  }
}

class RoomDirectionPainter extends CustomPainter {
  const RoomDirectionPainter({required this.color, this.car = false});
  final Color color;
  final bool car;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final triangle = RoomMarkerStyle(
      self: false,
      car: car,
    ).directionTriangleSize;
    const top = RoomMarkerStyle.directionShadowWidth / 2;
    final path = Path()
      ..moveTo(x, top)
      ..lineTo(x + triangle.width / 2, top + triangle.height)
      ..lineTo(x - triangle.width / 2, top + triangle.height)
      ..close();
    // 둥근 join은 꼭짓점의 miter가 캡처 영역 밖으로 잘리지 않게 한다.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = RoomMarkerStyle.directionShadowWidth
        ..color = RoomMarkerStyle.directionShadowColor,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = RoomMarkerStyle.directionOutlineWidth
        ..color = Colors.white,
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(RoomDirectionPainter oldDelegate) =>
      color != oldDelegate.color || car != oldDelegate.car;
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
    this.mode,
    this.onModeChanged,
    this.onResetGuidance,
    this.guidanceLabel,
  });
  final bool car, fullscreen, headingAligned;
  final FollowMode? mode;
  final ValueChanged<FollowMode>? onModeChanged;
  final VoidCallback? onResetGuidance;
  final String? guidanceLabel;
  final VoidCallback? onRecenter, onAlign, onStopSharing, onFullscreen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 10.0;
      final diameter = car ? 64.0 : 44.0;
      // 전체 화면의 발화 인디케이터 아래, 출처·통화 도크 위만 사용한다.
      final top = fullscreen ? (car ? 80.0 : 64.0) : 12.0;
      final bottom = fullscreen
          ? math.max(car ? 152.0 : 120.0, FloatingBarInset.of(context) + 12)
          : 36.0;
      final buttons = <Widget>[
        if (mode != null) ...[
          RoomMapButton(
            icon: 'navigation',
            label: '따라가기',
            car: car,
            selected: mode == FollowMode.a,
            onPressed: onModeChanged == null
                ? null
                : () => onModeChanged!(FollowMode.a),
          ),
          RoomMapButton(
            icon: 'route',
            label: '합류 지점 따라가기 · 준비 중',
            car: car,
            selected: false,
            onPressed: null,
          ),
          RoomMapButton(
            icon: 'refresh',
            label: '안내 다시 설정',
            car: car,
            onPressed: onResetGuidance,
          ),
        ],
        RoomMapButton(
          icon: 'focus',
          label: '내 위치로',
          car: car,
          onPressed: onRecenter,
        ),
        RoomMapButton(
          icon: 'compass',
          label: '방향 정렬',
          car: car,
          selected: headingAligned,
          onPressed: onAlign,
        ),
        RoomMapButton(
          icon: 'locationoff',
          label: '위치 공유 중지',
          car: car,
          onPressed: onStopSharing,
        ),
        if (fullscreen)
          RoomMapButton(
            icon: 'collapse',
            label: '지도 축소',
            car: car,
            onPressed: onFullscreen,
          ),
      ];
      // 버튼 크기를 유지하면서 짧은 창에서는 오른쪽부터 열을 늘린다.
      final rows =
          ((constraints.maxHeight - top - bottom + gap) / (diameter + gap))
              .floor()
              .clamp(1, buttons.length);
      final columns = (buttons.length / rows).ceil();
      final width = columns * diameter + (columns - 1) * gap;
      return Stack(
        children: [
          Positioned(
            top: top,
            right: 12,
            bottom: bottom,
            width: width,
            child: Wrap(
              direction: Axis.vertical,
              textDirection: TextDirection.rtl,
              spacing: gap,
              runSpacing: gap,
              children: buttons,
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
          if (guidanceLabel case final label?)
            Positioned(
              left: 8,
              right: width + 28,
              top: fullscreen ? (car ? 115 : 96) : 38,
              child: Align(
                alignment: Alignment.topLeft,
                child: RoomMapLabel(label, maxLines: 5),
              ),
            ),
        ],
      );
    },
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
              color: selected
                  ? UnavoColors.gold
                  : Colors.white.withValues(alpha: translucent ? .6 : 1),
              border: selected
                  ? Border.all(color: UnavoColors.ink, width: 3)
                  : null,
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
