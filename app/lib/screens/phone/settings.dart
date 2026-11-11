import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../ui/control_scale.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/status_chip.dart';
import 'auth.dart';
import 'legal_consent.dart';
import 'map_credits.dart';
import 'mic.dart';
import 'profile.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.services, this.car = false});
  final AppServices services;
  final bool car;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _open(Widget screen) async {
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ControlScale(car: widget.car, child: screen),
      ),
    );
    if (mounted) setState(() {});
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

  Future<void> _logout() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.logout();
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ControlScale(
    car: widget.car,
    child: _SettingsPage(
      backKey: const ValueKey('settings-back'),
      child: ListenableBuilder(
        listenable: widget.services.rooms,
        builder: (context, _) {
          final session = widget.services.rooms;
          return PanelScroll(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PanelButton(
                  key: const ValueKey('settings-profile'),
                  label: '프로필',
                  icon: 'user',
                  onPressed: _busy
                      ? null
                      : () => _open(
                          ProfileScreen(
                            api: widget.services.api,
                            store: widget.services.store,
                            car: widget.car,
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                Row(
                  key: const ValueKey('settings-volume'),
                  children: [
                    StatusChip(
                      '통화 음량',
                      icon: session.callVolume == 0
                          ? 'volume0'
                          : session.callVolume < 50
                          ? 'volume1'
                          : 'volume2',
                    ),
                    Expanded(
                      child: Semantics(
                        label: '통화 음량',
                        child: SizedBox(
                          height: ControlScale.target(context),
                          child: Slider(
                            key: const ValueKey('settings-call-volume-slider'),
                            value: session.callVolume.toDouble(),
                            min: 0,
                            max: 100,
                            divisions: 100,
                            activeColor: UnavoColors.gold,
                            label: '${session.callVolume}',
                            onChanged: _busy ? null : _changeVolume,
                          ),
                        ),
                      ),
                    ),
                    Text('${session.callVolume}', style: UnavoType.body),
                  ],
                ),
                const SizedBox(height: 16),
                PanelButton(
                  key: const ValueKey('settings-mic'),
                  label: '마이크',
                  icon: 'mic',
                  onPressed: _busy
                      ? null
                      : () => _open(
                          _SettingsPage(
                            backKey: const ValueKey('settings-mic-back'),
                            child: MicScreen(router: widget.services.mic),
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                Row(
                  key: const ValueKey('settings-server'),
                  children: [
                    PanelButton(
                      label: '서버 주소',
                      icon: 'server',
                      onPressed: _busy
                          ? null
                          : () => _open(
                              AuthScreen(
                                api: widget.services.api,
                                store: widget.services.store,
                                mode: widget.car
                                    ? DeviceMode.car
                                    : DeviceMode.phone,
                                serverSettingsOnly: true,
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.services.store.baseUrl,
                        style: UnavoType.body,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                PanelButton(
                  key: const ValueKey('settings-legal'),
                  label: '약관·동의 문서',
                  icon: 'check',
                  onPressed: _busy
                      ? null
                      : () => _open(const LegalDocumentsScreen()),
                ),
                const SizedBox(height: 16),
                PanelButton(
                  key: const ValueKey('settings-map'),
                  label: '지도 출처',
                  icon: 'map',
                  onPressed: _busy
                      ? null
                      : () => _open(
                          MapCreditsScreen(
                            provider: widget.services.mapProvider,
                          ),
                        ),
                ),
                const SizedBox(height: 16),
                PanelButton(
                  key: const ValueKey('settings-logout'),
                  label: '로그아웃',
                  icon: 'lock',
                  onPressed: _busy ? null : _logout,
                ),
                ErrorText(_error),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.backKey, required this.child});
  final Key backKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: PanelButton(
                key: backKey,
                label: '뒤로',
                icon: 'back',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(child: child),
          ],
        ),
      ),
    ),
  );
}
