import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../auth/handle_rules.dart';
import '../../auth/session_store.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../core/server_address.dart';
import '../../net/api_client.dart';
import '../../ui/icons.dart';
import '../../ui/control_scale.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/panel_field.dart';
import '../../ui/widgets/phone_frame.dart';
import '../../ui/widgets/status_chip.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.api,
    required this.store,
    required this.mode,
    this.serverSettingsOnly = false,
    this.onSaveServer,
  });
  final ApiClient api;
  final SessionStore store;
  final DeviceMode mode;
  final bool serverSettingsOnly;
  final Future<void> Function(String normalizedUrl)? onSaveServer;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _handle = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  late final TextEditingController _server;
  final _scroll = ScrollController();
  bool _signup = false;
  bool _over14 = false;
  bool _serverExpanded = false;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.store.baseUrl);
    for (final field in [_handle, _password, _displayName]) {
      field.addListener(_inputChanged);
    }
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  String? get _validationMessage {
    if (_handle.text.isNotEmpty && !HandleRules.isValid(_handle.text.trim()))
      return HandleRules.help;
    final passwordLength = _password.text.runes.length;
    if (_signup &&
        _password.text.isNotEmpty &&
        (passwordLength < 8 || passwordLength > 72)) {
      return '비밀번호는 8~72자로 입력해 주세요.';
    }
    final nameLength = _displayName.text.trim().runes.length;
    if (_signup &&
        _displayName.text.isNotEmpty &&
        (nameLength < 2 || nameLength > 20)) {
      return '표시 이름은 2~20자로 입력해 주세요.';
    }
    return null;
  }

  @override
  void dispose() {
    _handle.dispose();
    _password.dispose();
    _displayName.dispose();
    _server.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.serverSettingsOnly) {
        final onSaveServer = widget.onSaveServer;
        if (onSaveServer != null) {
          await onSaveServer(
            ServerAddress.normalize(
              _server.text,
              allowPrivateCleartext: kDebugMode,
            ),
          );
        } else {
          await _saveServer();
          if (mounted) Navigator.of(context).pop();
        }
        return;
      }
      if (_signup && !_over14) {
        throw const FormatException('만 14세 이상만 가입할 수 있습니다.');
      }
      final id = _handle.text.trim();
      if (!HandleRules.isValid(id))
        throw const FormatException(HandleRules.help);
      final password = _password.text;
      if (password.isEmpty) throw const FormatException('비밀번호를 입력해 주세요.');
      final name = _displayName.text.trim();
      if (_signup) {
        if (name.runes.length < 2 || name.runes.length > 20)
          throw const FormatException('표시 이름은 2~20자로 입력해 주세요.');
        if (password.runes.length < 8 || password.runes.length > 72)
          throw const FormatException('비밀번호는 8~72자로 입력해 주세요.');
      }
      await _saveServer();
      final result = _signup
          ? await widget.api.signup(id, password, name)
          : await widget.api.login(id, password);
      if (mounted) _password.clear();
      if (mounted) FocusScope.of(context).unfocus();
      await widget.store.save(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = errorMessage(error);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients)
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  Future<void> _saveServer() => widget.store.setBaseUrl(
    ServerAddress.normalize(_server.text, allowPrivateCleartext: kDebugMode),
  );

  Widget _serverField() => PanelField(
    controller: _server,
    label: 'https://…',
    icon: 'server',
    enabled: !_busy,
    keyboardType: TextInputType.url,
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => _submit(),
  );

  @override
  Widget build(BuildContext context) => widget.serverSettingsOnly
      ? _serverSettings(context)
      : widget.mode == DeviceMode.car
      ? _carAuthentication()
      : _authentication();

  Widget _serverSettings(BuildContext context) => ControlScale(
    car: widget.mode == DeviceMode.car,
    child: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: widget.mode == DeviceMode.car
              ? Builder(builder: _carServerSettings)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: PanelButton(
                        key: const ValueKey('server-settings-back'),
                        label: '뒤로',
                        icon: 'back',
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: PanelScroll(
                        controller: _scroll,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [_serverField(), ErrorText(_error)],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    PanelButton(
                      key: const ValueKey('server-settings-save'),
                      label: '서버 주소 저장',
                      icon: 'check',
                      style: PanelButtonStyle.gold,
                      onPressed: _busy ? null : _submit,
                    ),
                  ],
                ),
        ),
      ),
    ),
  );

  Widget _carServerSettings(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          PanelButton(
            key: const ValueKey('server-settings-back'),
            label: '뒤로',
            icon: 'back',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          SizedBox(width: ControlScale.gap(context)),
          Expanded(child: _serverField()),
          SizedBox(width: ControlScale.gap(context)),
          PanelButton(
            key: const ValueKey('server-settings-save'),
            label: '서버 주소 저장',
            icon: 'check',
            style: PanelButtonStyle.gold,
            onPressed: _busy ? null : _submit,
          ),
        ],
      ),
      SizedBox(height: ControlScale.gap(context)),
      Expanded(
        child: PanelScroll(controller: _scroll, child: ErrorText(_error)),
      ),
    ],
  );

  Widget _authentication() => PhoneFrame(
    mode: widget.mode,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: StatusChip('로그인·가입', icon: 'user'),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            for (var i = 0; i < 2; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(
                child: PanelButton(
                  label: i == 0 ? '로그인' : '가입',
                  icon: i == 0 ? 'login' : 'userplus',
                  selected: _signup == (i == 1),
                  style: _signup == (i == 1)
                      ? PanelButtonStyle.gold
                      : PanelButtonStyle.neutral,
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _signup = i == 1;
                          _error = null;
                        }),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: PanelScroll(
            controller: _scroll,
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PanelField(
                    controller: _handle,
                    label: '아이디',
                    icon: 'user',
                    enabled: !_busy,
                    keyboardType: TextInputType.visiblePassword,
                    autofillHints: const [AutofillHints.username],
                  ),
                  const SizedBox(height: 12),
                  PanelField(
                    controller: _password,
                    label: '비밀번호',
                    icon: 'lock',
                    enabled: !_busy,
                    obscureText: true,
                    autofillHints: [
                      _signup
                          ? AutofillHints.newPassword
                          : AutofillHints.password,
                    ],
                    textInputAction: _signup
                        ? TextInputAction.next
                        : TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_signup) ...[
                    const SizedBox(height: 12),
                    PanelField(
                      controller: _displayName,
                      label: '표시 이름',
                      icon: 'user',
                      enabled: !_busy,
                      autofillHints: const [AutofillHints.nickname],
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        PanelButton(
                          key: const ValueKey('signup-age-check'),
                          icon: 'check',
                          label: '만 14세 이상 확인',
                          selected: _over14,
                          style: _over14
                              ? PanelButtonStyle.gold
                              : PanelButtonStyle.neutral,
                          onPressed: _busy
                              ? null
                              : () => setState(() => _over14 = !_over14),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('만 14세 이상입니다', style: UnavoType.body),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  PanelButton(
                    label: _serverExpanded ? '서버 주소 접기' : '서버 주소 설정',
                    selected: _serverExpanded,
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _serverExpanded = !_serverExpanded;
                          }),
                    child: Row(
                      children: [
                        UnavoIcon('server', size: ControlScale.icon(context)),
                        const Spacer(),
                        RotatedBox(
                          quarterTurns: _serverExpanded ? 2 : 0,
                          child: UnavoIcon(
                            'chevron',
                            size: ControlScale.icon(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_serverExpanded) ...[
                    const SizedBox(height: 12),
                    _serverField(),
                  ],
                  ErrorText(_error ?? _validationMessage),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        PanelButton(
          label: _busy ? '연결 중' : (_signup ? '가입하고 시작' : '시작'),
          icon: 'arrow',
          style: PanelButtonStyle.gold,
          onPressed: _busy ? null : _submit,
        ),
      ],
    ),
  );

  Widget _carAuthentication() => PhoneFrame(
    mode: widget.mode,
    onCarSettings: _busy
        ? null
        : () => setState(() => _serverExpanded = !_serverExpanded),
    child: Builder(
      builder: (context) {
        final gap = ControlScale.gap(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const StatusChip('로그인·가입', icon: 'user'),
                SizedBox(width: gap),
                for (var i = 0; i < 2; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  PanelButton(
                    key: ValueKey(
                      i == 0 ? 'car-auth-login' : 'car-auth-signup',
                    ),
                    label: i == 0 ? '로그인' : '가입',
                    icon: i == 0 ? 'login' : 'userplus',
                    selected: _signup == (i == 1),
                    style: _signup == (i == 1)
                        ? PanelButtonStyle.gold
                        : PanelButtonStyle.neutral,
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _signup = i == 1;
                            _error = null;
                          }),
                  ),
                ],
                const Spacer(),
                PanelButton(
                  key: const ValueKey('car-auth-server-toggle'),
                  label: _serverExpanded ? '서버 주소 접기' : '서버 주소 설정',
                  icon: 'server',
                  selected: _serverExpanded,
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _serverExpanded = !_serverExpanded;
                        }),
                ),
              ],
            ),
            SizedBox(height: gap),
            // IME가 높이를 줄여도 입력과 제출은 함께 고정한다.
            // 서버 주소·오류만 아래 영역에서 별도로 스크롤한다.
            AutofillGroup(
              child: Row(
                key: const ValueKey('car-auth-form'),
                children: [
                  Expanded(
                    child: PanelField(
                      controller: _handle,
                      label: '아이디',
                      icon: 'user',
                      enabled: !_busy,
                      keyboardType: TextInputType.visiblePassword,
                      autofillHints: const [AutofillHints.username],
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: PanelField(
                      controller: _password,
                      label: '비밀번호',
                      icon: 'lock',
                      enabled: !_busy,
                      obscureText: true,
                      autofillHints: [
                        _signup
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      textInputAction: _signup
                          ? TextInputAction.next
                          : TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  if (_signup) ...[
                    SizedBox(width: gap),
                    Expanded(
                      child: PanelField(
                        controller: _displayName,
                        label: '표시 이름',
                        icon: 'user',
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.nickname],
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                    SizedBox(width: gap),
                    SizedBox(
                      width: ControlScale.target(context) * 3,
                      child: Row(
                        children: [
                          PanelButton(
                            key: const ValueKey('signup-age-check'),
                            label: '만 14세 이상 확인',
                            icon: 'check',
                            selected: _over14,
                            style: _over14
                                ? PanelButtonStyle.gold
                                : PanelButtonStyle.neutral,
                            onPressed: _busy
                                ? null
                                : () => setState(() => _over14 = !_over14),
                          ),
                          SizedBox(width: gap),
                          const Expanded(
                            child: Text('만 14세 이상입니다', style: UnavoType.body),
                          ),
                        ],
                      ),
                    ),
                  ],
                  SizedBox(width: gap),
                  PanelButton(
                    key: const ValueKey('car-auth-submit'),
                    label: _busy ? '연결 중' : (_signup ? '가입하고 시작' : '시작'),
                    icon: 'arrow',
                    style: PanelButtonStyle.gold,
                    onPressed: _busy ? null : _submit,
                  ),
                ],
              ),
            ),
            SizedBox(height: gap),
            Expanded(
              child: PanelScroll(
                controller: _scroll,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_serverExpanded) _serverField(),
                    ErrorText(_error ?? _validationMessage),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
