import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/errors.dart';
import '../../net/models.dart';
import '../../room/room_session.dart';
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/focus_ring.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/room_code.dart';
import '../../ui/widgets/panel_field.dart';
import '../../ui/widgets/status_chip.dart';

class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key, required this.services, required this.onRoom});
  final AppServices services;
  final ValueChanged<String> onRoom;
  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _enter({required bool create}) async {
    if (_busy || widget.services.rooms.state.code != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!create && _code.text.trim().isEmpty)
        throw const FormatException('방 코드를 입력해 주세요.');
      final Room room = create
          ? await widget.services.api.createRoom(name: _name.text.trim())
          : await widget.services.api.joinRoom(_code.text.trim());
      if (create && mounted) _name.clear();
      await widget.services.rooms.open(room.code);
      if (mounted) {
        FocusScope.of(context).unfocus();
        widget.onRoom(room.code);
      }
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

  Future<void> _logout() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.logout();
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.services.rooms,
    builder: (context, _) {
      final current = widget.services.rooms.state;
      final canEnter = !_busy && current.code == null;
      return PanelScroll(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('함께 갈 길', style: UnavoType.title),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: PanelField(
                    controller: _name,
                    label: '새 방 이름',
                    icon: 'rooms',
                    enabled: canEnter,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _enter(create: true),
                  ),
                ),
                const SizedBox(width: 12),
                PanelButton(
                  label: '방 만들기',
                  icon: 'plus',
                  iconOnly: true,
                  style: PanelButtonStyle.gold,
                  onPressed: canEnter ? () => _enter(create: true) : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: PanelField(
                    controller: _code,
                    label: '방 코드',
                    icon: 'rooms',
                    enabled: canEnter,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _enter(create: false),
                  ),
                ),
                const SizedBox(width: 12),
                PanelButton(
                  label: '코드로 참여',
                  icon: 'arrow',
                  iconOnly: true,
                  style: PanelButtonStyle.gold,
                  onPressed: canEnter ? () => _enter(create: false) : null,
                ),
              ],
            ),
            if (current.code != null) ...[
              const SizedBox(height: 12),
              const Text(
                joinedRoomReason,
                style: TextStyle(fontSize: 16, color: UnavoColors.muted),
              ),
            ],
            ErrorText(_error),
            const SizedBox(height: 18),
            const Text(
              '내 방',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (current.code == null)
              const Text(
                '참여 중인 방이 없습니다.',
                style: TextStyle(fontSize: 16, color: UnavoColors.muted),
              )
            else
              FocusRing(
                child: Semantics(
                  button: true,
                  label: '현재 방 ${current.code}',
                  child: GestureDetector(
                    onTap: () => widget.onRoom(current.code!),
                    child: Material(
                      color: UnavoColors.input,
                      child: InkWell(
                        onTap: () => widget.onRoom(current.code!),
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 88),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: UnavoColors.line),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      current.room?.name ?? '함께 가는 길',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: UnavoType.body,
                                    ),
                                    RoomCode(current.code!, fontSize: 40),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '${current.members.length}명',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: UnavoColors.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  const UnavoIcon('arrow'),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (current.code != null) ...[
              const SizedBox(height: 12),
              StatusChip(
                widget.services.rooms.call.isActive ? '통화 중' : '참여 중',
                active: true,
              ),
            ],
            const SizedBox(height: 24),
            PanelButton(
              label: '로그아웃',
              icon: 'exit',
              onPressed: _busy ? null : _logout,
            ),
          ],
        ),
      );
    },
  );
}
