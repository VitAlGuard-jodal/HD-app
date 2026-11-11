import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/icons.dart';
import '../ui/theme.dart';
import 'room_map_geometry.dart';

class RoomCarMarker extends StatelessWidget {
  const RoomCarMarker({
    required this.position,
    required this.self,
    required this.leader,
    this.rotateHeading = true,
    this.carIcon,
    this.starIcon,
  });
  final RoomMapPosition position;
  final bool self, leader;
  final bool rotateHeading;
  final Widget? carIcon, starIcon;

  @override
  Widget build(BuildContext context) {
    final name = position.name;
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
                angle: rotateHeading
                    ? (position.fix.heading ?? 0) * math.pi / 180
                    : 0,
                child: Center(
                  child: carIcon ?? const UnavoIcon('car', size: 28),
                ),
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
            Positioned(
              right: 0,
              top: 0,
              child:
                  starIcon ??
                  const UnavoIcon('star', size: 18, color: UnavoColors.gold),
            ),
        ],
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
