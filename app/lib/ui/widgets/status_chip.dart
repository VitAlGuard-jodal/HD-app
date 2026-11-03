import 'package:flutter/widgets.dart';

import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';

class StatusChip extends StatelessWidget {
  const StatusChip(
    this.label, {
    super.key,
    this.active = false,
    required this.icon,
  });
  final String label;
  final String icon;
  final bool active;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: UnavoColors.input,
        border: Border.all(
          color: active ? UnavoColors.onCall : UnavoColors.line,
        ),
      ),
      child: UnavoIcon(
        icon,
        size: ControlScale.icon(context),
        color: active ? UnavoColors.onCall : UnavoColors.muted,
      ),
    ),
  );
}

class ErrorText extends StatelessWidget {
  const ErrorText(this.message, {super.key});
  final String? message;
  @override
  Widget build(BuildContext context) => message == null || message!.isEmpty
      ? const SizedBox.shrink()
      : Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              message!,
              style: const TextStyle(
                color: UnavoColors.onDanger,
                fontSize: 16,
                height: 1.4,
              ),
            ),
          ),
        );
}
