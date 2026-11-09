import '../net/api_client.dart';
import '../net/models.dart';
import '../room/room_session.dart';
import 'session_store.dart';

/// Cold startup refreshes identity and offers a room card. Opening the room,
/// subscribing to SSE and starting the microphone require an explicit action.
Future<void> restoreSession({
  required ApiClient api,
  required SessionStore store,
  required RoomSession rooms,
  required bool Function() isCurrent,
}) async {
  final token = store.token;
  if (token == null) return;
  final baseUrl = store.baseUrl;
  bool current() =>
      isCurrent() && token == store.token && baseUrl == store.baseUrl;
  try {
    final me = await api.me();
    if (!current()) return;
    await store.save(AuthResult(me.user, token));
    if (!current() || rooms.state.code != null) return;
    rooms.setRestorableRoom(me.room);
  } on ApiException catch (error) {
    if (current() && error.status == 401) {
      await rooms.forget();
      if (current()) await store.clear();
    }
  } catch (_) {
    // Offline startup keeps the stored login and any room for screen retries.
  }
}
