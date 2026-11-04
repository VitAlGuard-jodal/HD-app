import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth/session_restore.dart';
import 'auth/session_store.dart';
import 'core/app_services.dart';
import 'core/device_mode.dart';
import 'screens/car/car_dashboard.dart';
import 'screens/phone/auth.dart';
import 'screens/phone/cover.dart';
import 'screens/phone/friends.dart';
import 'screens/phone/mic.dart';
import 'screens/phone/room.dart';
import 'screens/phone/rooms.dart';
import 'ui/appearance.dart';
import 'ui/theme.dart';
import 'ui/widgets/bottom_nav.dart';
import 'ui/widgets/phone_frame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  final store = SessionStore(await SharedPreferences.getInstance());
  final services = AppServices(store);
  final capabilities = await DeviceCapabilities.detect();
  try {
    await services.initialize();
  } catch (error) {
    debugPrint('플랫폼 초기화 실패: ${error.runtimeType}');
  }
  runApp(UnavoApp(services: services, mode: capabilities.mode));
}

class UnavoApp extends StatefulWidget {
  const UnavoApp({super.key, required this.services, required this.mode});
  final AppServices services;
  final DeviceMode mode;
  @override
  State<UnavoApp> createState() => _UnavoAppState();
}

class _UnavoAppState extends State<UnavoApp> {
  final _appearance = AppearanceController();
  final _navigator = GlobalKey<NavigatorState>();
  bool _cover = true;
  bool _roomVisible = false;
  bool _carRoomVisible = false;
  bool _startupUntouched = true;
  String? _restoredRoom;
  @override
  void initState() {
    super.initState();
    _carRoomVisible = widget.services.rooms.state.code != null;
    widget.services.store.addListener(_sessionChanged);
    widget.services.calls.onOpenRoom = _openRoom;
    unawaited(_restore());
  }

  Future<void> _restore() => restoreSession(
    api: widget.services.api,
    store: widget.services.store,
    rooms: widget.services.rooms,
    isCurrent: () => mounted,
    onRoomRestored: (code) {
      _restoredRoom = code;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openRestoredRoom());
    },
  );

  void _homeInteracted() {
    // Once the user acts, startup restoration must not take over their screen.
    _startupUntouched = false;
    _restoredRoom = null;
  }

  void _openRestoredRoom() {
    if (!mounted || _cover) return;
    final code = _restoredRoom;
    _restoredRoom = null;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editing =
        focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (code == null ||
        !_startupUntouched ||
        editing ||
        _roomVisible ||
        _navigator.currentState == null ||
        _navigator.currentState!.canPop() ||
        !widget.services.rooms.state.isConnected)
      return;
    _openRoom(code);
  }

  void _sessionChanged() {
    if (!mounted) return;
    if (widget.services.store.session == null) {
      _restoredRoom = null;
      _carRoomVisible = false;
      _navigator.currentState?.popUntil((route) => route.isFirst);
    }
    setState(() {});
  }

  void _openRoom(String code) {
    if (_cover ||
        widget.services.store.session == null ||
        _roomVisible ||
        !mounted)
      return;
    if (widget.services.rooms.state.code != code) return;
    _homeInteracted();
    widget.services.calls.pendingOpenRoom = null;
    if (widget.mode == DeviceMode.car) {
      setState(() => _carRoomVisible = true);
      return;
    }
    _roomVisible = true;
    unawaited(
      _navigator.currentState!
          .push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  RoomScreen(services: widget.services, mode: widget.mode),
            ),
          )
          .whenComplete(() {
            _roomVisible = false;
          }),
    );
  }

  void _continue() {
    setState(() {
      _cover = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = widget.services.calls.pendingOpenRoom;
      if (mounted && pending != null) {
        _openRoom(pending);
      } else {
        _openRestoredRoom();
      }
    });
  }

  @override
  void dispose() {
    widget.services.store.removeListener(_sessionChanged);
    widget.services.calls.onOpenRoom = null;
    _appearance.dispose();
    widget.services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UnavoAppearance(
    controller: _appearance,
    child: ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) => MaterialApp(
        title: '우나보',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigator,
        theme: unavoTheme(Brightness.light),
        darkTheme: unavoTheme(Brightness.dark),
        themeMode: _appearance.themeMode,
        home: _cover
            ? CoverScreen(mode: widget.mode, onContinue: _continue)
            : widget.services.store.session == null
            ? AuthScreen(
                api: widget.services.api,
                store: widget.services.store,
                mode: widget.mode,
              )
            : Focus(
                onKeyEvent: (_, _) {
                  _homeInteracted();
                  return KeyEventResult.ignored;
                },
                child: Listener(
                  onPointerDown: (_) => _homeInteracted(),
                  onPointerSignal: (_) => _homeInteracted(),
                  child: widget.mode == DeviceMode.car
                      ? CarDashboard(
                          services: widget.services,
                          showRoom: _carRoomVisible,
                          onRoom: _openRoom,
                          onInteraction: _homeInteracted,
                        )
                      : _PhoneTabs(
                          services: widget.services,
                          mode: widget.mode,
                          onRoom: _openRoom,
                          onInteraction: _homeInteracted,
                        ),
                ),
              ),
      ),
    ),
  );
}

class _PhoneTabs extends StatefulWidget {
  const _PhoneTabs({
    required this.services,
    required this.mode,
    required this.onRoom,
    required this.onInteraction,
  });
  final AppServices services;
  final DeviceMode mode;
  final ValueChanged<String> onRoom;
  final VoidCallback onInteraction;
  @override
  State<_PhoneTabs> createState() => _PhoneTabsState();
}

class _PhoneTabsState extends State<_PhoneTabs> {
  int _index = 0;
  @override
  Widget build(BuildContext context) => PhoneFrame(
    mode: widget.mode,
    bottomNav: BottomNav(
      index: _index,
      onChanged: (index) {
        widget.onInteraction();
        FocusScope.of(context).unfocus();
        setState(() {
          _index = index;
        });
      },
    ),
    // 화면을 떠나면 MicScreen이 dispose되어 시험 입력이 즉시 정리된다.
    child: switch (_index) {
      0 => RoomsScreen(services: widget.services, onRoom: widget.onRoom),
      1 => FriendsScreen(services: widget.services, onRoom: widget.onRoom),
      _ => MicScreen(router: widget.services.mic),
    },
  );
}
