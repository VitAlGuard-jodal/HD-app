import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/phone_frame.dart';
import '../../ui/widgets/room_code.dart';
import '../../ui/widgets/status_chip.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key, required this.services, required this.mode});
  final AppServices services;
  final DeviceMode mode;
  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  bool _busy = false;
  String? _error;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted)
        setState(() {
          _error = errorMessage(error);
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  Future<void> _leave() async {
    await widget.services.rooms.leave();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.services.rooms,
    builder: (context, _) {
      final session = widget.services.rooms;
      final state = session.state;
      final inCall =
          session.call.isActive ||
          session.call.isStarting ||
          session.joiningCall;
      return PhoneFrame(
        mode: widget.mode,
        child: PanelScroll(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      state.room?.name ?? '함께 가는 길',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UnavoType.title.copyWith(fontSize: 22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  PanelButton(
                    label: '방 나가기',
                    icon: 'exit',
                    iconOnly: true,
                    onPressed: _busy ? null : () => _run(_leave),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              RoomCode(state.code ?? ''),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text(
                    '참여자 ${state.members.length}명',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    inCall ? '통화 중' : '통화 대기',
                    style: TextStyle(
                      fontSize: 16,
                      color: inCall ? UnavoColors.onCall : UnavoColors.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final member in state.members)
                      Container(
                        width: (constraints.maxWidth - 24) / 3,
                        constraints: const BoxConstraints(minHeight: 68),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: UnavoColors.input,
                          border: Border.all(
                            color: session.speaking.contains(member.handle)
                                ? UnavoColors.onCall
                                : UnavoColors.line,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                UnavoIcon(
                                  session.speaking.contains(member.handle)
                                      ? 'wave'
                                      : 'user',
                                  size: 18,
                                  color: UnavoColors.gold,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    member.handle ==
                                            widget.services.store.handle
                                        ? '나'
                                        : member.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              session.speaking.contains(member.handle)
                                  ? '말하는 중'
                                  : (member.handle ==
                                            widget.services.store.handle
                                        ? '내 기기'
                                        : '참여 중'),
                              style: TextStyle(
                                fontSize: 16,
                                color: session.speaking.contains(member.handle)
                                    ? UnavoColors.onCall
                                    : UnavoColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              PanelButton(
                label: inCall ? '통화 끊기' : '통화 참여',
                icon: inCall ? 'hangup' : 'phone',
                height: 72,
                fontSize: 20,
                style: inCall ? PanelButtonStyle.danger : PanelButtonStyle.call,
                onPressed: state.isLeaving || session.call.isStopping
                    ? null
                    : () {
                        // 권한 요청/시작 중이어도 끊기 입력은 차단하지 않는다.
                        if (inCall) {
                          unawaited(session.leaveCall());
                        } else {
                          unawaited(_run(session.joinCall));
                        }
                      },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: PanelButton(
                      label: session.muted ? '음소거 중' : '음소거',
                      icon: session.muted ? 'micoff' : 'mic',
                      selected: session.muted,
                      style: session.muted
                          ? PanelButtonStyle.gold
                          : PanelButtonStyle.neutral,
                      onPressed: inCall
                          ? () => session.setMuted(!session.muted)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PanelButton(
                      label: session.speakerphone ? '스피커' : '수화부',
                      icon: session.speakerphone ? 'speaker' : 'earpiece',
                      selected: session.speakerphone,
                      style: session.speakerphone
                          ? PanelButtonStyle.gold
                          : PanelButtonStyle.neutral,
                      onPressed: inCall && !_busy
                          ? () => _run(
                              () => session.setSpeakerphone(
                                !session.speakerphone,
                              ),
                            )
                          : null,
                    ),
                  ),
                ],
              ),
              ErrorText(_error ?? state.error ?? session.call.error),
              if (!state.isConnected && state.error != null) ...[
                const SizedBox(height: 12),
                PanelButton(
                  label: '다시 연결',
                  icon: 'refresh',
                  onPressed: _busy || state.code == null
                      ? null
                      : () =>
                            _run(() => session.open(state.code!, force: true)),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
