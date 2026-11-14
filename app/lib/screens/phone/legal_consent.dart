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
  (
    title: '개인정보 처리방침',
    asset: 'assets/legal/privacy.md',
    summary: <(String, String)>[
      ('항목', '아이디·비밀번호(해시)·표시 이름·프로필 사진(선택)·친구·방·통화 연결 신호·위치(공유 중)·서비스 이용 기록'),
      ('목적', '같은 방 음성 통화, 내 차 위치·이동 경로 표시, 친구 초대, 장애 확인'),
      ('보유', '방·위치는 방이 사라질 때까지, 계정·친구는 삭제 요청까지, 이용 기록 30일'),
      (
        '제공',
        '같은 방 참여자(표시 이름·사진·통화 상태·위치), 네이버 지도 SDK(지도 영역 좌표), 네이버 클라우드 플랫폼 Maps(Directions 5)(뒷차 출발·앞차 기준점 좌표)',
      ),
      (
        '경로',
        '안내 시작·재계산 시 추천 경로 계산에 좌표만 제공. 계정·이름·사진·방 코드 제외. 제공처 보유 조건은 네이버 클라우드 플랫폼의 정책을 따릅니다',
      ),
      ('거부', '필수 항목이라 동의하지 않으면 서비스를 이용할 수 없습니다'),
    ],
  ),
  (
    title: '위치정보 수집·이용 동의',
    asset: 'assets/legal/location.md',
    summary: <(String, String)>[
      ('항목', '위치 공유 중의 위도·경도·정확도·속도·진행 방향·시각(화면 꺼짐·앱 전환 중에도 전송)'),
      (
        '제공',
        '같은 방 참여자, 네이버 클라우드 플랫폼 Maps(Directions 5)에 뒷차 출발·앞차 기준점(P0 또는 J) 좌표',
      ),
      (
        '경로',
        '안내 시작·합류 후 따라가기 재계산 때 앱 지도에 추천 경로를 그리기 위한 도로 경로 계산. 계정·이름·사진·방 코드는 보내지 않음',
      ),
      ('제공처 보유', '네이버 클라우드 플랫폼의 정책을 따릅니다'),
      ('보유', '방이 유지되는 동안 서버 메모리에만, 공유 중지·퇴장 시 즉시, 통신 두절 시 최대 2분 내 삭제'),
      ('거부', '선택 항목이라 동의하지 않아도 통화는 쓸 수 있고 위치 공유·따라가기만 쓸 수 없습니다'),
    ],
  ),
];

