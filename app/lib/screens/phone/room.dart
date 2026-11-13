import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/legal_consent_store.dart';
import '../../audio/mic_router.dart' show OutputRouteLabel;
import '../../call/media_engine.dart';
import '../../call/mesh_coordinator.dart';
import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../map/room_map.dart';
import '../../net/models.dart';
import '../../ui/control_scale.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/floating_bar.dart';
import '../../ui/widgets/member_tile.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/unavo_dialog.dart';
import '../car/car_shell.dart';
import '../../ui/widgets/member_avatar.dart';
import '../../ui/widgets/unavo_watermark.dart';
import '../../ui/widgets/room_code.dart';
import '../../ui/widgets/status_chip.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.services,
    required this.mode,
    this.embedded = false,
    this.onHome,
  });
  final AppServices services;
  final DeviceMode mode;
  final bool embedded;
  final VoidCallback? onHome;
  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  bool _busy = false;
  bool _volumeExpanded = false;
  bool _dragging = false;
  bool fullscreenMap = false;
  bool _dialogScheduled = false;
  bool _popped = false;
  String? _error;
  Timer? _volumeTimer;
  final _mapKey = GlobalKey();
  late final _mapController = RoomMapController.create(
    widget.services.mapProvider,
  );

  @override
  void dispose() {
    _volumeTimer?.cancel();
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
        ModalRoute.of(context)?.isCurrent == true &&
        widget.services.rooms.state.code == null) {
      _popped = true;
      Navigator.of(context).pop();
    }
  }

  Future<void> _leave() async {
    await widget.services.rooms.leave();
    _closeIfLeft();
  }

  Future<void> _tapMember(BuildContext dialogContext, Member member) async {
    final session = widget.services.rooms;
    final code = session.state.code;
    if (code == null) return;
    if (member.handle == widget.services.store.handle) {
      await _stopSharing(dialogContext);
      return;
    }
    final stopping = session.followIntent == member.handle;
    if (!stopping && !session.checkFollowAllowed(member.handle)) return;
    final token = session.beginLocationStart(member.handle);
    bool valid() => mounted && session.locationStartValid(token);
    var pending = false;
    try {
      final accepted = await showConsentDialog(
        dialogContext,
        title: stopping ? '따라가기 중지' : '따라가기',
        lines: stopping
            ? [
                member.displayName,
                '${member.displayName} 님의 따라가기를 중지합니다',
                '지도는 닫히고 내 위치 공유는 계속됩니다',
              ]
            : [
                member.displayName,
                '${member.displayName} 님의 위치를 따라갑니다',
                '내 위치도 같은 방 참여자에게 보입니다',
                '화면이 꺼져 있어도 공유 중에는 위치를 보냅니다',
                '방을 나가거나 위치 공유를 중지하면 공유가 끝납니다',
                '위치는 방이 있는 동안만 서버(국내)에 남습니다',
                '동의하지 않아도 통화는 계속됩니다',
              ],
      );
      if (!mounted ||
          !dialogContext.mounted ||
          session.state.code != code ||
          session.state.isLeaving)
        return;
      if (!accepted) {
        if (!stopping)
          await showNoticeDialog(
            dialogContext,
            message: '동의하지 않아 따라가기 기능을 사용할 수 없습니다',
          );
        return;
      }
      if (stopping) {
        await session.stopFollowing();
        return;
      }
      if (!valid()) return;
      final consentRevision = widget.services.store.sessionRevision;
      unawaited(
        widget.services.api
            .recordConsent(locationVersion: locationLegalVersion)
            .then<void>(
              (consent) {
                if (!mounted) return;
                widget.services.store.updateConsent(
                  consent,
                  sessionRevision: consentRevision,
                );
              },
              onError: (Object error, StackTrace stack) {
                debugPrint('위치 동의 기록 전송 실패: $error');
              },
            ),
      );
      if (!valid()) return;
      await session.locationShare.start(token: token, stillValid: valid);
      if (!valid() || !session.locationShare.sharing) return;
      await session.startFollowing(member.handle);
      if (valid() && session.locationShare.sharing) {
        pending = session.pendingFollow == member.handle;
        if (!pending) session.finishLocationStart(token);
      }
    } finally {
      if (!pending) session.cancelLocationStart(token);
    }
  }

  Future<void> _stopSharing(BuildContext dialogContext) async {
    final session = widget.services.rooms;
    final code = session.state.code;
    if (!session.locationShare.sharing) return;
    final accepted = await showConsentDialog(
      dialogContext,
      title: '위치 공유 중지',
      lines: ['내 위치 공유를 중지합니다'],
      note: '위치 공유를 중단하면 그룹 안 파트너와의 따라가기 연결이 끊깁니다. 통화는 계속됩니다. 그래도 하시겠습니까?',
    );
    if (accepted &&
        mounted &&
        session.state.code == code &&
        !session.state.isLeaving) {
      await session.locationShare.stop();
    }
  }

  void _scheduleFollowDialogs(BuildContext dialogContext) {
    final session = widget.services.rooms;
    if (_busy ||
        _dialogScheduled ||
        session.state.isLeaving ||
        (!session.hasFollowNotice && session.readyFollowRequests.isEmpty))
      return;
    _dialogScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dialogScheduled = false;
      if (!mounted || !dialogContext.mounted || _busy) return;
      unawaited(
        _run(() async {
          final code = session.state.code;
          bool current() =>
              mounted &&
              dialogContext.mounted &&
              session.state.code == code &&
              !session.state.isLeaving;
          while (current()) {
            if (!dialogContext.mounted) return;
            final notice = session.takeFollowNotice();
            if (notice != null) {
              final name = session.displayNameOf(notice.target);
              await showNoticeDialog(
                dialogContext,
                message: switch (notice.reason) {
                  'left' => '$name 님이 연결을 종료하여 따라가기가 끝났습니다',
                  'stopped' => '$name 님이 위치 공유를 중지했습니다',
                  'stale' => '$name 님의 위치 수신이 끊겨 따라가기가 끝났습니다',
                  'requester-stale' => '내 위치 수신이 끊겨 따라가기가 끝났습니다',
                  _ => '$name 님이 위치 공유에 동의하지 않았습니다',
                },
              );
              continue;
            }
            final request = session.readyFollowRequests.firstOrNull;
            if (request == null) break;
            final name = request.displayName ?? request.requester;
            final token = session.beginLocationStart(
              request.requester,
              requestId: request.requestId,
            );
            bool valid() => current() && session.locationStartValid(token);
            try {
              var accepted = session.locationShare.sharing;
              if (!accepted) {
                if (!dialogContext.mounted) return;
                accepted = await showConsentDialog(
                  dialogContext,
                  title: '따라가기 요청',
                  lines: [
                    name,
                    '$name 님이 내 위치를 따라가려 합니다',
                    '동의하면 내 위치가 같은 방 참여자에게 보입니다',
                    '화면이 꺼져 있어도 공유 중에는 위치를 보냅니다',
                    '방을 나가거나 위치 공유를 중지하면 끝납니다',
                    '위치는 방이 있는 동안만 서버(국내)에 남습니다',
                    '동의하지 않아도 통화는 계속됩니다',
                  ],
                );
              }
              if (!valid()) continue;
              if (accepted) {
                final consentRevision = widget.services.store.sessionRevision;
                unawaited(
                  widget.services.api
                      .recordConsent(locationVersion: locationLegalVersion)
                      .then<void>(
                        (consent) {
                          if (!mounted) return;
                          widget.services.store.updateConsent(
                            consent,
                            sessionRevision: consentRevision,
                          );
                        },
                        onError: (Object error, StackTrace stack) {
                          debugPrint('위치 동의 기록 전송 실패: $error');
                        },
                      ),
                );
                if (!valid()) continue;
                await session.locationShare.start(
                  token: token,
                  stillValid: valid,
                );
              }
              if (!valid()) continue;
              await session.respondToFollow(
                request.requestId,
                accepted: accepted && session.locationShare.sharing,
              );
            } finally {
              session.cancelLocationStart(token);
            }
          }
        }),
      );
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
  Widget build(BuildContext context) => ControlScale(
    car: widget.mode == DeviceMode.car,
    child: Builder(
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([
          widget.services.rooms,
          widget.services.mapAuthError,
        ]),
        builder: (context, _) {
          final session = widget.services.rooms;
          final state = session.state;
          if (session.followTarget == null) fullscreenMap = false;
          _scheduleFollowDialogs(context);
          if (state.code == null && !widget.embedded && !_popped) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _closeIfLeft());
          }
          final car = widget.mode == DeviceMode.car;
          final automotive = car || widget.services.mic.isAutomotive;
          final inCall =
              !state.isLeaving &&
              (session.call.isActive || session.joiningCall);
          final reconnect =
              session.canReconnect ||
              (!state.isConnected && state.error != null);
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
              widget.services.mapAuthError.value ??
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
          Widget memberTile(Member member, {bool compact = false}) =>
              MemberTile(
                key: ValueKey('member-${member.handle}'),
                compact: compact,
                onTap:
                    (member.handle == widget.services.store.handle &&
                            !session.locationShare.sharing) ||
                        _busy ||
                        session.deviceReplaced ||
                        state.isLeaving
                    ? null
                    : () => _run(() => _tapMember(context, member)),
                member: member,
                api: widget.services.api,
                fallbackOrder: state.members.indexOf(member),
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
                    : session.peerStates[member.handle] ??
                          MeshPeerState.connecting,
              );
          final membersByHandle = {
            for (final member in state.members) member.handle: member,
          };
          final map = RoomMap(
            api: widget.services.api,
            key: _mapKey,
            controller: _mapController,
            provider: widget.services.mapProvider,
            authError: widget.services.mapAuthError.value,
            positions: session.positions.map(
              (handle, fix) => MapEntry(
                handle,
                RoomMapPosition(
                  fix,
                  displayName: session.displayNameOf(handle),
                  avatar: membersByHandle[handle]?.avatar ?? const Avatar(),
                  order:
                      membersByHandle[handle]?.order ??
                      state.members
                          .indexWhere((member) => member.handle == handle)
                          .clamp(0, state.members.length),
                ),
              ),
            ),
            trail: session.trailOf(session.followTarget),
            targetHandle: session.followTarget,
            selfHandle: widget.services.store.handle,
            following: session.followTarget != null,
            brightness: MediaQuery.platformBrightnessOf(context),
            car: car,
            fullscreen: fullscreenMap,
            onFullscreen: () => setState(() => fullscreenMap = !fullscreenMap),
            onStopSharing:
                _busy || !session.locationShare.sharing || state.isLeaving
                ? null
                : () => _run(() => _stopSharing(context)),
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
          final volumeButtons = <Widget>[
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
          ];
          final leftButtons = <Widget>[
            FloatingBarButton(
              label: session.muted ? '음소거 해제' : '음소거',
              icon: session.muted ? 'micoff' : 'mic',
              selected: session.muted,
              onPressed:
                  inCall && !session.exitProtected && !session.deviceReplaced
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
            volume,
          ];
          final rightButtons = <Widget>[
            if (!automotive)
              FloatingBarButton(
                label: session.outputLabel,
                icon: session.outputRoute.icon,
                onPressed: inCall && !_busy
                    ? () => _run(session.cycleOutputRoute)
                    : null,
              ),
            exit,
          ];
          final carButtons = <Widget>[
            leftButtons.first,
            volume,
            FloatingBarButton(
              key: const ValueKey('room-home'),
              label: '홈',
              icon: 'home',
              onPressed: widget.onHome,
            ),
            exit,
          ];
          double carControlHeight(double width) {
            if (_volumeExpanded) return ControlScale.target(context) + 16;
            final target = ControlScale.target(context);
            final gap = ControlScale.gap(context);
            final columns = ((width - 16 + gap) / (target + gap)).floor().clamp(
              1,
              carButtons.length,
            );
            final rows = (carButtons.length / columns).ceil();
            return rows * target + (rows - 1) * gap + 16;
          }

          final controls = car
              ? LayoutBuilder(
                  builder: (context, constraints) => FloatingBar(
                    key: const ValueKey('room-controls'),
                    height: carControlHeight(constraints.maxWidth),
                    child: _volumeExpanded
                        ? Row(children: volumeButtons)
                        : Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            spacing: ControlScale.gap(context),
                            runSpacing: ControlScale.gap(context),
                            children: carButtons,
                          ),
                  ),
                )
              : FloatingBar(
                  key: const ValueKey('room-controls'),
                  child: _volumeExpanded
                      ? LayoutBuilder(
                          builder: (context, constraints) =>
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SizedBox(
                                  width:
                                      constraints.maxWidth < (car ? 320 : 200)
                                      ? (car ? 320 : 200)
                                      : constraints.maxWidth,
                                  child: Row(children: volumeButtons),
                                ),
                              ),
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            // 재연결/출력 유무가 달라도 좌우 폭은 같게 확보한다.
                            final sideCount =
                                leftButtons.length > rightButtons.length
                                ? leftButtons.length
                                : rightButtons.length;
                            final minWidth =
                                (sideCount * 2 + 1) * (car ? 80.0 : 48.0);
                            return SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: constraints.maxWidth < minWidth
                                    ? minWidth
                                    : constraints.maxWidth,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: leftButtons,
                                      ),
                                    ),
                                    FloatingBarButton(
                                      key: const ValueKey('room-home'),
                                      label: '홈',
                                      icon: 'home',
                                      onPressed: widget.onHome,
                                    ),
                                    Expanded(
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: rightButtons,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                );
          Widget dock(Widget child) => Stack(
            fit: StackFit.expand,
            children: [
              child,
              Positioned(left: 8, right: 8, bottom: 8, child: controls),
            ],
          );
          Widget callPanel({
            required bool compact,
            required bool horizontal,
          }) => Container(
            key: const ValueKey('room-call-panel'),
            color: UnavoColors.ink,
            child: LayoutBuilder(
              builder: (context, constraints) => dock(
                Stack(
                  fit: StackFit.expand,
                  children: [
                    const UnavoWatermark(),
                    SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        8,
                        12,
                        car
                            ? carControlHeight(constraints.maxWidth - 16) + 24
                            : 88,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!compact) ...[
                            Text(
                              state.room?.name ?? '함께 가는 길',
                              style: UnavoType.title,
                            ),
                            RoomCode(state.code ?? ''),
                            const SizedBox(height: 12),
                          ],
                          statusRow,
                          Row(
                            key: const ValueKey('room-ready-summary'),
                            children: [
                              Semantics(
                                label:
                                    '출발 준비 ${session.readyCount}/${state.members.length}',
                                child: Row(
                                  children: [
                                    const UnavoIcon('check'),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${session.readyCount}/${state.members.length}',
                                      style: UnavoType.body,
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              PanelButton(
                                key: const ValueKey('room-ready-toggle'),
                                label: session.selfReady ? '출발 준비 취소' : '출발 준비',
                                icon: 'check',
                                selected: session.selfReady,
                                style: session.selfReady
                                    ? PanelButtonStyle.call
                                    : PanelButtonStyle.neutral,
                                onPressed:
                                    _busy ||
                                        session.readyBusy ||
                                        !state.isConnected ||
                                        state.isLeaving ||
                                        session.deviceReplaced
                                    ? null
                                    : () => _run(session.toggleReady),
                              ),
                            ],
                          ),
                          if (session.vehicleNotice != null ||
                              session.deviceReplaced ||
                              session.exitProtected)
                            Row(
                              key: const ValueKey('room-vehicle-notice'),
                              children: [
                                Expanded(
                                  child: Text(
                                    session.vehicleNotice ?? '',
                                    style: UnavoType.body,
                                  ),
                                ),
                                if (session.deviceReplaced)
                                  PanelButton(
                                    key: const ValueKey('room-take-back'),
                                    label: '이 기기에서 다시 참여',
                                    icon: 'login',
                                    onPressed:
                                        _busy ||
                                            state.isLeaving ||
                                            session.takingBack
                                        ? null
                                        : () => _run(session.takeBack),
                                  )
                                else if (session.exitProtected)
                                  PanelButton(
                                    key: const ValueKey('room-exit-resume'),
                                    label: '차량 마이크와 이전 위치 공유 다시 켜기',
                                    icon: 'refresh',
                                    onPressed: _busy || state.isLeaving
                                        ? null
                                        : () => _run(session.resumeAfterExit),
                                  ),
                              ],
                            ),
                          ErrorText(error),
                          if (session.locationShare.deletionStatus
                              case final deletion?)
                            Text(deletion, style: UnavoType.caption),
                          if (session.pendingFollow != null)
                            const Text(
                              '따라가기 응답 대기 중',
                              style: UnavoType.caption,
                            ),
                          const SizedBox(height: 8),
                          if (horizontal)
                            SizedBox(
                              key: const ValueKey('room-member-strip'),
                              height: 104,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: state.members.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (_, index) => SizedBox(
                                  width: 272,
                                  child: SingleChildScrollView(
                                    child: memberTile(state.members[index]),
                                  ),
                                ),
                              ),
                            )
                          else if (car && !compact)
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final gap = ControlScale.gap(context);
                                return Wrap(
                                  key: const ValueKey('car-room-members'),
                                  spacing: gap,
                                  runSpacing: gap,
                                  children: [
                                    for (final member in state.members)
                                      SizedBox(
                                        width: constraints.maxWidth >= 800
                                            ? (constraints.maxWidth - gap) / 2
                                            : constraints.maxWidth,
                                        child: memberTile(member),
                                      ),
                                  ],
                                );
                              },
                            )
                          else
                            for (final member in state.members)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: memberTile(member, compact: compact),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          final content = LayoutBuilder(
            builder: (context, constraints) {
              final showingMap = session.followTarget != null;
              final sideBySide =
                  car || constraints.maxWidth > constraints.maxHeight;
              if (!showingMap)
                return callPanel(compact: false, horizontal: false);
              if (fullscreenMap) {
                return dock(
                  Stack(
                    key: const ValueKey('room-fullscreen-map'),
                    fit: StackFit.expand,
                    children: [
                      map,
                      Positioned(
                        left: 12,
                        top: 12,
                        right: car ? 88 : 68,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          clipBehavior: Clip.none,
                          child: Row(
                            children: [
                              for (final member in state.members.take(6))
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: MemberAvatar(
                                    key: ValueKey('speaker-${member.handle}'),
                                    member: member,
                                    api: widget.services.api,
                                    fallbackOrder: state.members.indexOf(
                                      member,
                                    ),
                                    defaultMascot: true,
                                    diameter: car ? 56 : 40,
                                    speaking:
                                        member.handle ==
                                            widget.services.store.handle
                                        ? session.localSpeaking
                                        : session.speaking.contains(
                                            member.handle,
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (error != null)
                        Positioned(
                          left: 12,
                          right: car ? 88 : 68,
                          bottom: car ? 152 : 120,
                          child: ErrorText(error),
                        ),
                    ],
                  ),
                );
              }
              return Flex(
                direction: sideBySide ? Axis.horizontal : Axis.vertical,
                children: [
                  Expanded(flex: 7, child: map),
                  Expanded(
                    flex: 3,
                    child: callPanel(compact: true, horizontal: !sideBySide),
                  ),
                ],
              );
            },
          );
          if (widget.embedded) return content;
          if (car) return CarShell(room: true, primary: content);
          return Scaffold(body: SafeArea(child: content));
        },
      ),
    ),
  );
}
