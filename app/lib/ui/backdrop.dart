import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../core/device_mode.dart';

class Backdrop extends StatelessWidget {
  const Backdrop({
    super.key,
    required this.mode,
    required this.brightness,
    this.cover = false,
  });
  final DeviceMode mode;
  final Brightness brightness;
  final bool cover;
  static bool isNarrow(Size viewport) =>
      viewport.width <= 380 || viewport.height <= 820;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final suffix = mode == DeviceMode.car || cover
          ? ''
          : (isNarrow(constraints.biggest) ? '_narrow' : '_interior');
      return ExcludeSemantics(
        child: Image.asset(
          'assets/backdrop/${mode == DeviceMode.car ? 'car' : 'phone'}_${brightness == Brightness.dark ? 'night' : 'day'}$suffix.png',
          fit: BoxFit.cover,
          alignment: Alignment.center,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        ),
      );
    },
  );

  static double letteringBottom(Size viewport, DeviceMode mode) {
    final source = mode == DeviceMode.car
        ? const Size(1682, 1210)
        : const Size(1080, 2400);
    final scale = math.max(
      viewport.width / source.width,
      viewport.height / source.height,
    );
    // 8b 정본(작업 중 갱신): 글자 획뿐 아니라 SVG 경계 밑변까지 보호.
    // 원본 1108px에 interior/narrow 레터링의 이동·배율만 적용한다.
    final bottom = mode == DeviceMode.car
        ? 654.0
        : isNarrow(viewport)
        ? 228 + .49 * 1108
        : 141.6 + .56 * 1108;
    return (viewport.height - source.height * scale) / 2 + bottom * scale;
  }
}
