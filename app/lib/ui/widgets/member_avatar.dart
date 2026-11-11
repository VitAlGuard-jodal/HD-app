import 'package:flutter/material.dart';

import '../../net/models.dart';
import '../theme.dart';

/// 사진 아바타로 교체할 때도 카드와 내비 인디케이터는 같은 경계를 쓴다.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.member,
    required this.diameter,
    this.speaking = false,
  });
  final Member member;
  final double diameter;
  final bool speaking;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${member.displayName}${speaking ? ", 말하는 중" : ""}',
    child: Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: UnavoColors.input,
        border: Border.all(
          width: 3,
          color: speaking ? UnavoColors.speaking : Colors.transparent,
        ),
        boxShadow: speaking
            ? [
                BoxShadow(
                  color: UnavoColors.speaking.withValues(alpha: .65),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Text(
        (member.displayName.trim().isEmpty ? member.handle : member.displayName)
            .characters
            .first,
        style: UnavoType.body.copyWith(fontSize: diameter * .4),
      ),
    ),
  );
}
