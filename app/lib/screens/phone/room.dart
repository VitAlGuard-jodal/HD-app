import 'dart:async';

import 'package:flutter/material.dart';

import '../../audio/mic_router.dart';
import '../../call/media_engine.dart';
import '../../call/mesh_coordinator.dart';
import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../map/room_map.dart';
import '../../net/models.dart';
import '../../ui/appearance.dart';
import '../../ui/control_scale.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/floating_bar.dart';
import '../../ui/widgets/member_tile.dart';
import '../../ui/widgets/location_consent_sheet.dart';
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
  bool _mapInteracting = false;
  bool _popped = false;
  String? _error;
  Timer? _volumeTimer;
  Timer? _mapControlsTimer;
  final _mapController = RoomMapController();

  @override
  void dispose() {
    _volumeTimer?.cancel();
    _mapControlsTimer?.cancel();
    _mapController.dispose();
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

  Future<void> _toggleLocation() async {
    final share = widget.services.locationShare;
    if (share.sharing) {
      await share.stop();
      return;
    }
    final session = widget.services.rooms;
    final code = session.state.code;
    final accepted = await showLocationConsentSheet(
      context,
      session.state.members.map((member) => member.displayName).toList(),
    );
    if (!mounted || !accepted || code == null || session.state.code != code)
      return;
    await share.consent();
    if (!mounted || session.state.code != code) return;
    await share.start();
  }

  void _mapInteracted() {
    // 지도 제스처가 상위 바의 탭을 소비해도 조작부를 다시 볼 수 있게 한다.
    if (!_mapInteracting) setState(() => _mapInteracting = true);
    _mapControlsTimer?.cancel();
    _mapControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _mapInteracting = false);
    });
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
          session.locationShare.error ??
          session.followError ??
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
      final statusRow = Row(
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
                        onTap: () => _run(widget.services.mic.openSettings),
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
      );
      Widget memberTile(Member member) => MemberTile(
        member: member,
        self: member.handle == widget.services.store.handle,
        interrupted:
            inCall &&
            session.interrupted &&
            member.handle == widget.services.store.handle,
        speaking: member.handle == widget.services.store.handle
            ? session.localSpeaking
            : session.speaking.contains(member.handle),
        connection:
            !inCall ||
                member.handle == widget.services.store.handle ||
                !MeshCoordinator.canJoin(
                  member.handle,
                  state.members.map((m) => m.handle),
                )
            ? null
            : session.peerStates[member.handle] ?? MeshPeerState.connecting,
      );
      final names = {
        for (final member in state.members) member.handle: member.displayName,
      };
      final appearance = context
          .dependOnInheritedWidgetOfExactType<UnavoAppearance>();
      final map = RoomMap(
        key: ValueKey('room-map-${state.code}'),
        controller: _mapController,
        positions: session.positions.map(
          (handle, fix) => MapEntry(
            handle,
            RoomMapPosition(fix, displayName: names[handle] ?? handle),
          ),
        ),
        trail: session.leaderTrail,
        leaderHandle: session.leaderHandle,
        selfHandle: widget.services.store.handle,
        followLeader: session.followLeader,
        onInteraction: _mapInteracted,
        brightness:
            appearance?.notifier?.resolve(context) ??
            Theme.of(context).brightness,
      );
      final details = PanelScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              state.room?.name ?? '함께 가는 길',
              style: UnavoType.title.copyWith(fontSize: 22),
            ),
            const SizedBox(height: 10),
            RoomCode(state.code ?? ''),
            const SizedBox(height: 18),
            statusRow,
            ErrorText(error),
            const SizedBox(height: 12),
            for (final member in state.members)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: memberTile(member),
              ),
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
      final buttons = showVolume && _volumeExpanded
          ? <Widget>[
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
              FloatingBarButton(
                label: session.locationShare.sharing ? '위치 공유 중지' : '위치 공유',
                icon: session.locationShare.sharing
                    ? 'location'
                    : 'locationoff',
                selected: session.locationShare.sharing,
                onPressed:
                    session.locationShare.available &&
                        !_busy &&
                        !state.isLeaving
                    ? () => _run(_toggleLocation)
                    : null,
              ),
              FloatingBarButton(
                label: '그룹장 따라가기',
                icon: 'navigation',
                selected: session.followLeader,
                onPressed:
                    session.leaderHandle != null &&
                        session.leaderHandle != widget.services.store.handle &&
                        session.positions.containsKey(session.leaderHandle) &&
                        !state.isLeaving
                    ? () => session.setFollowLeader(!session.followLeader)
                    : null,
              ),
              FloatingBarButton(
                label: '내 위치로',
                icon: 'focus',
                onPressed:
                    session.positions.containsKey(widget.services.store.handle)
                    ? _mapController.recenter
                    : null,
              ),
              exit,
            ];
      final controls = FloatingBar(
        key: const ValueKey('room-controls'),
        child: showVolume && _volumeExpanded
            ? Row(children: buttons)
            : LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: buttons,
                    ),
                  ),
                ),
              ),
      );
      final pinned =
          _busy ||
          _volumeExpanded ||
          _dragging ||
          _mapInteracting ||
          error != null ||
          session.mediaConnection == MediaConnectionState.failed;
      if (car) {
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.room?.name ?? '함께 가는 길',
                    style: UnavoType.title,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 144,
                  child: RoomCode(state.code ?? '', fontSize: 24),
                ),
              ],
            ),
            const SizedBox(height: 8),
            statusRow,
            ErrorText(error),
            const SizedBox(height: 8),
            Expanded(child: map),
            SizedBox(
              key: const ValueKey('room-member-strip'),
              height: 112,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: state.members.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, index) => SizedBox(
                  width: 300,
                  child: SingleChildScrollView(
                    child: memberTile(state.members[index]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            controls,
          ],
        );
        return widget.embedded
            ? content
            : PhoneFrame(mode: widget.mode, child: content);
      }
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 45, child: map),
          Expanded(
            flex: 55,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: details,
            ),
          ),
        ],
      );
      if (widget.embedded) {
        return FloatingBarOverlay(
          bar: controls,
          keepVisible: pinned,
          child: content,
        );
      }
      return PhoneFrame(
        mode: widget.mode,
        bottomNav: controls,
        keepControlsVisible: pinned,
        child: content,
      );
    },
  );
}
