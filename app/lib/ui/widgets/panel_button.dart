import 'package:flutter/material.dart';

import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';
import 'focus_ring.dart';

enum PanelButtonStyle { neutral, gold, call, danger }

class PanelButton extends StatelessWidget {
  const PanelButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.style = PanelButtonStyle.neutral,
    this.height = 56,
    this.iconOnly = true,
    this.selected = false,
    this.child,
    this.fontSize = 16,
  }) : assert(!iconOnly || icon != null || child != null);
  final String label;
  final VoidCallback? onPressed;
  final String? icon;
  final PanelButtonStyle style;
  final double height;
  final bool iconOnly;
  final bool selected;
  final Widget? child;
  final double fontSize;
  @override
  Widget build(BuildContext context) {
    final car = ControlScale.isCar(context);
    final target = ControlScale.target(context);
    final effectiveHeight = height < target ? target : height;
    final disabledColor = UnavoColors.text.withValues(alpha: 0.4);
    final (background, foreground, border) = switch (style) {
      _ when onPressed == null => (
        UnavoColors.panel,
        disabledColor,
        disabledColor,
      ),
      PanelButtonStyle.neutral => (
        UnavoColors.input,
        UnavoColors.text,
        UnavoColors.line,
      ),
      PanelButtonStyle.gold => (
        UnavoColors.gold,
        UnavoColors.ink,
        UnavoColors.gold,
      ),
      PanelButtonStyle.call => (
        UnavoColors.call,
        UnavoColors.onCall,
        UnavoColors.onCall,
      ),
      PanelButtonStyle.danger => (
        UnavoColors.danger,
        UnavoColors.onDanger,
        UnavoColors.onDanger,
      ),
    };
    final content =
        child ??
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null)
              UnavoIcon(
                icon!,
                color: foreground,
                size: car ? 36 : (height >= 72 ? 28 : 24),
              ),
            if (icon != null && !iconOnly) const SizedBox(width: 10),
            if (!iconOnly)
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                    color: foreground,
                  ),
                ),
              ),
          ],
        );
    return Semantics(
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: ExcludeSemantics(
          child: FocusRing(
            child: SizedBox(
              height: effectiveHeight,
              width: iconOnly ? target : null,
              child: OutlinedButton(
                onPressed: onPressed,
                style: ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size(target, target)),
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: iconOnly ? 0 : 14),
                  ),
                  backgroundColor: WidgetStatePropertyAll(background),
                  foregroundColor: WidgetStatePropertyAll(foreground),
                  side: WidgetStatePropertyAll(BorderSide(color: border)),
                  shape: const WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                  ),
                  animationDuration: const Duration(milliseconds: 150),
                  overlayColor: const WidgetStatePropertyAll(Color(0x16F3EDDF)),
                ),
                // 별도 child의 SVG는 버튼의 foregroundColor를 상속하지 않는다.
                child: onPressed == null && child != null
                    ? ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          foreground,
                          BlendMode.srcIn,
                        ),
                        child: content,
                      )
                    : content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
