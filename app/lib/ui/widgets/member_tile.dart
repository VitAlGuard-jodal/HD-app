import 'package:flutter/widgets.dart';

import '../../net/models.dart';
import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';

class MemberTile extends StatelessWidget {
  const MemberTile({
    super.key,
    required this.member,
    this.self = false,
    this.speaking = false,
  });
  final Member member;
  final bool self;
  final bool speaking;
  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '${member.displayName}, @${member.handle}${self ? ", 나" : ""}${speaking ? ", 말하는 중" : ""}',
    child: ExcludeSemantics(
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(
          minHeight: ControlScale.isCar(context) ? 80 : 68,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: UnavoColors.input,
          border: Border.all(
            color: speaking ? UnavoColors.onCall : UnavoColors.line,
          ),
        ),
        child: Row(
          children: [
            UnavoIcon(
              speaking ? 'wave' : 'user',
              size: ControlScale.icon(context),
              color: speaking ? UnavoColors.onCall : UnavoColors.gold,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    member.displayName,
                    softWrap: true,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: UnavoColors.text,
                    ),
                  ),
                  Text(
                    '@${member.handle}',
                    softWrap: true,
                    style: const TextStyle(
                      fontSize: 16,
                      color: UnavoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (self) ...[
              const SizedBox(width: 12),
              UnavoIcon(
                'mobile',
                size: ControlScale.icon(context),
                color: UnavoColors.muted,
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
