import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../core/device_mode.dart';
import 'phone_frame_layout.dart';
import 'theme.dart';

class Backdrop extends StatelessWidget {
  const Backdrop({
    super.key,
    required this.mode,
    required this.brightness,
    this.cover = false,
    this.verticalOffset = 0,
  });
  final DeviceMode mode;
  final Brightness brightness;
  final bool cover;
  final double verticalOffset;
  static bool isNarrow(Size viewport) =>
      isNarrowPhone(viewport.width, viewport.height);
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final suffix = mode == DeviceMode.car || cover
          ? ''
          : (isNarrow(constraints.biggest) ? '_narrow' : '_interior');
      return ExcludeSemantics(
        child: ColoredBox(
          color: UnavoColors.ink,
          child: ClipRect(
            child: Transform.translate(
              offset: Offset(0, verticalOffset),
              child: Image.asset(
                'assets/backdrop/${mode == DeviceMode.car ? 'car' : 'phone'}_${brightness == Brightness.dark ? 'night' : 'day'}$suffix.png',
                fit: BoxFit.cover,
                alignment: Alignment.center,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
      );
    },
  );

  static double letteringTop(Size viewport, {double verticalOffset = 0}) =>
      phoneLetteringBounds(
        width: viewport.width,
        height: viewport.height,
        verticalOffset: verticalOffset,
      ).top;

  static double letteringBottom(
    Size viewport,
    DeviceMode mode, {
    double verticalOffset = 0,
  }) {
    if (mode == DeviceMode.phone) {
      return phoneLetteringBounds(
        width: viewport.width,
        height: viewport.height,
        verticalOffset: verticalOffset,
      ).bottom;
    }
    const source = Size(1682, 1210);
    final scale = math.max(
      viewport.width / source.width,
      viewport.height / source.height,
    );
    return (viewport.height - source.height * scale) / 2 + 654 * scale;
  }
}
