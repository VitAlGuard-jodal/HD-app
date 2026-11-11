import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth/session_restore.dart';
import 'auth/session_store.dart';
import 'core/app_services.dart';
import 'core/device_mode.dart';
import 'map/map_provider.dart';
import 'screens/car/car_dashboard.dart';
import 'screens/phone/auth.dart';
import 'screens/phone/cover.dart';
import 'screens/phone/friends.dart';
import 'screens/phone/legal_consent.dart';
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
  final capabilities = await DeviceCapabilities.detect();
  final services = AppServices(store, deviceMode: capabilities.mode);
  if (services.mapProvider == MapProvider.naver) {
    final clientId = naverClientId.trim();
    try {
      await FlutterNaverMap().init(
        clientId: clientId,
        onAuthFailed: (error) {
          // SDK 메시지에 인증값이 포함돼도 로그에는 남기지 않는다.
          final message = error.message ?? '';
          final safeMessage = clientId.isEmpty
              ? message
              : message.replaceAll(clientId, '[redacted]');
          debugPrint('map: 네이버 인증 실패 (${error.code}) $safeMessage');
          services.setMapAuthError(error.code);
        },
      );
    } catch (error) {
      services.mapProvider = MapProvider.vworld;
      services.mapAuthError.value = null;
      debugPrint('map: 네이버 초기화 실패, 브이월드 사용 (${error.runtimeType})');
    }
  }
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
  late bool _legalAccepted;
  @override
  void initState() {
    super.initState();
    _legalAccepted =
        widget.services.store.preferences.getString(legalConsentKey) ==
        legalVersion;
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
  );

  void _sessionChanged() {
    if (!mounted) return;
    if (widget.services.store.session == null) {
      _carRoomVisible = false;
      _navigator.currentState?.popUntil((route) => route.isFirst);
    }
    setState(() {});
  }

  void _openRoom(String code) {
    if (_cover ||
        !_legalAccepted ||
        widget.services.store.session == null ||
        _roomVisible ||
        !mounted)
      return;
    if (widget.services.rooms.state.code != code) return;
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
      }
    });
  }

  void _acceptLegal() {
    setState(() => _legalAccepted = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = widget.services.calls.pendingOpenRoom;
      if (mounted && pending != null) _openRoom(pending);
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
            : !_legalAccepted
            ? LegalConsentScreen(
                key: ValueKey(widget.services.store.token),
                services: widget.services,
                mode: widget.mode,
                onAccepted: _acceptLegal,
              )
            : widget.mode == DeviceMode.car
            ? CarDashboard(
                services: widget.services,
                showRoom: _carRoomVisible,
                onRoom: _openRoom,
              )
            : _PhoneTabs(
                services: widget.services,
                mode: widget.mode,
                onRoom: _openRoom,
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
  });
  final AppServices services;
  final DeviceMode mode;
  final ValueChanged<String> onRoom;
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
