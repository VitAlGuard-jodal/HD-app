import '../net/api_client.dart';
import '../net/models.dart';
import '../room/room_session.dart';
import 'session_store.dart';

/// Refresh the saved identity and recover membership without joining again.
/// Navigation waits for SSE hello so a revoked membership never opens a screen.
Future<void> restoreSession({
  required ApiClient api,
  required SessionStore store,
  required RoomSession rooms,
  required bool Function() isCurrent,
  required void Function(String code) onRoomRestored,
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
    if (!current() || me.room == null || rooms.state.code != null) return;
    final code = me.room!.code;
    await rooms.open(
      code,
      onReady: () {
        if (current() && rooms.state.code == code) onRoomRestored(code);
      },
    );
  } on ApiException catch (error) {
    if (current() && error.status == 401) {
      await rooms.forget();
      if (current()) await store.clear();
    }
  } catch (_) {
    // Offline startup keeps the stored login and any room for screen retries.
  }
}
