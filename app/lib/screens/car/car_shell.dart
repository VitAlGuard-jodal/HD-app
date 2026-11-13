import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/device_mode.dart';
import '../../ui/appearance.dart';
import '../../ui/backdrop.dart';
import '../../ui/control_scale.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';

/// 차량은 한 패널이 전체 폭을 쓰며 IME는 가용 높이만 줄인다.
class CarShell extends StatelessWidget {
  const CarShell({
    super.key,
    required this.primary,
    this.onSettings,
    this.room = false,
  });
  final bool room;
  final Widget primary;
  final VoidCallback? onSettings;

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
                // 이 셸이 이미 소비한 안전 영역과 IME를 중첩 Scaffold에서
                // 다시 빼지 않는다. 입력 화면도 같은 가용 영역을 사용한다.
                child: MediaQuery(
                  data: media.copyWith(
                    padding: EdgeInsets.zero,
                    viewPadding: EdgeInsets.zero,
                    viewInsets: EdgeInsets.zero,
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
                            PanelButton(
                              key: const ValueKey('open-settings'),
                              label: '설정',
                              icon: 'settings',
                              onPressed: onSettings,
                            ),
                          ],
                        ),
                      if (!room) const SizedBox(height: 16),
                      Expanded(
                        child: Container(
                          key: const ValueKey('car-primary'),
                          width: double.infinity,
                          decoration: panelDecoration(),
                          padding: room
                              ? EdgeInsets.zero
                              : const EdgeInsets.all(24),
                          child: primary,
                        ),
                      ),
                    ],
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
