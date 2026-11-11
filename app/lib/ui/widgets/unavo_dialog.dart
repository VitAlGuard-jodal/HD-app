import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../control_scale.dart';
import '../theme.dart';
import 'panel_button.dart';

Future<bool> showConsentDialog(
  BuildContext context, {
  required String title,
  required List<String> lines,
  Widget? detail,
}) async {
  final car = ControlScale.isCar(context);
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope<bool>(
          canPop: false,
          child: ControlScale(
            car: car,
            child: _DialogCard(
              title: title,
              lines: lines,
              detail: detail,
              actions: [
                PanelButton(
                  label: '미동의',
                  icon: 'back',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                PanelButton(
                  label: '동의',
                  icon: 'check',
                  style: PanelButtonStyle.gold,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ),
        ),
      ) ??
      false;
}

Future<void> showNoticeDialog(
  BuildContext context, {
  required String message,
}) async {
  final car = ControlScale.isCar(context);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope<void>(
      canPop: false,
      child: ControlScale(
        car: car,
        child: _DialogCard(
          lines: [message],
          actions: [
            PanelButton(
              label: '닫기',
              icon: 'check',
              style: PanelButtonStyle.gold,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DialogCard extends StatelessWidget {
  const _DialogCard({
    this.title,
    required this.lines,
    this.detail,
    required this.actions,
  });
  final String? title;
  final List<String> lines;
  final Widget? detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final car = ControlScale.isCar(context);
    final width = MediaQuery.sizeOf(context).width;
    return Dialog(
      alignment: Alignment.center,
      insetPadding: EdgeInsets.symmetric(
        horizontal: car ? 24 : width * .05,
        vertical: 24,
      ),
      backgroundColor: UnavoColors.ink,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: UnavoColors.line),
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      child: SizedBox(
        width: math.min(car ? width - 48 : width * .9, car ? 560 : 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (title != null) ...[
                        Text(title!, style: UnavoType.title),
                        const SizedBox(height: 16),
                      ],
                      for (final line in lines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(line, style: UnavoType.body),
                        ),
                      if (detail != null) detail!,
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (var index = 0; index < actions.length; index++) ...[
                    if (index > 0) const SizedBox(width: 12),
                    actions[index],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
