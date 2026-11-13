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
  final sessionRevision = store.sessionRevision;
  final consentRevision = store.consentRevision;
  bool current() =>
      isCurrent() &&
      token == store.token &&
      baseUrl == store.baseUrl &&
      sessionRevision == store.sessionRevision;
  try {
    const retryDelays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
    ];
    late MeResult me;
    for (var attempt = 0; ; attempt++) {
      if (!current() ||
          (rooms.state.code != null && (attempt > 0 || store.consentLoaded)))
        return;
      try {
        me = await api.me();
        break;
      } catch (error) {
        if (error is ApiException && error.status == 401) rethrow;
        if (!current() ||
            rooms.state.code != null ||
            attempt == retryDelays.length)
          return;
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
    if (!current()) return;
    await store.save(
      AuthResult(me.user, token),
      consent: me.consent,
      consentLoaded: true,
      // A GET started before an explicit PUT must not undo that newer consent.
      expectedConsentRevision: consentRevision,
    );
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
