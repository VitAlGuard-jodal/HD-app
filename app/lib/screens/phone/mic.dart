import 'dart:async';

import 'package:flutter/material.dart';

import '../../audio/mic_ranker.dart';
import '../../audio/mic_router.dart';
import '../../core/errors.dart';
import '../../ui/widgets/mic_level.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/status_chip.dart';

class MicScreen extends StatefulWidget {
  const MicScreen({super.key, required this.router, this.showLevel = true});
  final MicRouter router;
  final bool showLevel;
  @override
  State<MicScreen> createState() => _MicScreenState();
}

class _MicScreenState extends State<MicScreen> with WidgetsBindingObserver {
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run(widget.router.refreshPermissions));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed)
      unawaited(_run(widget.router.refreshPermissions));
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused)
      unawaited(_stopPreview());
  }

  Future<void> _stopPreview() async {
    try {
      await widget.router.stopPreview();
    } catch (_) {
      /* 앱 종료 중 채널이 이미 닫힐 수 있다. */
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopPreview());
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

  Future<void> _preview() async {
    if (widget.router.state.isPreviewing) {
      await widget.router.stopPreview();
      return;
    }
    if (!widget.router.permissions.microphone)
      await widget.router.requestPermissions();
    if (!mounted) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      return;
    if (!widget.router.permissions.microphone)
      throw StateError('마이크 권한을 허용해 주세요.');
    await widget.router.startPreview();
  }

  String _icon(int type) => switch (type) {
    7 => 'bluetooth',
    22 || 3 => 'headset',
    15 => 'mic',
    _ => 'mobile',
  };
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.router,
    builder: (context, _) {
      final state = widget.router.state;
      final devices = MicRanker.rank(state.mode, state.devices);
      final callOwnsCapture =
          state.isCallActive || (state.isRecording && !state.isPreviewing);
      return PanelScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('어디서 말할까요', style: UnavoType.title),
            const SizedBox(height: 12),
            if (!widget.router.supported)
              const Text('이 기기의 오디오 연결은 아직 지원하지 않습니다.', style: UnavoType.body)
            else if (devices.isEmpty)
              const Text('사용 가능한 마이크가 없습니다.', style: UnavoType.body),
            for (final device in devices)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(child: Text(device.name, style: UnavoType.body)),
                    const SizedBox(width: 12),
                    PanelButton(
                      label: '${device.name} 선택',
                      icon: _icon(device.type),
                      selected: state.selected?.id == device.id,
                      style: state.selected?.id == device.id
                          ? PanelButtonStyle.gold
                          : PanelButtonStyle.neutral,
                      onPressed: _busy
                          ? null
                          : () => _run(() => widget.router.choose(device.id)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            if (widget.showLevel) MicLevel(router: widget.router),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: PanelButton(
                    label: '자동 선택',
                    icon: 'wave',
                    selected: state.manualId == null,
                    style: state.manualId == null
                        ? PanelButtonStyle.gold
                        : PanelButtonStyle.neutral,
                    onPressed: _busy || !widget.router.supported
                        ? null
                        : () => _run(() => widget.router.choose(null)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PanelButton(
                    label: state.isPreviewing ? '시험 종료' : '입력 시험',
                    icon: state.isPreviewing ? 'micoff' : 'mic',
                    selected: state.isPreviewing,
                    style: state.isPreviewing
                        ? PanelButtonStyle.gold
                        : PanelButtonStyle.neutral,
                    onPressed:
                        _busy || !widget.router.supported || callOwnsCapture
                        ? null
                        : () => _run(_preview),
                  ),
                ),
              ],
            ),
            if (callOwnsCapture)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: StatusChip('통화 입력 사용 중', icon: 'phone', active: true),
              ),
            if (widget.router.supported &&
                (!widget.router.permissions.microphone ||
                    !widget.router.permissions.notifications)) ...[
              const SizedBox(height: 12),
              Text(
                !widget.router.permissions.microphone
                    ? '마이크 권한 필요'
                    : '알림 권한 필요',
                style: UnavoType.body,
              ),
              const SizedBox(height: 12),
              PanelButton(
                label: '마이크·알림 권한 요청',
                icon: 'lock',
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await widget.router.requestPermissions();
                      }),
              ),
              const SizedBox(height: 12),
              PanelButton(
                label: '앱 권한 설정 열기',
                icon: 'server',
                onPressed: _busy
                    ? null
                    : () => _run(widget.router.openSettings),
              ),
            ],
            ErrorText(_error ?? state.error),
          ],
        ),
      );
    },
  );
}
