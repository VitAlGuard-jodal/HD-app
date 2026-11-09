import 'package:flutter/widgets.dart';

import '../../net/models.dart';
import '../../call/mesh_coordinator.dart';
import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';

class MemberTile extends StatelessWidget {
  const MemberTile({
    super.key,
    required this.member,
    this.self = false,
    this.speaking = false,
    this.interrupted = false,
    this.connection,
  });
  final Member member;
  final bool self;
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
  Widget build(BuildContext context) => Semantics(
    label:
        '${member.displayName}, @${member.handle}${self ? ", 나" : ""}${_speaking ? ", 말하는 중" : ""}${_interrupted ? ", 다른 오디오 때문에 잠시 중단" : ""}$_connectionLabel',
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
            color: _speaking ? UnavoColors.onCall : UnavoColors.line,
          ),
        ),
        child: Row(
          children: [
            UnavoIcon(
              _interrupted
                  ? 'micoff'
                  : _speaking
                  ? 'wave'
                  : 'user',
              size: ControlScale.icon(context),
              color: _speaking ? UnavoColors.onCall : UnavoColors.gold,
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
                  if (_interrupted)
                    const Text(
                      '다른 오디오 때문에 잠시 중단',
                      softWrap: true,
                      style: TextStyle(fontSize: 16, color: UnavoColors.muted),
                    ),
                ],
              ),
            ),
            if (_connectionLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              UnavoIcon(
                connection == MeshPeerState.connecting ? 'refresh' : 'hangup',
                size: ControlScale.isCar(context) ? 24 : 18,
                color: connection == MeshPeerState.connecting
                    ? UnavoColors.muted
                    : UnavoColors.onDanger,
              ),
            ],
            if (self) ...[
              const SizedBox(width: 12),
              UnavoIcon(
                ControlScale.isCar(context) ? 'car' : 'mobile',
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
