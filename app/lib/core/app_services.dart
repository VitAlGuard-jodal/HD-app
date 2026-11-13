import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/mic_router.dart';
import '../auth/session_store.dart';
import '../call/call_service.dart';
import '../call/media_engine.dart';
import '../call/webrtc_media_engine.dart';
import '../location/location_share.dart';
import '../location/geolocator_location_source.dart';
import '../location/location_source.dart';
import '../location/vehicle_location_source.dart';
import '../map/map_provider.dart';
import '../net/api_client.dart';
import '../room/room_session.dart';
import 'device_mode.dart';
import 'driving_state.dart';
import 'vehicle_state.dart';

class AppServices {
  AppServices(
    this.store, {
    MediaEngine? mediaEngine,
    LocationSource? locationSource,
    DeviceMode? deviceMode,
    MapProvider? mapProvider,
  }) : mapProvider = mapProvider ?? mapProviderFromEnvironment(),
       locationSource =
           locationSource ??
           VehicleLocationSource(
             mode: deviceMode ?? DeviceMode.phone,
             fallback: GeolocatorLocationSource(),
           ) {
    api = ApiClient(tokenStore: store);
    mic = MicRouter(store);
    calls = CallService();
    driving = DrivingState(mode: deviceMode ?? DeviceMode.phone);
    rooms = RoomSession(
      api: api,
      mediaEngine:
          mediaEngine ??
          (calls.supported
              ? WebRtcMediaEngine(api: api, micRouter: mic)
              : NoopMediaEngine()),
      store: store,
      callService: calls,
      micRouter: mic,
      locationSource: this.locationSource,
      deviceMode: deviceMode,
      driving: driving,
      vehicle: VehicleState(mode: deviceMode ?? DeviceMode.phone),
    );
  }
  final SessionStore store;
  // 초기화 실패 시 runApp 전에만 브이월드로 내린다.
  MapProvider mapProvider;
  final mapAuthError = ValueNotifier<String?>(null);
  bool _disposed = false;
  final LocationSource? locationSource;
  LocationShare get locationShare => rooms.locationShare;
  late final ApiClient api;
  late final MicRouter mic;
  late final CallService calls;
  late final DrivingState driving;
  late final RoomSession rooms;

  void setMapAuthError(String code) {
    if (!_disposed && mapProvider == MapProvider.naver) {
      mapAuthError.value = code;
    }
  }

  Future<void> initialize() async {
    await mic.initialize();
    await calls.initialize();
    // A surviving native service is not consent to restart capture in a new
    // Dart process. /v1/me will expose membership as an explicit-entry card.
    if (calls.state.roomCode != null ||
        calls.state.isActive ||
        calls.state.isStarting) {
      await calls.stop();
    }
    calls.pendingOpenRoom = null;
  }

  Future<void> logout() async {
    // 서버 주소 변경도 이 순서를 따른다. 실패 시 주소·세션을 유지하고,
    // 성공 시 기존 주소·토큰으로 방과 공유를 정리한 뒤 세션을 비운다.
    await api.logout();
    await rooms.forget();
    await store.clear();
    api.close();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    mapAuthError.dispose();
    driving.dispose();
    unawaited(
      rooms.shutdown().whenComplete(api.close).catchError((Object error) {
        debugPrint('앱 종료 정리 실패: ${error.runtimeType}');
      }),
    );
    calls.dispose();
    mic.dispose();
    store.dispose();
  }
}
