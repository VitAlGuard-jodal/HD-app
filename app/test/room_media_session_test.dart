import 'dart:async';

// Already supplied by flutter_test; no additional package dependency.
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_ranker.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_restore.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/call/mesh_coordinator.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('기동 복귀: me의 방을 join 없이 열고 hello 뒤 통화와 화면 이동을 요청한다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.api.currentRoom = const Room('ABC123', '이전 방');
      _microtasksOnly(clock, f.restore());
      expect(f.store.displayName, '새 이름');
      expect(f.session.state.code, 'ABC123');
      expect(f.session.state.members.length, 2);
      expect(f.api.joins, 0);
      expect(f.calls.starts, 0);
      expect(f.restoredRooms, isEmpty);
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.session.state.isConnected, isTrue);
      expect(f.calls.starts, 1);
      expect(f.media.joins, 1);
      expect(f.restoredRooms, ['ABC123']);
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.restoredRooms, ['ABC123']);
      expect(f.media.joins, 1);
      _microtasksOnly(clock, f.session.leave());
      expect(clock.pendingTimers, isEmpty);
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('기동 복귀: me의 방이 없으면 세션·통화·화면을 열지 않는다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      _microtasksOnly(clock, f.restore());
      expect(f.session.state.code, isNull);
      expect(f.api.roomReads, 0);
      expect(f.api.subscriptions, 0);
      expect(f.calls.starts, 0);
      expect(f.media.joins, 0);
      expect(f.restoredRooms, isEmpty);
      _microtasksOnly(clock, f.dispose());
    });
  });

  for (final status in [403, 404]) {
    test('기동 복귀: 방 조회 $status는 상태를 비우고 목록 화면을 유지한다', () {
      fakeAsync((clock) {
        final f = _microtasksOnly(clock, _Fixture.create());
        f.api.currentRoom = const Room('ABC123', null);
        f.api.roomError = ApiException(status, 'gone', '접근할 수 없음');
        _microtasksOnly(clock, f.restore());
        expect(f.session.state.code, isNull);
        expect(f.session.state.error, isNull);
        expect(f.api.subscriptions, 0);
        expect(f.api.joins, 0);
        expect(f.calls.starts, 0);
        expect(f.restoredRooms, isEmpty);
        expect(f.store.token, 'test');
        expect(clock.pendingTimers, isEmpty);
        _microtasksOnly(clock, f.dispose());
      });
    });

    test('기동 복귀: 조회 뒤 SSE $status도 조용히 정리하고 화면을 열지 않는다', () {
      fakeAsync((clock) {
        final f = _microtasksOnly(clock, _Fixture.create());
        f.api.currentRoom = const Room('ABC123', null);
        _microtasksOnly(clock, f.restore());
        f.api.events.addError(ApiException(status, 'gone', '접근할 수 없음'));
        clock.flushMicrotasks();
        expect(f.session.state.code, isNull);
        expect(f.session.state.error, isNull);
        expect(f.calls.starts, 0);
        expect(f.restoredRooms, isEmpty);
        expect(f.store.token, 'test');
        expect(clock.pendingTimers, isEmpty);
        _microtasksOnly(clock, f.dispose());
      });
    });
  }

  test('기동 복귀: 방 연결 네트워크 오류는 세션을 유지하고 hello 후 복귀한다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.api.currentRoom = const Room('ABC123', null);
      f.api.roomError = TimeoutException('offline');
      _microtasksOnly(clock, f.restore());
      f.api.events.add(const Disconnected('연결을 다시 시도합니다.', 2000));
      clock.flushMicrotasks();
      expect(f.store.token, 'test');
      expect(f.session.state.code, 'ABC123');
      expect(f.session.state.error, isNotNull);
      expect(f.restoredRooms, isEmpty);
      expect(f.calls.starts, 0);
      f.api.roomError = null;
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.restoredRooms, ['ABC123']);
      expect(f.calls.starts, 1);
      _microtasksOnly(clock, f.session.leave());
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('기동 복귀: me 네트워크 오류는 저장된 로그인 정보를 유지한다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.api.meError = TimeoutException('offline');
      _microtasksOnly(clock, f.restore());
      expect(f.store.token, 'test');
      expect(f.session.state.code, isNull);
      expect(f.restoredRooms, isEmpty);
      _microtasksOnly(clock, f.dispose());
    });
  });

  for (final stage in ['me', 'room', 'events']) {
    test('기동 복귀: $stage 401은 기존 로그아웃 경로를 유지한다', () {
      fakeAsync((clock) {
        final f = _microtasksOnly(clock, _Fixture.create());
        f.api.currentRoom = const Room('ABC123', null);
        const error = ApiException(401, 'expired', '토큰 만료');
        if (stage == 'me') f.api.meError = error;
        if (stage == 'room') f.api.roomError = error;
        _microtasksOnly(clock, f.restore());
        if (stage == 'events') {
          f.api.events.addError(error);
          clock.flushMicrotasks();
        }
        expect(f.store.token, isNull);
        expect(f.session.state.code, isNull);
        expect(f.restoredRooms, isEmpty);
        expect(clock.pendingTimers, isEmpty);
        _microtasksOnly(clock, f.dispose());
      });
    });
  }

  test('기동 복귀: me 응답 전 다른 방이 열렸으면 그 세션을 덮어쓰지 않는다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.api.pendingMe = Completer<MeResult>();
      final restoring = f.restore();
      _microtasksOnly(clock, f.session.open('OTHER1'));
      final reads = f.api.roomReads;
      f.api.pendingMe!.complete(
        const MeResult(User('alice', '새 이름'), Room('ABC123', null)),
      );
      _microtasksOnly(clock, restoring);
      expect(f.session.state.code, 'OTHER1');
      expect(f.api.roomReads, reads);
      expect(f.api.subscriptions, 1);
      expect(f.restoredRooms, isEmpty);
      _microtasksOnly(clock, f.session.leave());
      _microtasksOnly(clock, f.dispose());
    });
  });

  for (final status in [401, 403, 404]) {
    test('기동 복귀: hello 뒤 통화 직전 조회 $status도 방과 재시도를 정리한다', () {
      fakeAsync((clock) {
        final f = _microtasksOnly(clock, _Fixture.create());
        f.api.currentRoom = const Room('ABC123', null);
        _microtasksOnly(clock, f.restore());
        f.api.roomError = ApiException(status, 'gone', '접근할 수 없음');
        f.api.events.add(Hello('alice', f.api.members));
        clock.flushMicrotasks();
        expect(f.session.state.code, isNull);
        expect(f.session.state.error, isNull);
        expect(f.calls.starts, 0);
        expect(f.media.joins, 0);
        // 준비 콜백은 hello 시점에 보고된다. 화면 전환은 main.dart 가 state 로 막는다.
        expect(f.restoredRooms, ['ABC123']);
        expect(f.store.token, status == 401 ? null : 'test');
        expect(clock.pendingTimers, isEmpty);
        _microtasksOnly(clock, f.dispose());
      });
    });
  }

  test('기동 복귀: me 응답 전 로그아웃하면 오래된 응답을 버린다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.api.pendingMe = Completer<MeResult>();
      final restoring = f.restore();
      _microtasksOnly(clock, f.store.clear());
      f.api.pendingMe!.complete(
        const MeResult(User('alice', '새 이름'), Room('ABC123', null)),
      );
      _microtasksOnly(clock, restoring);
      expect(f.store.token, isNull);
      expect(f.session.state.code, isNull);
      expect(f.api.subscriptions, 0);
      expect(f.restoredRooms, isEmpty);
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('open 성공 → hello 후 통화 자동 시작, 음소거·나가기 순서', () async {
    final f = await _Fixture.create();
    await f.open();
    expect(f.media.members, ['alice', 'bob']);
    expect(f.order, [
      'preview-stop',
      'native-start',
      'media-start',
      'speaker:true',
    ]);
    expect(f.session.mediaConnection, MediaConnectionState.connected);
    await f.session.joinCall();
    expect(f.media.joins, 1);
    f.media.remoteSpeaking?.call('bob', true);
    expect(f.session.speaking, {'bob'});
    f.session.setMuted(true);
    expect(f.media.muted, isTrue);
    expect(f.calls.muted, isTrue);
    f.api.members = const [Member('alice', 'Alice', '1')];
    f.api.events.add(const MemberLeft('bob'));
    await Future<void>.delayed(Duration.zero);
    expect(f.media.members, ['alice']);
    expect(f.session.speaking, isEmpty);
    await f.calls.onLeaveCall!();
    expect(f.order.sublist(f.order.length - 3), [
      'media-stop',
      'native-stop',
      'room-leave',
    ]);
    expect(f.session.state.code, isNull);
    await f.dispose();
  });

  test('5명째는 joinCall 안 함, 자리가 나면 자동 입장', () async {
    final f = await _Fixture.create(handle: 'aaron');
    f.api.members = [
      for (final name in ['alice', 'bob', 'charlie', 'david', 'aaron'])
        Member(name, name, ''),
    ];
    await f.open();
    expect(f.session.callJoinBlockedReason, meshCapacityReason);
    expect(f.media.joins, 0);
    expect(f.calls.starts, 0);
    f.api.members.removeAt(0);
    f.api.events.add(const MemberLeft('alice'));
    await Future<void>.delayed(Duration.zero);
    expect(f.media.joins, 1);
    expect(f.calls.starts, 1);
    await f.dispose();
  });

  test('실패 → 1s·2s·4s 재시도 3회 후 중단, FGS는 나갈 때 종료', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.media.failJoin = true;
      _microtasksOnly(clock, f.session.open('ABC123'));
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.media.joins, 1);
      clock.elapse(const Duration(milliseconds: 999));
      expect(f.media.joins, 1);
      clock.elapse(const Duration(milliseconds: 1));
      expect(f.media.joins, 2);
      clock.elapse(const Duration(seconds: 2));
      expect(f.media.joins, 3);
      clock.elapse(const Duration(seconds: 4));
      expect(f.media.joins, 4);
      expect(f.session.retryAttempts, 3);
      expect(f.session.canReconnect, isTrue);
      expect(f.session.mediaError, 'capture unavailable');
      clock.elapse(const Duration(seconds: 30));
      expect(f.media.joins, 4);
      expect(f.calls.starts, 1);
      expect(f.calls.stops, 0);
      f.media.failJoin = false;
      _microtasksOnly(clock, f.session.reconnect());
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      _microtasksOnly(clock, f.session.leave());
      expect(f.calls.stops, 1);
      expect(f.order.sublist(f.order.length - 3), [
        'media-stop',
        'native-stop',
        'room-leave',
      ]);
      expect(f.session.state.code, isNull);
      expect(clock.pendingTimers, isEmpty);
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('방 나가기는 예약된 자동 재시도를 취소한다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.media.failJoin = true;
      _microtasksOnly(clock, f.session.open('ABC123'));
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 1);
      _microtasksOnly(clock, f.session.leave());
      expect(f.calls.stops, 1);
      expect(clock.pendingTimers, isEmpty);
      clock.elapse(const Duration(seconds: 8));
      expect(f.media.joins, 1);
      expect(f.session.state.code, isNull);
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('SSE open(force)와 hello 반복은 기존 미디어·음소거를 보존한다', () async {
    final f = await _Fixture.create();
    await f.open();
    f.session.setMuted(true);
    await f.session.open('ABC123', force: true);
    f.api.events.add(Hello('alice', f.api.members));
    await Future<void>.delayed(Duration.zero);
    expect(f.media.joins, 1);
    expect(f.media.leaves, 0);
    expect(f.session.muted, isTrue);
    expect(f.session.state.isConnected, isTrue);
    await f.dispose();
  });

  test('피어 실패 상태는 전달하되 정상 통화와 FGS를 다시 시작하지 않는다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      _microtasksOnly(clock, f.session.open('ABC123'));
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      var notifications = 0;
      f.session.addListener(() => notifications++);
      f.media.changePeers({
        'bob': MeshPeerState.connected,
        'charlie': MeshPeerState.failed,
      });
      expect(f.session.peerStates['charlie'], MeshPeerState.failed);
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      expect(notifications, greaterThan(0));
      clock.elapse(const Duration(seconds: 30));
      expect(f.media.joins, 1);
      expect(f.media.leaves, 0);
      expect(f.calls.starts, 1);
      expect(f.session.retryAttempts, 0);
      expect(clock.pendingTimers, isEmpty);
      _microtasksOnly(clock, f.session.leave());
      expect(f.session.peerStates, isEmpty);
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('권한 거부는 재요청 루프 없이 iOS 설정 경로를 알린다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final f = await _Fixture.create();
    f.mic.permissions = const AudioPermissions();
    await f.open();
    expect(f.session.permissionDenied, isTrue);
    expect(f.session.mediaError, contains('설정 > 우나보 > 마이크'));
    expect(f.session.retryAttempts, 0);
    expect(f.media.joins, 0);
    expect(f.calls.starts, 0);
    await f.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('저장된 음량 적용, 음량 변경 저장, 인터럽션 후 음소거 보존', () async {
    final f = await _Fixture.create(volume: 35);
    await f.open();
    expect(f.media.volume, .35);
    await f.session.setCallVolume(62);
    expect(f.media.volume, .62);
    expect(f.store.preferences.getInt('callVolume'), 62);
    f.session.setMuted(true);
    f.mic.audioInterrupted = true;
    f.mic.changed();
    expect(f.media.interrupted, isTrue);
    f.mic.audioInterrupted = false;
    f.mic.changed();
    expect(f.media.interrupted, isFalse);
    expect(f.media.muted, isTrue);
    expect(f.media.joins, 1);
    await f.dispose();
  });

  test('차량 음량 UI가 꺼져 있으면 시스템 음량은 수신 이득·저장값과 분리된다', () async {
    final f = await _Fixture.create(volume: 100);
    f.mic.state = const MicState(mode: MicMode.car);
    f.mic.systemCallVolume = 60;
    await f.open();
    expect(f.session.callVolume, 100);
    f.mic.systemCallVolume = 40;
    f.mic.changed();
    await Future<void>.delayed(Duration.zero);
    expect(f.session.callVolume, 100);
    expect(f.media.volume, 1);
    f.mic.systemVolumeWritable = false;
    await f.session.setCallVolume(25);
    expect(f.session.callVolume, 25);
    expect(f.media.volume, .25);
    expect(f.store.callVolume, 25);
    expect(f.mic.systemVolumeWrites, 0);
    await f.dispose();
  });
}

/// A timer-dependent or incomplete Future fails an assertion instead of
/// suspending the test body. In particular, leave must finish at the same time.
T _microtasksOnly<T>(FakeAsync clock, Future<T> future) {
  final elapsed = clock.elapsed;
  var completed = false;
  late T value;
  unawaited(
    future.then((result) {
      value = result;
      completed = true;
    }),
  );
  clock.flushMicrotasks();
  expect(completed, isTrue, reason: 'Future must finish using only microtasks');
  expect(clock.elapsed, elapsed);
  return value;
}

class _Fixture {
  _Fixture(this.store) {
    api = _Api(store, order);
    mic = _Mic(store, order);
    calls = _Calls(order);
    media = _Media(order);
    session = RoomSession(
      api: api,
      mediaEngine: media,
      store: store,
      callService: calls,
      micRouter: mic,
    );
  }
  static Future<_Fixture> create({
    String handle = 'alice',
    int volume = 100,
  }) async {
    SharedPreferences.setMockInitialValues({
      'token': 'test',
      'handle': handle,
      'callVolume': volume,
    });
    return _Fixture(SessionStore(await SharedPreferences.getInstance()));
  }

  final SessionStore store;
  final order = <String>[];
  final restoredRooms = <String>[];
  late final _Api api;
  late final _Mic mic;
  late final _Calls calls;
  late final _Media media;
  late final RoomSession session;
  Future<void> restore() => restoreSession(
    api: api,
    store: store,
    rooms: session,
    isCurrent: () => true,
    onRoomRestored: restoredRooms.add,
  );
  Future<void> open() async {
    await session.open('ABC123');
    api.events.add(Hello(store.handle!, api.members));
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> dispose() async {
    session.dispose();
    await api.close();
    calls.dispose();
    mic.dispose();
    store.dispose();
  }
}

class _Api extends ApiClient {
  _Api(SessionStore store, this.order) : super(tokenStore: store);
  final List<String> order;
  final _eventStreams = <StreamController<RoomEvent>>[];
  StreamController<RoomEvent> get events => _eventStreams.last;
  Future<void> close() async {
    for (final stream in _eventStreams) {
      await stream.close();
    }
  }

  List<Member> members = const [
    Member('alice', 'Alice', '1'),
    Member('bob', 'Bob', '2'),
  ];
  Room? currentRoom;
  Object? meError, roomError;
  Completer<MeResult>? pendingMe;
  int roomReads = 0, subscriptions = 0, joins = 0;
  @override
  Future<MeResult> me() async {
    if (meError != null) throw meError!;
    if (pendingMe != null) return pendingMe!.future;
    return MeResult(const User('alice', '새 이름'), currentRoom);
  }

  @override
  Future<Room> joinRoom(String code) async {
    joins++;
    return Room(code, null);
  }

  @override
  Future<RoomDetails> getRoom(String code) async {
    roomReads++;
    if (roomError != null) throw roomError!;
    return RoomDetails(Room(code, null), members);
  }

  @override
  Stream<RoomEvent> subscribeEvents(String code) {
    subscriptions++;
    // SSE has one subscription per request. A broadcast controller's cancel
    // returns Dart's cached root-zone nullFuture; awaiting it escapes FakeAsync
    // and strands the next media.leave continuation in the fake microtask queue.
    _eventStreams.add(StreamController<RoomEvent>(onCancel: () async {}));
    // Allocate done in this zone before cancellation, for deterministic cleanup.
    unawaited(events.done);
    return events.stream;
  }

  @override
  Future<void> leaveRoom(String code) async {
    order.add('room-leave');
  }
}

class _Mic extends MicRouter {
  _Mic(super.store, this.order) {
    permissions = const AudioPermissions(microphone: true);
  }
  final List<String> order;
  int systemVolumeWrites = 0;
  void changed() => notifyListeners();
  @override
  Future<void> refreshPermissions() async {}
  @override
  Future<AudioPermissions> requestPermissions() async => permissions;
  @override
  Future<void> stopPreview() async {
    order.add('preview-stop');
  }

  @override
  Future<void> refreshOutputRoute() async {}
  @override
  Future<void> applyOutputRoute() async {
    order.add('speaker:true');
  }

  @override
  Future<void> setSystemCallVolume(int percent) async {
    systemVolumeWrites++;
  }
}

class _Calls extends CallService {
  _Calls(this.order);
  final List<String> order;
  int starts = 0, stops = 0;
  bool muted = false;
  @override
  Future<void> start(String roomCode, String handle) async {
    starts++;
    order.add('native-start');
    state = CallState(roomCode: roomCode, selfHandle: handle, isActive: true);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    order.add('native-stop');
    state = const CallState();
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
  }
}

class _Media extends NoopMediaEngine {
  _Media(this.order);
  final List<String> order;
  List<String> members = [];
  bool failJoin = false, muted = false, interrupted = false;
  int joins = 0, leaves = 0;
  double volume = 1;
  void changePeers(Map<String, MeshPeerState> states) {
    publishPeerStates(states);
    connectionChanged?.call(
      receiveConnectionState(MediaConnectionState.connected, states.values),
      null,
    );
  }

  @override
  Future<void> setMembers(List<String> handles) async {
    members = handles;
  }

  @override
  Future<void> join(String roomCode, String selfHandle) async {
    joins++;
    order.add('media-start');
    if (failJoin) throw StateError('capture unavailable');
    connectionChanged?.call(MediaConnectionState.connected, null);
  }

  @override
  Future<void> leave() async {
    leaves++;
    order.add('media-stop');
    publishPeerStates({});
    connectionChanged?.call(MediaConnectionState.idle, null);
  }

  @override
  void setMuted(bool value) {
    muted = value;
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  void setInterrupted(bool value) {
    interrupted = value;
  }

  @override
  void onRemoteSpeaking(String handle) {}
}
