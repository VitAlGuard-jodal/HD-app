import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';
import 'focus_ring.dart';
import 'panel_edit_menu.dart';

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
    this.inputFormatters,
    this.enableSuggestions,
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
  final List<TextInputFormatter>? inputFormatters;
  final bool? enableSuggestions;
  @override
  Widget build(BuildContext context) {
    final car = ControlScale.isCar(context);
    final target = ControlScale.target(context);
    final prefixIcon = UnavoIcon(
      icon,
      color: UnavoColors.muted,
      size: ControlScale.icon(context),
    );
    final field = SizedBox(
      height: target,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        obscureText: obscureText,
        autocorrect: false,
        enableSuggestions: enableSuggestions ?? !obscureText,
        inputFormatters: inputFormatters,
        autofillHints: autofillHints,
        keyboardType: keyboardType,
        onSubmitted: onSubmitted,
        textCapitalization: textCapitalization,
        textInputAction: textInputAction,
        style: UnavoType.body,
        textAlignVertical: car ? TextAlignVertical.center : null,
        scrollPadding: const EdgeInsets.all(24),
        contextMenuBuilder: (_, editable) =>
            PanelEditMenu(editable: editable, car: car),
        decoration: InputDecoration(
          hintText: label,
          hintStyle: car
              ? UnavoType.body.copyWith(color: UnavoColors.muted)
              : const TextStyle(fontSize: 16, color: UnavoColors.muted),
          filled: true,
          fillColor: UnavoColors.input,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          prefixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: car ? Center(child: prefixIcon) : prefixIcon,
          ),
          prefixIconConstraints: BoxConstraints(
            minWidth: car ? 64 : 52,
            maxWidth: car ? 64 : 52,
            // TextField의 바깥 높이만으로는 실제 채움·테두리가 늘어나지 않는다.
            minHeight: car ? target : 0,
            maxHeight: car ? target : double.infinity,
          ),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.line),
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.gold, width: car ? 3 : 1),
          ),
          disabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
            borderSide: BorderSide(color: UnavoColors.line),
          ),
        ),
      ),
    );
    // 차량 입력은 같은 상자 안의 focusedBorder만 사용한다.
    return car ? field : FocusRing(child: field);
  }
}
