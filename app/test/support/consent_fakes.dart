import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/app_services.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/map/map_provider.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';

import 'location_fakes.dart';

// 메모리 응답의 완료와 root-zone microtask만 기다린다. 네트워크·타이머 대기 없음.
Future<T> completeConsentFuture<T>(
  WidgetTester tester,
  Future<T> future,
) async {
  var done = false;
  late T value;
  Object? failure;
  StackTrace? stack;
  unawaited(
    future.then<void>(
      (result) {
        value = result;
        done = true;
      },
      onError: (Object error, StackTrace trace) {
        failure = error;
        stack = trace;
        done = true;
      },
    ),
  );
  for (var turn = 0; turn < 8 && !done; turn++) {
    await tester.pump();
    if (!done) await tester.runAsync(() async {});
  }
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  expect(done, isTrue, reason: '메모리 fake의 Future가 완료되어야 합니다.');
  return value;
}

Future<void> pumpConsentUi(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() async {});
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

class ConsentTestServices implements AppServices {
  ConsentTestServices(
    this.store, {
    DeviceMode mode = DeviceMode.phone,
    DateTime Function()? locationNow,
  }) {
    _api = ConsentTestApi(store);
    mic = _Mic(store);
    calls = _Calls();
    rooms = RoomSession(
      api: api,
      mediaEngine: media,
      store: store,
      callService: calls,
      micRouter: mic,
      locationSource: locationSource,
      locationNow: locationNow,
      deviceMode: mode,
    );
  }

  static Future<ConsentTestServices> create(
    WidgetTester tester, {
    bool signedIn = true,
    String? savedVersion,
    DeviceMode mode = DeviceMode.phone,
    String handle = 'bob',
  }) async {
    SharedPreferences.setMockInitialValues({
      if (signedIn) ...{'token': 'test', 'handle': handle},
      if (savedVersion != null)
        'legal.consent.v1': jsonEncode({
          'privacy': {'accepted': true, 'version': savedVersion},
          'location': {'accepted': true, 'version': '1'},
        }),
    });
    final preferences = await completeConsentFuture(
      tester,
      SharedPreferences.getInstance(),
    );
    return ConsentTestServices(
      SessionStore(preferences, defaultBaseUrl: 'https://example.invalid'),
      mode: mode,
      locationNow: tester.binding.clock.now,
    );
  }

  @override
  final SessionStore store;
  @override
  ConsentTestApi get api => _api;
  late final ConsentTestApi _api;
  @override
  late final MicRouter mic;
  @override
  late final CallService calls;
  @override
  late final RoomSession rooms;
  @override
  final FakeLocationSource locationSource = FakeLocationSource();
  @override
  LocationShare get locationShare => rooms.locationShare;
  @override
  MapProvider mapProvider = MapProvider.vworld;
  @override
  final mapAuthError = ValueNotifier<String?>(null);
  final media = _Media();
  int logouts = 0;
  bool _disposed = false;

  @override
  Future<void> logout() async {
    logouts++;
    await api.logout();
    await rooms.forget();
    await store.clear();
  }

  @override
  Future<void> initialize() async {}
  @override
  void setMapAuthError(String code) => mapAuthError.value = code;

  Future<void> openRoom(WidgetTester tester) async {
    await completeConsentFuture(tester, rooms.open('ABC123'));
    await completeConsentFuture(tester, rooms.leaveCall());
    api.events.add(
      Hello(store.handle!, api.members, 'alice', const [
        LocationFix(handle: 'alice', lat: 37, lng: 127, at: 0, seq: 0),
      ]),
    );
    await pumpConsentUi(tester);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    rooms.dispose();
    mapAuthError.dispose();
    calls.dispose();
    mic.dispose();
    store.dispose();
  }

  Future<void> finish(WidgetTester tester) async {
    dispose();
    await completeConsentFuture(tester, media.disposed!);
    await completeConsentFuture(tester, locationShare.stop());
    await completeConsentFuture(tester, locationSource.close());
    await completeConsentFuture(tester, api.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ConsentTestApi extends ApiClient {
  ConsentTestApi(SessionStore store) : super(tokenStore: store) {
    unawaited(events.done);
  }
  final events = StreamController<RoomEvent>.broadcast();
  List<Member> members = const [
    Member('alice', '앨리스', '1'),
    Member('bob', '보비', '2'),
  ];
  int logins = 0, signups = 0, meReads = 0, logouts = 0;
  int stops = 0, sends = 0;
  bool logoutFails = false, stopFails = false;
  final follows = <String>[];
  final followResponses = <(String, bool)>[];
  int unfollows = 0;
  @override
  Future<FollowResult> follow(String code, String target) async {
    follows.add(target);
    return FollowResult('$target-request', ++revision, followAccepted);
  }

  int revision = 0;
  bool followAccepted = true;
  Future<void>? roomGate, locationGate;
  bool roomFails = false;

  @override
  Future<int> respondFollow(
    String code,
    String requester, {
    required bool accepted,
  }) async {
    followResponses.add((requester, accepted));
    return ++revision;
  }

  @override
  Future<int> stopFollowing(String code) async {
    unfollows++;
    return ++revision;
  }

  Future<void> close() => events.close();

  @override
  Future<AuthResult> login(String handle, String password) async {
    logins++;
    return AuthResult(User(handle, '보비'), 'test');
  }

  @override
  Future<AuthResult> signup(
    String handle,
    String password,
    String displayName,
  ) async {
    signups++;
    return AuthResult(User(handle, displayName), 'test');
  }

  @override
  Future<MeResult> me() async {
    meReads++;
    return const MeResult(User('bob', '보비'), null);
  }

  @override
  Future<void> logout() async {
    logouts++;
    if (logoutFails) throw const ApiException(503, 'unavailable', '연결 실패');
  }

  @override
  Future<RoomDetails> getRoom(String code) async {
    await roomGate;
    if (roomFails) throw const ApiException(503, 'unavailable', '참여자 조회 실패');
    return RoomDetails(Room(code, '함께 가는 길', leader: 'alice'), members);
  }

  @override
  Stream<RoomEvent> subscribeEvents(String code) => events.stream;
  @override
  Future<List<User>> listContacts() async => [];
  @override
  Future<bool> sendLocation(String code, LocationFix fix) async {
    sends++;
    await locationGate;
    return false;
  }

  @override
  Future<void> stopLocation(String code) async {
    stops++;
    if (stopFails) throw const ApiException(503, 'unavailable', '삭제 실패');
  }
}

class _Media extends NoopMediaEngine {
  Future<void>? disposed;
  @override
  Future<void> leave() async {}
  @override
  void setMuted(bool muted) {}
  @override
  Future<void> dispose() => disposed ??= super.dispose();
}

class _Mic extends MicRouter {
  _Mic(super.store);
  @override
  Future<void> stopPreview() async {}
}

class _Calls extends CallService {
  @override
  Future<void> stop() async {
    state = const CallState();
    notifyListeners();
  }
}
