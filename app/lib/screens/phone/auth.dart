import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../auth/handle_rules.dart';
import '../../auth/session_store.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../core/server_address.dart';
import '../../net/api_client.dart';
import '../../ui/icons.dart';
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
  });
  final ApiClient api;
  final SessionStore store;
  final DeviceMode mode;
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
      await widget.store.setBaseUrl(
        ServerAddress.normalize(
          _server.text,
          allowPrivateCleartext: kDebugMode,
        ),
      );
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

  @override
  Widget build(BuildContext context) => PhoneFrame(
    mode: widget.mode,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('함께 갈 준비.', style: UnavoType.title),
        const SizedBox(height: 16),
        Row(
          children: [
            for (var i = 0; i < 2; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(
                child: PanelButton(
                  label: i == 0 ? '로그인' : '가입',
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
                  ],
                  const SizedBox(height: 12),
                  PanelButton(
                    label: '서버 주소',
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _serverExpanded = !_serverExpanded;
                          }),
                    child: Row(
                      children: [
                        const UnavoIcon('server'),
                        const SizedBox(width: 12),
                        const Text('서버 주소', style: UnavoType.body),
                        const Spacer(),
                        Text(
                          _serverExpanded ? '접기' : '설정',
                          style: const TextStyle(
                            fontSize: 16,
                            color: UnavoColors.muted,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const UnavoIcon('chevron', size: 20),
                      ],
                    ),
                  ),
                  if (_serverExpanded) ...[
                    const SizedBox(height: 12),
                    PanelField(
                      controller: _server,
                      label: 'https://…',
                      icon: 'server',
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),
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
}
