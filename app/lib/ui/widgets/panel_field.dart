import 'package:flutter/material.dart';

import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';
import 'focus_ring.dart';

class PanelField extends StatelessWidget {
  const PanelField({
    super.key,
    required this.controller,
    required this.label,
    required this.icon,
    this.obscureText = false,
    this.enabled = true,
    this.keyboardType,
    this.onSubmitted,
    this.autofillHints,
    this.textCapitalization = TextCapitalization.none,
    this.textInputAction = TextInputAction.next,
    this.focusNode,
  });
  final TextEditingController controller;
  final String label;
  final String icon;
  final bool obscureText;
  final bool enabled;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;
  final TextCapitalization textCapitalization;
  final TextInputAction textInputAction;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) => FocusRing(
    child: SizedBox(
      height: ControlScale.target(context),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        obscureText: obscureText,
        autocorrect: false,
        enableSuggestions: !obscureText,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        onSubmitted: onSubmitted,
        textCapitalization: textCapitalization,
        textInputAction: textInputAction,
        style: UnavoType.body,
        scrollPadding: const EdgeInsets.all(24),
        decoration: InputDecoration(
          hintText: label,
          hintStyle: const TextStyle(fontSize: 16, color: UnavoColors.muted),
          filled: true,
          fillColor: UnavoColors.input,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          prefixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: UnavoIcon(
              icon,
              color: UnavoColors.muted,
              size: ControlScale.icon(context),
            ),
          ),
          prefixIconConstraints: BoxConstraints(
            minWidth: ControlScale.isCar(context) ? 64 : 52,
            maxWidth: ControlScale.isCar(context) ? 64 : 52,
          ),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.line),
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.line),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.gold),
          ),
          disabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.line),
          ),
        ),
      ),
    ),
  );
}
