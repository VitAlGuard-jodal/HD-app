import '../audio/mic_router.dart';
import '../auth/session_store.dart';
import '../call/call_service.dart';
import '../call/media_engine.dart';
import '../net/api_client.dart';
import '../room/room_session.dart';

class AppServices {
  AppServices(this.store) {
    api = ApiClient(tokenStore: store);
    mic = MicRouter(store);
    calls = CallService();
    rooms = RoomSession(
      api: api,
      mediaEngine: NoopMediaEngine(),
      store: store,
      callService: calls,
      micRouter: mic,
    );
  }
  final SessionStore store;
  late final ApiClient api;
  late final MicRouter mic;
  late final CallService calls;
  late final RoomSession rooms;

  Future<void> initialize() async {
    await mic.initialize();
    await calls.initialize();
    final code = calls.state.roomCode;
    if (code != null) {
      if (calls.state.selfHandle == store.handle) {
        await rooms.open(code);
      } else {
        await calls.stop();
      }
    }
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
