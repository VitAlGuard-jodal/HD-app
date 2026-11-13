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
import 'friends.dart';
import 'legal_consent.dart';
import 'map_credits.dart';
import 'mic.dart';
import 'profile.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.services,
    this.car = false,
    this.onRoom,
  });
  final AppServices services;
  final bool car;
  final ValueChanged<String>? onRoom;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  String? _error;
  _CarSetting _selected = _CarSetting.profile;

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

  Future<void> _saveServer(String normalizedUrl) async {
    final services = widget.services;
    final store = services.store;
    final previous = Uri.parse(store.baseUrl);
    final next = Uri.parse(normalizedUrl);
    final sameOrigin =
        previous.scheme == next.scheme &&
        previous.host == next.host &&
        previous.port == next.port;
    if (!sameOrigin && store.session != null) {
      // 로그아웃·공유·방 정리는 기존 서버 주소와 세션으로 끝낸다.
      await services.logout();
      await store.setBaseUrl(normalizedUrl);
      return; // main.dart가 로그인 화면으로 바꾸므로 route를 추가로 pop하지 않는다.
    }
    await store.setBaseUrl(normalizedUrl);
    if (!mounted) return;
    if (widget.car) {
      FocusScope.of(context).unfocus();
      setState(() {});
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => ControlScale(
    car: widget.car,
    child: widget.car
        ? Builder(builder: _carSettings)
        : _SettingsPage(
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
                                  key: const ValueKey(
                                    'settings-call-volume-slider',
                                  ),
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
                                      onSaveServer: _saveServer,
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

  Widget _carSettings(BuildContext context) {
    final gap = ControlScale.gap(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            PanelButton(
              key: const ValueKey('settings-back'),
              label: '뒤로',
              icon: 'back',
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
            SizedBox(width: gap),
            Text('설정 · ${_selected.label}', style: UnavoType.title),
          ],
        ),
        SizedBox(height: gap),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: ControlScale.target(context),
                child: PanelScroll(
                  child: Column(
                    children: [
                      for (final item in _CarSetting.values) ...[
                        if (item.index > 0) SizedBox(height: gap),
                        KeyedSubtree(
                          key: ValueKey('car-settings-menu-${item.name}'),
                          child: KeyedSubtree(
                            key: item.legacyKey == null
                                ? null
                                : ValueKey<String>(item.legacyKey!),
                            child: PanelButton(
                              label: item.label,
                              icon: item.icon,
                              selected: _selected == item,
                              style: _selected == item
                                  ? PanelButtonStyle.gold
                                  : PanelButtonStyle.neutral,
                              onPressed: _busy
                                  ? null
                                  : () {
                                      FocusScope.of(context).unfocus();
                                      setState(() {
                                        _selected = item;
                                        _error = null;
                                      });
                                    },
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SizedBox(width: gap),
              Expanded(
                child: Container(
                  key: const ValueKey('car-settings-detail'),
                  decoration: panelDecoration(opaque: true),
                  padding: EdgeInsets.all(gap),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: KeyedSubtree(
                          key: ValueKey(
                            'car-settings-content-${_selected.name}',
                          ),
                          child: _carDetail(context),
                        ),
                      ),
                      ErrorText(_error),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _carDetail(BuildContext context) => switch (_selected) {
    _CarSetting.profile => ProfileScreen(
      api: widget.services.api,
      store: widget.services.store,
      car: true,
      showBackButton: false,
    ),
    _CarSetting.friends => FriendsScreen(
      services: widget.services,
      onRoom: widget.onRoom ?? (_) {},
    ),
    _CarSetting.mic => MicScreen(router: widget.services.mic),
    _CarSetting.volume => ListenableBuilder(
      listenable: widget.services.rooms,
      builder: (context, _) {
        final volume = widget.services.rooms.callVolume;
        return Align(
          alignment: Alignment.topCenter,
          child: Row(
            key: const ValueKey('settings-volume'),
            children: [
              const StatusChip('통화 음량', icon: 'volume2'),
              SizedBox(width: ControlScale.gap(context)),
              Expanded(
                child: Semantics(
                  label: '통화 음량',
                  child: SizedBox(
                    height: ControlScale.target(context),
                    child: Slider(
                      key: const ValueKey('settings-call-volume-slider'),
                      value: volume.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      activeColor: UnavoColors.gold,
                      label: '$volume',
                      onChanged: _busy ? null : _changeVolume,
                    ),
                  ),
                ),
              ),
              SizedBox(width: ControlScale.gap(context)),
              Text('$volume', style: UnavoType.body),
            ],
          ),
        );
      },
    ),
    _CarSetting.server => AuthScreen(
      api: widget.services.api,
      store: widget.services.store,
      mode: DeviceMode.car,
      serverSettingsOnly: true,
      showBackButton: false,
      onSaveServer: _saveServer,
    ),
    // 새 법률 문구를 만들지 않고 기존의 두 정본을 각각 먼저 연다.
    _CarSetting.terms => const LegalDocumentsScreen(showBackButton: false),
    _CarSetting.consent => const LegalDocumentsScreen(
      initialIndex: 1,
      showBackButton: false,
    ),
    _CarSetting.map => MapCreditsScreen(
      provider: widget.services.mapProvider,
      showBackButton: false,
    ),
    _CarSetting.logout => PanelScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('로그아웃', style: UnavoType.title),
          SizedBox(height: ControlScale.gap(context)),
          const Text('로그아웃하려면 아래 버튼을 누르세요.', style: UnavoType.body),
          SizedBox(height: ControlScale.gap(context)),
          PanelButton(
            key: const ValueKey('settings-logout'),
            label: '로그아웃',
            icon: 'lock',
            style: PanelButtonStyle.danger,
            onPressed: _busy ? null : _logout,
          ),
        ],
      ),
    ),
  };
}

enum _CarSetting {
  profile('프로필', 'user', 'settings-profile'),
  friends('친구', 'friends'),
  mic('마이크', 'mic', 'settings-mic'),
  volume('통화 음량', 'volume2'),
  server('서버 주소', 'server', 'settings-server'),
  terms('약관', 'check', 'settings-legal'),
  consent('동의 문서', 'location'),
  map('지도 출처', 'map', 'settings-map'),
  logout('로그아웃', 'lock');

  const _CarSetting(this.label, this.icon, [this.legacyKey]);
  final String label;
  final String icon;
  final String? legacyKey;
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
