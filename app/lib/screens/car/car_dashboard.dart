import 'package:flutter/material.dart';

import '../../core/app_services.dart';
import '../../core/device_mode.dart';
import '../phone/room.dart';
import '../phone/rooms.dart';
import '../phone/settings.dart';
import 'car_shell.dart';

class CarDashboard extends StatefulWidget {
  const CarDashboard({
    super.key,
    required this.services,
    this.showRoom = true,
    this.onRoom,
    this.onHome,
    this.onInteraction,
  });
  final AppServices services;
  final bool showRoom;
  final ValueChanged<String>? onRoom;
  final VoidCallback? onHome;
  final VoidCallback? onInteraction;
  @override
  State<CarDashboard> createState() => _CarDashboardState();
}

class _CarDashboardState extends State<CarDashboard> {
  final _primaryNavigator = GlobalKey<NavigatorState>();
  bool _settingsVisible = false;

  @override
  void didUpdateWidget(CarDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showRoom && !oldWidget.showRoom) _settingsVisible = false;
  }

  void _openSettings() {
    widget.onInteraction?.call();
    FocusScope.of(context).unfocus();
    widget.onHome?.call();
    if (_settingsVisible) {
      _primaryNavigator.currentState?.popUntil(
        (route) => route is PageRoute && route.settings.name == 'settings',
      );
    } else {
      setState(() => _settingsVisible = true);
    }
  }

  void _removedPage(Page<Object?> page) {
    if (page.key == const ValueKey('car-settings') && _settingsVisible) {
      setState(() => _settingsVisible = false);
    } else if (page.key == const ValueKey('car-room') &&
        widget.showRoom &&
        !_settingsVisible) {
      widget.onHome?.call();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.services.rooms,
    builder: (context, _) {
      final roomVisible =
          widget.services.rooms.state.code != null &&
          widget.showRoom &&
          !_settingsVisible;
      return CarShell(
        room: roomVisible,
        onSettings: _openSettings,
        primary: NavigatorPopHandler<void>(
          onPopWithResult: (_) => _primaryNavigator.currentState?.maybePop(),
          child: Navigator(
            key: _primaryNavigator,
            onDidRemovePage: _removedPage,
            pages: [
              MaterialPage<void>(
                key: const ValueKey('car-rooms'),
                child: RoomsScreen(
                  services: widget.services,
                  onRoom: widget.onRoom ?? (_) {},
                ),
              ),
              if (roomVisible)
                MaterialPage<void>(
                  key: const ValueKey('car-room'),
                  child: RoomScreen(
                    services: widget.services,
                    mode: DeviceMode.car,
                    embedded: true,
                    onHome: widget.onHome,
                  ),
                ),
              if (_settingsVisible)
                MaterialPage<void>(
                  key: const ValueKey('car-settings'),
                  name: 'settings',
                  child: SettingsScreen(
                    services: widget.services,
                    car: true,
                    onRoom: (code) {
                      setState(() => _settingsVisible = false);
                      widget.onRoom?.call(code);
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
