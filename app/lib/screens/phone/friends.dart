import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/handle_rules.dart';
import '../../core/app_services.dart';
import '../../core/errors.dart';
import '../../net/models.dart';
import '../../room/room_session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/floating_bar.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_field.dart';
import '../../ui/widgets/panel_scroll.dart';
import '../../ui/widgets/status_chip.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({
    super.key,
    required this.services,
    required this.onRoom,
  });
  final AppServices services;
  final ValueChanged<String> onRoom;
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _handle = TextEditingController();
  List<User> _contacts = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_run(_load));
  }

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final contacts = await widget.services.api.listContacts();
    if (mounted)
      setState(() {
        _contacts = contacts;
      });
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

  Future<void> _add() async {
    final id = _handle.text.trim();
    if (!HandleRules.isValid(id)) throw const FormatException(HandleRules.help);
    await widget.services.api.addContact(id);
    if (!mounted) return;
    _handle.clear();
    await _load();
  }

  Future<void> _room(User contact) async {
    if (widget.services.rooms.state.code != null)
      throw StateError(joinedRoomReason);
    final room = await widget.services.api.createRoom(
      invitees: [contact.handle],
    );
    await widget.services.rooms.open(room.code);
    if (mounted) {
      FocusScope.of(context).unfocus();
      widget.onRoom(room.code);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.services.rooms,
    builder: (context, _) {
      final current = widget.services.rooms.state;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: StatusChip('친구', icon: 'friends'),
                ),
              ),
              Text(
                '${_contacts.length}',
                style: const TextStyle(fontSize: 16, color: UnavoColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: PanelField(
                  controller: _handle,
                  label: '친구 아이디',
                  icon: 'user',
                  enabled: !_busy,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _run(_add),
                ),
              ),
              const SizedBox(width: 12),
              PanelButton(
                label: '친구 추가',
                icon: 'plus',
                iconOnly: true,
                style: PanelButtonStyle.gold,
                onPressed: _busy ? null : () => _run(_add),
              ),
            ],
          ),
          Expanded(
            child: PanelViewport(
              child: ListView(
                padding: EdgeInsets.only(
                  top: 18,
                  bottom: 9 + FloatingBarInset.of(context),
                ),
                clipBehavior: Clip.none,
                children: [
                  ErrorText(_error),
                  if (current.code != null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        joinedRoomReason,
                        style: TextStyle(
                          fontSize: 16,
                          color: UnavoColors.muted,
                        ),
                      ),
                    ),
                  if (_contacts.isEmpty)
                    StatusChip(
                      _busy ? '친구를 불러오는 중' : '추가한 친구 없음',
                      icon: _busy ? 'refresh' : 'friends',
                    ),
                  for (final (index, contact) in _contacts.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 84),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Text(
                                (index + 1).toString().padLeft(2, '0'),
                                style: UnavoType.western.copyWith(fontSize: 23),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    contact.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '@${contact.handle}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: UnavoColors.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  StatusChip(
                                    current.members.any(
                                          (m) => m.handle == contact.handle,
                                        )
                                        ? '같은 방'
                                        : '친구',
                                    icon:
                                        current.members.any(
                                          (m) => m.handle == contact.handle,
                                        )
                                        ? 'rooms'
                                        : 'friends',
                                    active: current.members.any(
                                      (m) => m.handle == contact.handle,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            PanelButton(
                              label: '${contact.displayName} 통화방 이동',
                              icon: 'phone',
                              iconOnly: true,
                              onPressed: _busy || current.code != null
                                  ? null
                                  : () => _run(() => _room(contact)),
                            ),
                            const SizedBox(width: 12),
                            PanelButton(
                              label: '${contact.displayName} 삭제',
                              icon: 'trash',
                              iconOnly: true,
                              style: PanelButtonStyle.danger,
                              onPressed: _busy
                                  ? null
                                  : () => _run(() async {
                                      await widget.services.api.removeContact(
                                        contact.handle,
                                      );
                                      await _load();
                                    }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  PanelButton(
                    label: '목록 새로고침',
                    icon: 'refresh',
                    onPressed: _busy ? null : () => _run(_load),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}
