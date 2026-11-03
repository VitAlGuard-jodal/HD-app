import 'dart:async';

import 'package:flutter/material.dart';

import '../../audio/mic_router.dart';
import '../../call/media_engine.dart';
import '../../call/mesh_coordinator.dart';
import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../ui/control_scale.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/floating_bar.dart';
import '../../ui/widgets/member_tile.dart';
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
  bool _volumeExpanded = false;
  bool _dragging = false;
  bool _popped = false;
  String? _error;
  Timer? _volumeTimer;

  @override
  void dispose() {
    _volumeTimer?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _closeIfLeft() {
    if (mounted &&
        !widget.embedded &&
        !_popped &&
        widget.services.rooms.state.code == null) {
      _popped = true;
      Navigator.of(context).pop();
    }
  }

  Future<void> _leave() async {
    await widget.services.rooms.leave();
    _closeIfLeft();
  }

  void _collapseVolumeLater() {
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_dragging) setState(() => _volumeExpanded = false);
    });
  }

  void _toggleVolume() {
    setState(() => _volumeExpanded = !_volumeExpanded);
    if (_volumeExpanded)
      _collapseVolumeLater();
    else
      _volumeTimer?.cancel();
  }

  void _changeVolume(double value) {
    unawaited(
      widget.services.rooms.setCallVolume(value.round()).catchError((
        Object error,
      ) {
        if (mounted) setState(() => _error = errorMessage(error));
      }),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.services.rooms,
    builder: (context, _) {
      final session = widget.services.rooms;
      final state = session.state;
      if (state.code == null && !widget.embedded && !_popped) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _closeIfLeft());
      }
      final car = widget.mode == DeviceMode.car;
      final automotive = car || widget.services.mic.isAutomotive;
      final showVolume = !automotive || carVolumeSlider;
      final inCall = session.call.isActive || session.joiningCall;
      final reconnect =
          session.canReconnect || (!state.isConnected && state.error != null);
      final blocked = session.callJoinBlockedReason;
      final (statusLabel, statusIcon) = switch (session.mediaConnection) {
        MediaConnectionState.connecting => ('음성 연결 중', 'refresh'),
        MediaConnectionState.connected => ('음성 수신 준비됨', 'check'),
        MediaConnectionState.failed => (
          '음성 연결 실패',
          session.permissionDenied ? 'lock' : 'hangup',
        ),
        MediaConnectionState.idle => ('음성 연결 대기', 'phone'),
      };
      final error =
          _error ??
          session.mediaError ??
          state.error ??
          session.call.error ??
          widget.services.mic.outputError;
      final status = StatusChip(
        blocked ??
            (session.permissionDenied
                ? session.mediaError ?? statusLabel
                : statusLabel),
        icon: blocked != null ? 'hangup' : statusIcon,
        active: session.mediaConnection == MediaConnectionState.connected,
      );
      final details = PanelScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              state.room?.name ?? '함께 가는 길',
              style: UnavoType.title.copyWith(fontSize: car ? 28 : 22),
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
                    child: session.permissionDenied
                        ? Semantics(
                            button: true,
                            label: '마이크 설정 열기',
                            child: GestureDetector(
                              onTap: () =>
                                  _run(widget.services.mic.openSettings),
                              child: status,
                            ),
                          )
                        : automotive && reconnect
                        ? Semantics(
                            button: true,
                            label: '다시 연결',
                            child: GestureDetector(
                              onTap: _busy || state.isLeaving
                                  ? null
                                  : () => _run(session.reconnect),
                              child: status,
                            ),
                          )
                        : status,
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
                  connection:
                      !inCall ||
                          member.handle == widget.services.store.handle ||
                          !MeshCoordinator.canJoin(
                            member.handle,
                            state.members.map((m) => m.handle),
                          )
                      ? null
                      : session.peerStates[member.handle] ??
                            MeshPeerState.connecting,
                ),
              ),
            ErrorText(error),
          ],
        ),
      );
      final exit = FloatingBarButton(
        label: '방 나가기',
        icon: 'exit',
        danger: true,
        onPressed: state.isLeaving || _busy ? null : () => _run(_leave),
      );
      final volume = FloatingBarButton(
        label: '통화 음량 ${session.callVolume}%',
        icon: session.callVolume == 0
            ? 'volume0'
            : session.callVolume < 50
            ? 'volume1'
            : 'volume2',
        selected: _volumeExpanded,
        onPressed: inCall ? _toggleVolume : null,
      );
      final controls = FloatingBar(
        key: const ValueKey('room-controls'),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: showVolume && _volumeExpanded
              ? [
                  volume,
                  Expanded(
                    child: Semantics(
                      label: '통화 음량',
                      child: Slider(
                        key: const ValueKey('call-volume-slider'),
                        value: session.callVolume.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 100,
                        activeColor: UnavoColors.gold,
                        label: '${session.callVolume}',
                        onChangeStart: (_) {
                          _volumeTimer?.cancel();
                          setState(() => _dragging = true);
                        },
                        onChanged: _changeVolume,
                        onChangeEnd: (_) {
                          setState(() => _dragging = false);
                          _collapseVolumeLater();
                        },
                      ),
                    ),
                  ),
                  exit,
                ]
              : [
                  FloatingBarButton(
                    label: session.muted ? '음소거 해제' : '음소거',
                    icon: session.muted ? 'micoff' : 'mic',
                    selected: session.muted,
                    onPressed: inCall
                        ? () => session.setMuted(!session.muted)
                        : null,
                  ),
                  if (reconnect && !automotive)
                    FloatingBarButton(
                      label: '다시 연결',
                      icon: 'refresh',
                      onPressed: _busy || state.isLeaving
                          ? null
                          : () => _run(session.reconnect),
                    ),
                  if (showVolume) volume,
                  if (!automotive)
                    FloatingBarButton(
                      label: session.outputLabel,
                      icon: session.outputRoute.icon,
                      onPressed: inCall && !_busy
                          ? () => _run(session.cycleOutputRoute)
                          : null,
                    ),
                  exit,
                ],
        ),
      );
      final pinned =
          _busy ||
          _volumeExpanded ||
          _dragging ||
          error != null ||
          session.mediaConnection == MediaConnectionState.failed;
      if (car) {
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: details),
            const SizedBox(height: 16),
            controls,
          ],
        );
        return widget.embedded
            ? content
            : PhoneFrame(mode: widget.mode, child: content);
      }
      if (widget.embedded) {
        return FloatingBarOverlay(
          bar: controls,
          keepVisible: pinned,
          child: details,
        );
      }
      return PhoneFrame(
        mode: widget.mode,
        bottomNav: controls,
        keepControlsVisible: pinned,
        child: details,
      );
    },
  );
}
