import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/icons.dart';
import '../ui/theme.dart';
import 'room_map_geometry.dart';

class RoomMarkerStyle {
  const RoomMarkerStyle({required this.self, required this.car});
  final bool self, car;
  double get diameter => self ? (car ? 56 : 40) : (car ? 44 : 32);
  double get opacity => self ? 1 : .55;
  int get globalZIndex => self ? 300000 : 200000;
  Size get size =>
      self ? Size.square(diameter) : Size(diameter + 24, diameter + 16);
}

class RoomCarMarker extends StatelessWidget {
  const RoomCarMarker({
    super.key,
    required this.position,
    required this.self,
    this.car = false,
    this.rotateHeading = true,
    this.applyOpacity = true,
    this.carIcon,
  });
  final RoomMapPosition position;
  final bool self, car, rotateHeading, applyOpacity;
  final Widget? carIcon;

  @override
  Widget build(BuildContext context) {
    final style = RoomMarkerStyle(self: self, car: car);
    final heading = rotateHeading
        ? (position.fix.heading ?? 0) * math.pi / 180
        : 0.0;
    return Semantics(
      label: '${position.name}${self ? ", 나" : ""}',
      child: Opacity(
        opacity: applyOpacity ? style.opacity : 1,
        child: SizedBox.fromSize(
          size: style.size,
          child: self
              ? Transform.rotate(
                  angle: heading,
                  child: CustomPaint(
                    key: const ValueKey('gps-marker'),
                    painter: RoomGpsPainter(
                      hasHeading: position.fix.heading != null,
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.rotate(
                      angle: heading,
                      child:
                          carIcon ??
                          UnavoIcon(
                            'car',
                            size: style.diameter,
                            color: UnavoColors.ink,
                          ),
                    ),
                    Container(
                      color: UnavoColors.text,
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Text(
                        position.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1.2,
                          color: UnavoColors.ink,
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

class RoomGpsPainter extends CustomPainter {
  const RoomGpsPainter({required this.hasHeading});
  final bool hasHeading;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide;
    if (hasHeading) {
      canvas.drawPath(
        Path()
          ..moveTo(center.dx, center.dy)
          ..arcTo(
            Rect.fromCircle(center: center, radius: radius * .5),
            -math.pi * .75,
            math.pi * .5,
            false,
          )
          ..close(),
        Paint()..color = Colors.blue.withValues(alpha: .25),
      );
    }
    canvas.drawCircle(
      center,
      radius * .32,
      Paint()..color = Colors.blue.withValues(alpha: .16),
    );
    canvas.drawCircle(center, radius * .19, Paint()..color = Colors.white);
    canvas.drawCircle(center, radius * .14, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(RoomGpsPainter oldDelegate) =>
      hasHeading != oldDelegate.hasHeading;
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
