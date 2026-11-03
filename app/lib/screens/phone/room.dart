import 'dart:async';

import 'package:flutter/material.dart';

import '../../call/media_engine.dart';
import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../ui/control_scale.dart';
import '../../ui/icons.dart';
import '../../ui/widgets/member_tile.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/phone_frame.dart';
import '../../ui/widgets/room_code.dart';
import '../../ui/widgets/status_chip.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.services,
    required this.mode,
    this.embedded = false,
  });
  final AppServices services;
  final DeviceMode mode;
  final bool embedded;
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
    if (mounted && !widget.embedded) Navigator.of(context).pop();
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
      final car = widget.mode == DeviceMode.car;
      final blocked = inCall ? null : session.callJoinBlockedReason;
      final (statusLabel, statusIcon) = switch (session.mediaConnection) {
        MediaConnectionState.connecting => ('음성 연결 중', 'refresh'),
        MediaConnectionState.connected => ('음성 연결됨', 'check'),
        MediaConnectionState.failed => ('음성 연결 실패', 'hangup'),
        MediaConnectionState.idle => (
          inCall ? '음성 연결 중' : '통화 대기',
          inCall ? 'refresh' : 'phone',
        ),
      };
      final details = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  state.room?.name ?? '함께 가는 길',
                  style: UnavoType.title.copyWith(fontSize: car ? 28 : 22),
                ),
              ),
              const SizedBox(width: 12),
              PanelButton(
                label: '방 나가기',
                icon: 'exit',
                onPressed: _busy ? null : () => _run(_leave),
              ),
            ],
          ),
          const SizedBox(height: 10),
          RoomCode(state.code ?? ''),
          const SizedBox(height: 18),
          Row(
            children: [
              UnavoIcon('friends', size: ControlScale.icon(context)),
              const SizedBox(width: 12),
              Text('${state.members.length}', style: UnavoType.body),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: StatusChip(
                    blocked ?? statusLabel,
                    icon: blocked == null ? statusIcon : 'hangup',
                    active:
                        session.mediaConnection ==
                        MediaConnectionState.connected,
                    showLabel: blocked != null,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final member in state.members)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MemberTile(
                member: member,
                self: member.handle == widget.services.store.handle,
                speaking: session.speaking.contains(member.handle),
              ),
            ),
          ErrorText(
            _error ?? session.mediaError ?? state.error ?? session.call.error,
          ),
          if (!state.isConnected && state.error != null) ...[
            const SizedBox(height: 12),
            PanelButton(
              label: '다시 연결',
              icon: 'refresh',
              onPressed: _busy || state.code == null
                  ? null
                  : () => _run(() => session.open(state.code!, force: true)),
            ),
          ],
        ],
      );
      final join = PanelButton(
        label: inCall ? '통화 끊기' : '통화 참여',
        icon: inCall ? 'hangup' : 'phone',
        height: car ? 80 : 72,
        style: inCall ? PanelButtonStyle.danger : PanelButtonStyle.call,
        onPressed:
            state.isLeaving ||
                session.call.isStopping ||
                (!inCall && (blocked != null || _busy))
            ? null
            : () {
                if (inCall) {
                  unawaited(session.leaveCall());
                } else {
                  unawaited(_run(session.joinCall));
                }
              },
      );
      final mute = PanelButton(
        label: session.muted ? '음소거 해제' : '음소거',
        icon: session.muted ? 'micoff' : 'mic',
        selected: session.muted,
        style: session.muted ? PanelButtonStyle.gold : PanelButtonStyle.neutral,
        onPressed: inCall ? () => session.setMuted(!session.muted) : null,
      );
      final output = PanelButton(
        label: session.speakerphone ? '수화부로 전환' : '스피커로 전환',
        icon: session.speakerphone ? 'speaker' : 'earpiece',
        selected: session.speakerphone,
        style: session.speakerphone
            ? PanelButtonStyle.gold
            : PanelButtonStyle.neutral,
        onPressed: inCall && !_busy
            ? () => _run(() => session.setSpeakerphone(!session.speakerphone))
            : null,
      );
      final controls = car
          ? Row(
              children: [
                Expanded(flex: 2, child: join),
                const SizedBox(width: 16),
                mute,
                const SizedBox(width: 16),
                output,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                join,
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: mute),
                    const SizedBox(width: 12),
                    Expanded(child: output),
                  ],
                ),
              ],
            );
      final content = car
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: PanelScroll(child: details)),
                const SizedBox(height: 16),
                controls,
              ],
            )
          : PanelScroll(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [details, const SizedBox(height: 20), controls],
              ),
            );
      return widget.embedded
          ? content
          : PhoneFrame(mode: widget.mode, child: content);
    },
  );
}
