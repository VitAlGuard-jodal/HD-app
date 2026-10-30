import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/device_mode.dart';
import '../appearance.dart';
import '../backdrop.dart';
import '../phone_frame_layout.dart';
import '../theme.dart';
import 'panel_button.dart';

class PhoneFrame extends StatelessWidget {
  const PhoneFrame({
    super.key,
    required this.mode,
    required this.child,
    this.bottomNav,
  });
  final DeviceMode mode;
  final Widget child;
  final Widget? bottomNav;

  @override
  Widget build(BuildContext context) {
    final appearance = UnavoAppearance.of(context);
    final brightness = appearance.resolve(context);
    final media = MediaQuery.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final keyboard = media.viewInsets.bottom;
            final safeBottom = media.viewPadding.bottom;
            final hasDock = bottomNav != null && keyboard == 0;
            final bottom = keyboard > 0
                ? keyboard + 12
                : safeBottom + (hasDock ? 96 : 8);
            final phoneLayout = mode == DeviceMode.phone
                ? calculatePhoneFrameLayout(
                    width: size.width,
                    height: size.height,
                    safeTop: media.viewPadding.top,
                  )
                : null;
            final headerTop =
                phoneLayout?.headerTop ?? media.viewPadding.top + 12;
            final letteringSafe = math.max(
              headerTop + 68,
              Backdrop.letteringBottom(size, mode) + 12,
            );
            final preferredTop =
                size.height * (Backdrop.isNarrow(size) ? 260 / 780 : 304 / 915);
            var top =
                phoneLayout?.panelTop ?? math.max(letteringSafe, preferredTop);
            if (keyboard > 0) {
              // 키보드가 보이는 동안만 포스터 위로 패널을 올린다. 배경은 움직이지 않는다.
              top = math.max(
                headerTop + 68,
                math.min(top, size.height - bottom - 412),
              );
            }
            final panelArea = math.max(0.0, size.height - bottom - top);
            return Stack(
              fit: StackFit.expand,
              children: [
                Backdrop(
                  mode: mode,
                  brightness: brightness,
                  verticalOffset: phoneLayout?.backdropOffset ?? 0,
                ),
                Positioned(
                  left: media.viewPadding.left + 16,
                  right: media.viewPadding.right + 16,
                  top: headerTop,
                  height: PhoneFrameLayout.headerHeight,
                  child: Row(
                    children: [
                      Text(
                        '우나보',
                        style: UnavoType.display.copyWith(fontSize: 24),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'UNAVO',
                        style: UnavoType.western.copyWith(fontSize: 12),
                      ),
                      const Spacer(),
                      Container(
                        color: UnavoColors.panel,
                        child: PanelButton(
                          label: brightness == Brightness.dark
                              ? '낮 테마 보기'
                              : '밤 테마 보기',
                          icon: brightness == Brightness.dark ? 'moon' : 'sun',
                          iconOnly: true,
                          onPressed: () => appearance.toggle(context),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: media.viewPadding.left + 16,
                  right: media.viewPadding.right + 16,
                  top: top,
                  height: panelArea,
                  child: Container(
                    decoration: panelDecoration(),
                    padding: const EdgeInsets.all(16),
                    child: child,
                  ),
                ),
                if (hasDock)
                  Positioned(
                    left: media.viewPadding.left + 16,
                    right: media.viewPadding.right + 16,
                    bottom: safeBottom + 8,
                    height: 76,
                    child: bottomNav!,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