class LegalConsentCheckScreen extends StatelessWidget {
  const LegalConsentCheckScreen({
    super.key,
    required this.mode,
    required this.checking,
    required this.onRetry,
  });
  final DeviceMode mode;
  final bool checking;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => PhoneFrame(
    mode: mode,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            checking ? '동의 내역을 확인하는 중입니다' : '동의 내역을 확인하지 못했습니다. 다시 시도해 주세요.',
            style: UnavoType.body,
            textAlign: TextAlign.center,
          ),
          if (!checking) ...[
            const SizedBox(height: 16),
            PanelButton(
              key: const ValueKey('legal-retry'),
              label: '다시 시도',
              icon: 'refresh',
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    ),
  );
}

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
    final store = widget.services.store;
    final revision = store.sessionRevision;
    if (store.session == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final consent = await widget.services.api.recordConsent(
        privacyVersion: legalVersion,
        locationVersion: _checked[1] ? locationLegalVersion : null,
      );
      if (!hasPrivacyConsent(consent) ||
          (_checked[1] && !hasLocationConsent(consent))) {
        throw const FormatException('동의 내역을 저장하지 못했습니다. 다시 시도해 주세요.');
      }
      if (mounted && store.updateConsent(consent, sessionRevision: revision))
        widget.onAccepted();
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
            if (widget.mode == DeviceMode.car && !snapshot.hasData)
              snapshot.hasError
                  ? const ErrorText('동의 문서를 불러오지 못했습니다. 다시 시작해 주세요.')
                  : const Text('문서를 불러오는 중입니다', style: UnavoType.body),
            Expanded(
              child: widget.mode == DeviceMode.car
                  ? Row(
                      key: const ValueKey('car-consent-columns'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (
                          var index = 0;
                          index < _documents.length;
                          index++
                        ) ...[
                          if (index > 0)
                            SizedBox(width: ControlScale.gap(context)),
                          Expanded(
                            child: PanelScroll(
                              key: ValueKey('car-consent-document-$index'),
                              child: _consentDocument(context, snapshot, index),
                            ),
                          ),
                        ],
                      ],
                    )
                  : PanelScroll(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!snapshot.hasData && !snapshot.hasError)
                            const Text('문서를 불러오는 중입니다', style: UnavoType.body),
                          if (snapshot.hasError)
                            const ErrorText('동의 문서를 불러오지 못했습니다. 다시 시작해 주세요.'),
                          for (
                            var index = 0;
                            index < _documents.length;
                            index++
                          )
                            _consentDocument(context, snapshot, index),
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
                SizedBox(width: ControlScale.gap(context)),
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
  Widget _consentDocument(
    BuildContext context,
    AsyncSnapshot<List<String>> snapshot,
    int index,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
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
                  : () => setState(() => _checked[index] = !_checked[index]),
            ),
          ),
          SizedBox(width: ControlScale.gap(context)),
          Expanded(
            child: Text(
              '${_documents[index].title} (${index == 0 ? '필수' : '선택'})',
              style: UnavoType.body,
            ),
          ),
          SizedBox(width: ControlScale.gap(context)),
          PanelButton(
            key: ValueKey('legal-expand-$index'),
            label:
                '${_documents[index].title} 전문 ${_expanded[index] ? '접기' : '펼치기'}',
            icon: 'chevron',
            selected: _expanded[index],
            onPressed: _busy || !snapshot.hasData
                ? null
                : () => setState(() => _expanded[index] = !_expanded[index]),
            child: RotatedBox(
              quarterTurns: _expanded[index] ? 2 : 0,
              child: UnavoIcon('chevron', size: ControlScale.icon(context)),
            ),
          ),
        ],
      ),
      for (var line = 0; line < _documents[index].summary.length; line++) ...[
        if (line > 0) const SizedBox(height: 4),
        Text.rich(
          key: ValueKey('legal-summary-$index-$line'),
          TextSpan(
            children: [
              TextSpan(
                text: '${_documents[index].summary[line].$1}: ',
                style: UnavoType.body.copyWith(
                  fontWeight: FontWeight.bold,
                  color: UnavoColors.gold,
                ),
              ),
              TextSpan(text: _documents[index].summary[line].$2),
            ],
          ),
          style: UnavoType.body,
        ),
      ],
      const SizedBox(height: 8),
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
  );
}

/// 설정에서는 저장된 동의 여부를 바꾸지 않고 같은 원문 렌더러만 사용한다.
class LegalDocumentsScreen extends StatefulWidget {
  const LegalDocumentsScreen({
    super.key,
    this.initialIndex = 0,
    this.showBackButton = true,
  }) : assert(initialIndex >= 0 && initialIndex < 2);
  final int initialIndex;
  final bool showBackButton;

  @override
  State<LegalDocumentsScreen> createState() => _LegalDocumentsScreenState();
}

class _LegalDocumentsScreenState extends State<LegalDocumentsScreen> {
  late int _index = widget.initialIndex;
  late final _texts = Future.wait([
    for (final document in _documents) rootBundle.loadString(document.asset),
  ]);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (widget.showBackButton)
                  PanelButton(
                    key: const ValueKey('legal-documents-back'),
                    label: '뒤로',
                    icon: 'back',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                const Spacer(),
                for (var index = 0; index < _documents.length; index++) ...[
                  if (index > 0) SizedBox(width: ControlScale.gap(context)),
                  PanelButton(
                    key: ValueKey('legal-document-$index'),
                    label: _documents[index].title,
                    icon: index == 0 ? 'user' : 'location',
                    selected: _index == index,
                    style: _index == index
                        ? PanelButtonStyle.gold
                        : PanelButtonStyle.neutral,
                    onPressed: () => setState(() => _index = index),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FutureBuilder<List<String>>(
                future: _texts,
                builder: (context, snapshot) => PanelScroll(
                  key: ValueKey('legal-document-text-$_index'),
                  child: snapshot.hasError
                      ? const ErrorText('동의 문서를 불러오지 못했습니다. 다시 열어 주세요.')
                      : snapshot.hasData
                      ? _legalText(snapshot.data![_index])
                      : const SizedBox.shrink(),
                ),
              ),
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
