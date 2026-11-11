import 'package:flutter/material.dart';

import '../control_scale.dart';
import '../theme.dart';
import 'panel_button.dart';

Future<bool> showLocationConsentSheet(
  BuildContext context,
  List<String> recipients,
) async {
  final car = ControlScale.isCar(context);
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: UnavoColors.panel,
        builder: (context) => ControlScale(
          car: car,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(recipients.join(', ')),
                  const SizedBox(height: 16),
                  const Text('같은 방 참여자에게 내 차 위치를 보여 줍니다'),
                  const SizedBox(height: 12),
                  const Text('방을 나가거나 중지 아이콘을 누르면 끝납니다'),
                  const SizedBox(height: 12),
                  const Text('위치는 방이 있는 동안만 서버에 남습니다'),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      PanelButton(
                        label: '취소',
                        icon: 'back',
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                      const SizedBox(width: 12),
                      PanelButton(
                        label: '확인',
                        icon: 'check',
                        style: PanelButtonStyle.gold,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ) ??
      false;
}
