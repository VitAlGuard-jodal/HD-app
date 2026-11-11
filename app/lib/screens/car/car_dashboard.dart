import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../../ui/widgets/mic_level.dart';
import '../../ui/widgets/floating_bar.dart';
import '../phone/friends.dart';
import '../phone/mic.dart';
import '../phone/room.dart';
import '../phone/rooms.dart';
import 'car_shell.dart';

class CarDashboard extends StatelessWidget {
  const CarDashboard({
    super.key,
    required this.services,
    this.showRoom = true,
    this.onRoom,
    this.onInteraction,
  });
  final AppServices services;
  final bool showRoom;
  final ValueChanged<String>? onRoom;
  final VoidCallback? onInteraction;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: services.rooms,
    builder: (context, _) => CarShell(
      room: services.rooms.state.code != null && showRoom,
      primary: services.rooms.state.code == null || !showRoom
          ? RoomsScreen(services: services, onRoom: onRoom ?? (_) {})
          : RoomScreen(
              services: services,
              mode: DeviceMode.car,
              embedded: true,
            ),
      secondary: _Companion(
        services: services,
        onRoom: onRoom ?? (_) {},
        onInteraction: onInteraction,
      ),
    ),
  );
}

class _Companion extends StatefulWidget {
  const _Companion({
    required this.services,
    required this.onRoom,
    this.onInteraction,
  });
  final AppServices services;
  final ValueChanged<String> onRoom;
  final VoidCallback? onInteraction;
  @override
  State<_Companion> createState() => _CompanionState();
}

class _CompanionState extends State<_Companion> {
  bool _microphone = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MicLevel(router: widget.services.mic),
      const SizedBox(height: 20),
      Expanded(
        child: _microphone
            ? MicScreen(router: widget.services.mic, showLevel: false)
            : FriendsScreen(services: widget.services, onRoom: widget.onRoom),
      ),
      const SizedBox(height: 16),
      FloatingBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final microphone in [false, true])
              FloatingBarButton(
                label: microphone ? '마이크' : '친구',
                icon: microphone ? 'mic' : 'friends',
                selected: _microphone == microphone,
                onPressed: () {
                  widget.onInteraction?.call();
                  FocusScope.of(context).unfocus();
                  setState(() => _microphone = microphone);
                },
              ),
          ],
        ),
      ),
    ],
  );
}
