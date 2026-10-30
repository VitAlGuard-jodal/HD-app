import 'package:flutter/material.dart';

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
    this.iconOnly = false,
    this.selected = false,
    this.child,
    this.fontSize = 16,
  });
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
    final (background, foreground, border) = switch (style) {
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
              UnavoIcon(icon!, color: foreground, size: height == 72 ? 28 : 24),
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
      child: ExcludeSemantics(
        child: FocusRing(
          child: SizedBox(
            height: height,
            width: iconOnly ? 56 : null,
            child: OutlinedButton(
              onPressed: onPressed,
              style: ButtonStyle(
                minimumSize: const WidgetStatePropertyAll(Size(56, 56)),
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
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
