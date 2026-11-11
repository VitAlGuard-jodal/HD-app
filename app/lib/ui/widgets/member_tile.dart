import 'package:flutter/material.dart';

import '../../net/models.dart';
import '../../call/mesh_coordinator.dart';
import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';
import 'member_avatar.dart';

class MemberTile extends StatelessWidget {
  const MemberTile({
    super.key,
    required this.member,
    this.self = false,
    this.speaking = false,
    this.interrupted = false,
    this.connection,
    this.onTap,
    this.compact = false,
  });
  final VoidCallback? onTap;
  final Member member;
  final bool self, compact;
  final bool speaking;
  final bool interrupted;
  bool get _interrupted => self && interrupted;
  bool get _speaking => speaking && !_interrupted;
  final MeshPeerState? connection;
  String get _connectionLabel => self || speaking
      ? ''
      : switch (connection) {
          MeshPeerState.connecting => ', 연결 중',
          MeshPeerState.failed || MeshPeerState.closed => ', 연결 실패',
          _ => '',
        };
  @override
  Widget build(BuildContext context) {
    final car = ControlScale.isCar(context);
    final avatar = MemberAvatar(member: member, diameter: car ? 56 : 32);
    final indicators = [
      UnavoIcon(
        _interrupted
            ? 'micoff'
            : _speaking
            ? 'wave'
            : 'user',
        size: car ? 24 : 18,
        color: _speaking ? UnavoColors.onCall : UnavoColors.gold,
      ),
      if (_connectionLabel.isNotEmpty)
        UnavoIcon(
          connection == MeshPeerState.connecting ? 'refresh' : 'hangup',
          size: car ? 24 : 18,
          color: connection == MeshPeerState.connecting
              ? UnavoColors.muted
              : UnavoColors.onDanger,
        ),
      if (self)
        UnavoIcon(
          car ? 'car' : 'mobile',
          size: car ? 24 : 18,
          color: UnavoColors.muted,
        ),
    ];
    final names = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          member.displayName,
          maxLines: car ? 1 : 2,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: UnavoColors.text,
          ),
        ),
        Text(
          '@${member.handle}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, color: UnavoColors.muted),
        ),
        if (_interrupted)
          const Text(
            '다른 오디오 때문에 잠시 중단',
            style: TextStyle(fontSize: 16, color: UnavoColors.muted),
          ),
      ],
    );
    return Semantics(
      button: onTap != null,
      onTap: onTap,
      label:
          '${member.displayName}, @${member.handle}${self ? ", 나" : ""}${_speaking ? ", 말하는 중" : ""}${_interrupted ? ", 다른 오디오 때문에 잠시 중단" : ""}$_connectionLabel',
      child: ExcludeSemantics(
        child: Material(
          color: UnavoColors.input,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(minHeight: car ? 80 : 68),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _speaking ? UnavoColors.onCall : UnavoColors.line,
                ),
              ),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [avatar, ...indicators],
                        ),
                        const SizedBox(height: 8),
                        names,
                      ],
                    )
                  : Row(
                      children: [
                        avatar,
                        SizedBox(width: car ? 12 : 8),
                        Expanded(child: names),
                        const SizedBox(width: 8),
                        Wrap(
                          direction: car ? Axis.horizontal : Axis.vertical,
                          spacing: 4,
                          children: indicators,
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
