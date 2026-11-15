import 'dart:async';
import 'package:flutter/material.dart';
import '../../location/meeting_plan_controller.dart';
import '../../net/meeting_plan.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_field.dart';

class MeetingPlanPanel extends StatefulWidget {
  const MeetingPlanPanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onShowPoint,
    required this.displayName,
  });
  final MeetingPlanController controller;
  final VoidCallback onClose;
  final void Function(double lat, double lng) onShowPoint;
  final String Function(String) displayName;
  @override
  State<MeetingPlanPanel> createState() => _MeetingPlanPanelState();
}

class _MeetingPlanPanelState extends State<MeetingPlanPanel> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  MeetingPointField? _field;
  bool _wasEditing = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    final c = widget.controller;
    if (!c.canEditMeetingPlan || !c.editing || _field != c.field) {
      _focus.unfocus();
      _query.clear();
    }
    if (_wasEditing && !c.editing && !c.canEditMeetingPlan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onClose();
      });
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  Widget button(
    String icon,
    String label,
    VoidCallback? action, {
    bool selected = false,
  }) => PanelButton(
    icon: icon,
    label: label,
    onPressed: action,
    selected: selected,
    style: selected ? PanelButtonStyle.gold : PanelButtonStyle.neutral,
  );
  void _show() {
    final p = widget.controller.pendingPoint;
    if (p != null) widget.onShowPoint(p.point.lat, p.point.lng);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, can = c.canEditMeetingPlan && !c.busy;
    _field = c.field;
    _wasEditing = c.editing;
    final plan = c.active ?? c.targetPlan ?? c.ownPlan;
    return Material(
      color: UnavoColors.panel,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('합류 지점 따라가기', style: UnavoType.body),
                  ),
                  button('back', '합류 계획 닫기', () {
                    c.dismissEditor();
                    widget.onClose();
                  }),
                ],
              ),
              const SizedBox(height: 8),
              if (!can) const Text('정차와 최신 위치가 확인된 뒤 설정할 수 있습니다'),
              if (c.error != null)
                Text(
                  '${c.error}${c.retrySeconds == null ? '' : ' · ${c.retrySeconds}초'}',
                ),
              if (!c.editing) ...[
                Text(c.selected ? c.status : '그룹장이 목적지와 합류 지점을 정합니다'),
                if (plan != null) ...[
                  Text('목적지 · ${plan.plan.destination.label}'),
                  Text('합류 지점 · ${plan.plan.joinPoint?.label ?? '설정 전'}'),
                  Text(
                    plan.plan.policy == MeetingPolicy.wait
                        ? '합류 지점에서 기다리기'
                        : '먼저 목적지까지 가기',
                  ),
                  if (plan.plan.destinationOnly) const Text('목적지에서 만나요'),
                  if (plan.runtime?.vehicle(plan.plan.leaderHandle)
                      case final leader?)
                    Text(_vehicleStatus(c, leader)),
                  for (final id in plan.plan.participantFollowRequestIds)
                    Text(_participantStatus(c, id)),
                ],
                if (c.etaText != null) Text(c.etaText!),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    button(
                      'plus',
                      '내 그룹 합류 계획 편집',
                      can ? () => c.beginEditing() : null,
                    ),
                    button(
                      'navigation',
                      '내 그룹장 안내 선택',
                      can && c.ownPlan != null
                          ? () => unawaited(c.selectOwnGuidance())
                          : null,
                      selected: c.selected && c.owner,
                    ),
                    button(
                      'route',
                      '앞차의 합류 계획 참여',
                      c.canEnroll ? () => unawaited(c.enroll(true)) : null,
                      selected: c.selected && !c.owner,
                    ),
                    button(
                      'player-play',
                      '함께 출발 준비',
                      c.canDepart ? () => unawaited(c.depart()) : null,
                    ),
                    button(
                      'trash',
                      '내 합류 계획 취소',
                      can && c.ownPlan != null
                          ? () => unawaited(c.cancelPlan())
                          : null,
                    ),
                  ],
                ),
              ] else ...[
                Text(
                  c.field == MeetingPointField.destination
                      ? '목적지 선택'
                      : '합류 지점 선택',
                ),
                const Text('지도를 길게 누르거나 주소를 검색한 뒤 후보를 확인해 주세요'),
                Wrap(
                  spacing: 8,
                  children: [
                    button(
                      'navigation',
                      '목적지 선택',
                      can
                          ? () => c.selectField(MeetingPointField.destination)
                          : null,
                      selected: c.field == MeetingPointField.destination,
                    ),
                    button(
                      'route',
                      '합류 지점 선택',
                      can
                          ? () => c.selectField(MeetingPointField.joinPoint)
                          : null,
                      selected: c.field == MeetingPointField.joinPoint,
                    ),
                  ],
                ),
                Text('목적지 · ${c.destination?.label ?? '미선택'}'),
                Text('합류 지점 · ${c.joinPoint?.label ?? '미선택'}'),
                if (c.capabilities.geocoding) ...[
                  const SizedBox(height: 8),
                  PanelField(
                    controller: _query,
                    focusNode: _focus,
                    label: '도로명 또는 지번 주소 입력',
                    icon: 'search',
                    enabled: can,
                    textInputAction: TextInputAction.search,
                    enableSuggestions: false,
                    onSubmitted: can
                        ? (value) => unawaited(c.search(value))
                        : null,
                  ),
                  button(
                    'search',
                    '주소 검색',
                    can && !c.searching
                        ? () => unawaited(c.search(_query.text))
                        : null,
                  ),
                  if (c.searching) const Text('주소 검색 중'),
                  if (c.searchMessage != null) Text(c.searchMessage!),
                  for (final result in c.addresses)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${result.label}${result.roadAddress.isNotEmpty && result.jibunAddress.isNotEmpty ? '\n${result.jibunAddress}' : ''}',
                          ),
                        ),
                        button(
                          'location',
                          '${result.label} 후보 보기',
                          can
                              ? () {
                                  c.selectAddress(result);
                                  _show();
                                }
                              : null,
                        ),
                      ],
                    ),
                ] else
                  const Text('주소 검색은 현재 사용할 수 없습니다. 지도에서 선택해 주세요'),
                const SizedBox(height: 8),
                const Text('추천 대상 · 수락된 직계 따라오기 차량'),
                if (c.participants.isEmpty) const Text('수락된 따라오기 차량이 없습니다'),
                for (final p in c.participants)
                  Row(
                    children: [
                      Expanded(child: Text('${p.displayName} · ${p.status}')),
                      button(
                        'check',
                        '${p.displayName} 추천 대상 선택',
                        can
                            ? () => c.toggleParticipant(p.followRequestId)
                            : null,
                        selected: c.selectedParticipants.contains(
                          p.followRequestId,
                        ),
                      ),
                    ],
                  ),
                const Text('겹치는 구간 기준 추천'),
                const Text('각 차량의 추천 경로가 이어지는 공통 후반 구간을 기준으로 계산합니다'),
                button(
                  'star',
                  '겹치는 구간 기준 추천',
                  can &&
                          c.capabilities.recommendation &&
                          c.destination != null &&
                          !c.recommending
                      ? () async {
                          await c.recommend();
                          if (mounted) _show();
                        }
                      : null,
                ),
                if (!c.capabilities.recommendation)
                  const Text('합류 지점 추천은 현재 사용할 수 없습니다'),
                if (c.recommending) const Text('선택한 차량의 경로 비교 중'),
                if (c.recommendation case final r?) ...[
                  Text(r.destinationOnly ? '목적지에서 만나요' : '겹치는 구간의 합류 후보'),
                  Text(
                    '계산 시각 ${DateTime.fromMillisecondsSinceEpoch(r.calculatedAtMs).toLocal().toString().substring(11, 19)} · 60초 동안 확인 가능',
                  ),
                  Text(
                    r.etaQuality == 'rough'
                        ? '전체 거리 비례로 계산한 대략적인 예상 시간'
                        : '추천 경로 구간 시간 기준 예상',
                  ),
                  if (r.vehicles.isNotEmpty &&
                      r.vehicles.every(
                        (e) =>
                            (e.seconds - r.vehicles.first.seconds).abs() < 30,
                      ))
                    const Text('비슷한 시각에 도착할 것으로 예상합니다'),
                  for (final eta in r.vehicles)
                    Text(
                      '${widget.displayName(eta.handle)} · 약 ${(eta.seconds / 60).ceil()}분 · 예상 대기 ${(eta.waitSeconds / 60).ceil()}분',
                    ),
                  Text(
                    '그룹장 추천 경로 기준 목적지까지 ${r.remainingMeters.round()}m · 약 ${(r.remainingSeconds / 60).ceil()}분',
                  ),
                ],
                if (c.pendingPoint case final p?) ...[
                  Text('후보 · ${p.label}'),
                  Wrap(
                    spacing: 8,
                    children: [
                      button('check', '지점 후보 확인', can ? c.confirmPoint : null),
                      button('back', '지점 후보 취소', can ? c.cancelPoint : null),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  c.policy == MeetingPolicy.wait
                      ? '합류 지점에서 기다리기'
                      : '먼저 목적지까지 가기',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    button(
                      'stop',
                      '합류 지점에서 기다리기',
                      can ? () => c.setPolicy(MeetingPolicy.wait) : null,
                      selected: c.policy == MeetingPolicy.wait,
                    ),
                    button(
                      'player-play',
                      '먼저 목적지까지 가기',
                      can ? () => c.setPolicy(MeetingPolicy.proceed) : null,
                      selected: c.policy == MeetingPolicy.proceed,
                    ),
                  ],
                ),
                if (c.policy == MeetingPolicy.wait)
                  Row(
                    children: [
                      const Expanded(
                        child: Text('정차 가능한 지점인지 확인해 주세요. 지도에서 옮길 수 있습니다'),
                      ),
                      button(
                        'check',
                        '정차 가능한 대기 장소 확인',
                        can && c.joinPoint != null
                            ? c.confirmWaitingPlace
                            : null,
                        selected: c.waitingPlaceConfirmed,
                      ),
                    ],
                  ),
                button(
                  'check',
                  c.joinPoint == null ? '목적지 초안 저장' : '합류 계획 확정',
                  can && c.destination != null && c.pendingPoint == null
                      ? () => unawaited(c.save())
                      : null,
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                '추천: 선택 차량의 현재 위치·목적지 / 안내·재계산: 내 현재 위치·목표를 네이버 Maps Directions 5에 제공합니다. 주소 검색: 입력 주소를 Geocoding에 제공합니다.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _participantStatus(MeetingPlanController c, String id) {
    final plan = c.active ?? c.targetPlan ?? c.ownPlan;
    final vehicles = plan?.runtime?.vehicles ?? const [];
    for (final v in vehicles) {
      if (v.followRequestId == id) return _vehicleStatus(c, v);
    }
    for (final p in c.participants) {
      if (p.followRequestId == id) return '${p.displayName} · 안내 미시작';
    }
    return '초대한 차량 · 안내 미시작';
  }

  String _vehicleStatus(MeetingPlanController c, PlanVehicle vehicle) {
    final eta = c.vehicleEtaText(vehicle);
    return '${widget.displayName(vehicle.handle)} · ${vehicle.status}${eta == null ? '' : ' · $eta'}';
  }
}
