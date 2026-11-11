import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/legal_consent_store.dart';
export '../../auth/legal_consent_store.dart';

import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../core/errors.dart';
import '../../ui/control_scale.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/phone_frame.dart';
import '../../ui/widgets/status_chip.dart';
import '../../ui/widgets/unavo_dialog.dart';

const _documents = [
  (title: '개인정보 처리방침', asset: 'assets/legal/privacy.md'),
  (title: '위치정보 수집·이용 동의', asset: 'assets/legal/location.md'),
];

class LegalConsentScreen extends StatefulWidget {
  const LegalConsentScreen({
    super.key,
    required this.services,
    required this.mode,
    required this.onAccepted,
  });
  final AppServices services;
  final DeviceMode mode;
  final VoidCallback onAccepted;

  @override
  State<LegalConsentScreen> createState() => _LegalConsentScreenState();
}

class _LegalConsentScreenState extends State<LegalConsentScreen> {
  late final _texts = Future.wait([
    for (final document in _documents) rootBundle.loadString(document.asset),
  ]);
  final _checked = [false, false];
  final _expanded = [false, false];
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    if (_busy || !_checked[0]) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await saveLegalConsent(
        widget.services.store.preferences,
        privacy: _checked[0],
        location: _checked[1],
      );
      if (mounted) widget.onAccepted();
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline(BuildContext dialogContext) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await showNoticeDialog(dialogContext, message: '동의하지 않아 서비스를 이용할 수 없습니다');
      if (!mounted) return;
      try {
        await widget.services.logout();
      } catch (_) {
        // 오프라인에서도 미동의 사용자의 로컬 세션은 종료한다.
        await widget.services.rooms.forget();
        await widget.services.store.clear();
      }
    } catch (error) {
      if (mounted) setState(() => _error = errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: false,
    child: PhoneFrame(
      mode: widget.mode,
      child: FutureBuilder<List<String>>(
        future: _texts,
        builder: (context, snapshot) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('서비스 이용 동의', style: UnavoType.title),
            const SizedBox(height: 16),
            Expanded(
              child: PanelScroll(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!snapshot.hasData && !snapshot.hasError)
                      const Text('문서를 불러오는 중입니다', style: UnavoType.body),
                    if (snapshot.hasError)
                      const ErrorText('동의 문서를 불러오지 못했습니다. 다시 시작해 주세요.'),
                    for (var index = 0; index < _documents.length; index++) ...[
                      Row(
                        children: [
                          Semantics(
                            checked: _checked[index],
                            child: PanelButton(
                              key: ValueKey('legal-check-$index'),
                              label: '${_documents[index].title} 동의',
                              icon: 'check',
                              selected: _checked[index],
                              style: _checked[index]
                                  ? PanelButtonStyle.gold
                                  : PanelButtonStyle.neutral,
                              onPressed: _busy || !snapshot.hasData
                                  ? null
                                  : () => setState(
                                      () => _checked[index] = !_checked[index],
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '${_documents[index].title} (${index == 0 ? '필수' : '선택'})',
                              style: UnavoType.body,
                            ),
                          ),
                          const SizedBox(width: 12),
                          PanelButton(
                            key: ValueKey('legal-expand-$index'),
                            label:
                                '${_documents[index].title} 전문 ${_expanded[index] ? '접기' : '펼치기'}',
                            icon: 'chevron',
                            selected: _expanded[index],
                            onPressed: _busy || !snapshot.hasData
                                ? null
                                : () => setState(
                                    () => _expanded[index] = !_expanded[index],
                                  ),
                            child: RotatedBox(
                              quarterTurns: _expanded[index] ? 2 : 0,
                              child: UnavoIcon(
                                'chevron',
                                size: ControlScale.icon(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_expanded[index] && snapshot.hasData) ...[
                        const SizedBox(height: 12),
                        Container(
                          key: ValueKey('legal-detail-$index'),
                          height: ControlScale.isCar(context) ? 280 : 220,
                          decoration: panelDecoration(opaque: true),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(12),
                            child: _legalText(snapshot.data![index]),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ),
            ErrorText(_error),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                PanelButton(
                  key: const ValueKey('legal-decline'),
                  label: '미동의',
                  icon: 'back',
                  onPressed: _busy ? null : () => _decline(context),
                ),
                const SizedBox(width: 12),
                PanelButton(
                  key: const ValueKey('legal-accept'),
                  label: '동의',
                  icon: 'check',
                  style: PanelButtonStyle.gold,
                  onPressed: !_busy && snapshot.hasData && _checked[0]
                      ? _accept
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _legalText(String markdown) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (final line in markdown.split('\n').map((line) => line.trim()))
      if (line.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            line.startsWith('## ')
                ? line.substring(3)
                : line.startsWith('# ')
                ? line.substring(2)
                : line.startsWith('- ')
                ? '• ${line.substring(2)}'
                : line,
            style: line.startsWith('## ')
                ? UnavoType.title.copyWith(fontSize: 20)
                : line.startsWith('# ')
                ? UnavoType.title
                : UnavoType.body,
          ),
        ),
  ],
);
