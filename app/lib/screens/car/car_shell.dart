import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/device_mode.dart';
import '../../ui/appearance.dart';
import '../../ui/backdrop.dart';
import '../../ui/control_scale.dart';
import '../../ui/theme.dart';

/// 패널의 열 수와 폭은 전체 창 너비로 정하고 IME는 가용 높이만 줄인다.
class CarShell extends StatelessWidget {
  const CarShell({
    super.key,
    required this.primary,
    this.secondary,
    this.room = false,
  });
  final bool room;
  final Widget primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final appearance = UnavoAppearance.of(context);
    final brightness = appearance.resolve(context);
    return ControlScale(
      car: true,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Backdrop(mode: DeviceMode.car, brightness: brightness),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  media.viewPadding.left + 24,
                  media.viewPadding.top + 16,
                  media.viewPadding.right + 24,
                  math.max(media.viewPadding.bottom, media.viewInsets.bottom) +
                      16,
                ),
                child: Column(
                  children: [
                    if (!room)
                      Row(
                        children: [
                          Text(
                            '우나보',
                            style: UnavoType.display.copyWith(fontSize: 32),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'UNAVO',
                            style: UnavoType.western.copyWith(fontSize: 20),
                          ),
                          const Spacer(),
                        ],
                      ),
                    if (!room) const SizedBox(height: 16),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          Widget panel(Widget child, String key) => Container(
                            key: ValueKey(key),
                            decoration: panelDecoration(),
                            padding: room && key == 'car-primary'
                                ? EdgeInsets.zero
                                : const EdgeInsets.all(20),
                            child: child,
                          );
                          final left = panel(primary, 'car-primary');
                          if (secondary == null) {
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: room
                                    ? constraints.maxWidth
                                    : math.min(720, constraints.maxWidth),
                                child: left,
                              ),
                            );
                          }
                          // Pleos 1320px 영역: 주 패널 약 60%, 보조 약 40%.
                          // 작은 창도 80dp 조작부를 축소하지 않고 가로 스크롤한다.
                          final width = math.max(1060.0, constraints.maxWidth);
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: width,
                              height: constraints.maxHeight,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(flex: 3, child: left),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    flex: 2,
                                    child: panel(secondary!, 'car-secondary'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
