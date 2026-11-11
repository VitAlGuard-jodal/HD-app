import '../audio/mic_router.dart';
import '../auth/session_store.dart';
import '../call/call_service.dart';
import '../call/media_engine.dart';
import '../call/webrtc_media_engine.dart';
import '../location/location_share.dart';
import '../location/location_source.dart';
import '../net/api_client.dart';
import '../room/room_session.dart';
import 'device_mode.dart';

class AppServices {
  AppServices(
    this.store, {
    MediaEngine? mediaEngine,
    this.locationSource,
    DeviceMode? deviceMode,
  }) {
    api = ApiClient(tokenStore: store);
    mic = MicRouter(store);
    calls = CallService();
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
      locationSource: locationSource,
      deviceMode: deviceMode,
    );
  }
  final SessionStore store;
  final LocationSource? locationSource;
  LocationShare get locationShare => rooms.locationShare;
  late final ApiClient api;
  late final MicRouter mic;
  late final CallService calls;
  late final RoomSession rooms;

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
    await api.logout();
    await rooms.forget();
    await store.clear();
  }

  void dispose() {
    rooms.dispose();
    calls.dispose();
    mic.dispose();
    store.dispose();
  }
}
