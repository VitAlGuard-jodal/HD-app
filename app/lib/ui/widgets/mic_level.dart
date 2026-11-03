import 'package:flutter/widgets.dart';

import '../../audio/mic_router.dart';
import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';

/// 입력을 새로 열지 않고 공유 중인 캡처의 레벨만 표시한다.
class MicLevel extends StatelessWidget {
  const MicLevel({super.key, required this.router});
  final MicRouter router;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: router,
    builder: (context, _) {
      final level = router.state.level.clamp(0.0, 1.0);
      return Semantics(
        label: '마이크 입력 레벨',
        value: '${(level * 100).round()}%',
        child: ExcludeSemantics(
          child: Column(
            children: [
              Row(
                children: [
                  UnavoIcon(
                    'wave',
                    size: ControlScale.icon(context),
                    color: UnavoColors.gold,
                  ),
                  const Spacer(),
                  Text('${(level * 100).round()}%', style: UnavoType.body),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 12,
                child: Row(
                  children: [
                    for (var i = 0; i < 20; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: i < (level * 20).round()
                                ? UnavoColors.gold
                                : UnavoColors.input,
                            border: Border.all(
                              color: i < (level * 20).round()
                                  ? UnavoColors.gold
                                  : UnavoColors.line,
                            ),
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
