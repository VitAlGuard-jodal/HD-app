import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';

import 'support/location_fakes.dart';

LocationFix _fix(String handle, int seq) => LocationFix(
  handle: handle,
  lat: 37 + seq / 100000,
  lng: 127,
  speed: 2,
  at: 1000 + seq * 1000,
  seq: seq,
  receivedAt: 1001 + seq * 1000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hello 스냅샷·그룹장 궤적을 초기화하고 중복/역순 위치에는 알리지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open(
        positions: [_fix('alice', 1), _fix('bob', 0)],
        trail: [_fix('alice', 0), _fix('alice', 1), _fix('alice', 1)],
      );
      expect(f.session.leaderHandle, 'alice');
      expect(f.session.positions.keys, unorderedEquals(['alice', 'bob']));
      expect(f.session.leaderTrail.map((fix) => fix.seq), [0, 1]);
      var notifications = 0;
      f.session.addListener(() => notifications++);
      f.event(LocationUpdated(_fix('alice', 2)));
      expect(f.session.positions['alice']?.seq, 2);
      expect(f.session.leaderTrail.map((fix) => fix.seq), [0, 1, 2]);
      expect(notifications, 1);
      f.event(LocationUpdated(_fix('alice', 2)));
      f.event(LocationUpdated(_fix('alice', 1)));
      expect(notifications, 1);
      f.event(LocationUpdated(_fix('bob', 1)));
      expect(f.session.leaderTrail, hasLength(3));
      expect(notifications, 2);
      f.dispose();
    });
  });

  test('재접속 hello는 오래된 위치를 교체하고 궤적은 최신 7200개로 제한한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open(positions: [_fix('bob', 0)]);
      final trail = List.generate(7205, (seq) => _fix('alice', seq));
      f.event(
        Hello('bob', f.api.members, 'alice', [
          trail.last,
        ], LocationTrail('alice', trail)),
      );
      expect(f.session.positions.keys, ['alice']);
      expect(f.session.leaderTrail, hasLength(7200));
      expect(f.session.leaderTrail.first.seq, 5);
      f.event(LocationUpdated(_fix('alice', 7205)));
      expect(f.session.leaderTrail, hasLength(7200));
      expect(f.session.leaderTrail.first.seq, 6);
      expect(f.session.leaderTrail.last.seq, 7205);
      f.event(const LocationStopped('alice'));
      f.event(LocationUpdated(_fix('alice', 0)));
      expect(f.session.leaderTrail.first.seq, 6); // 이미 잘린 seq도 재누적하지 않는다.
      expect(f.session.leaderTrail.last.seq, 7205);
      f.dispose();
    });
  });

  test('location-stopped·member-left는 현재 위치만 지우고 그룹장 궤적은 보존한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open(
        positions: [_fix('alice', 0), _fix('bob', 0)],
        trail: [_fix('alice', 0)],
      );
      var notifications = 0;
      f.session.addListener(() => notifications++);
      f.event(const LocationStopped('alice'));
      expect(f.session.positions.containsKey('alice'), isFalse);
      expect(f.session.leaderTrail, hasLength(1));
      expect(notifications, 1);
      f.event(const LocationStopped('alice'));
      expect(notifications, 1);
      f.api.members = [const Member('alice', '앨리스', '1')];
      f.event(const MemberLeft('bob'));
      expect(f.session.positions, isEmpty);
      expect(f.session.leaderHandle, 'alice');
      expect(f.session.leaderTrail, hasLength(1));
      f.dispose();
    });
  });

  test('차량은 최근 정차 표본이 있을 때만 따라가기를 켜고 끄기는 언제나 허용한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, mode: DeviceMode.car);
      f.open();
      var notifications = 0;
      f.session.addListener(() => notifications++);
      f.session.setFollowLeader(true);
      expect(f.session.followLeader, isFalse);
      expect(f.session.followError, '정차 후 설정할 수 있습니다');
      expect(notifications, 1);
      f.session.setFollowLeader(true);
      expect(notifications, 1);
      f.startSharing();
      for (var second = 0; second <= 3; second++) {
        if (second > 0) clock.elapse(const Duration(seconds: 1));
        f.sample(lat: 37 + second * .001, speed: 3);
      }
      f.session.setFollowLeader(true);
      expect(f.session.followLeader, isFalse);
      for (var second = 0; second < 4; second++) {
        clock.elapse(const Duration(seconds: 1));
        f.sample(lat: 37.003, speed: 0);
      }
      expect(f.session.locationShare.isStationary, isTrue);
      f.session.setFollowLeader(true);
      expect(f.session.followLeader, isTrue);
      expect(f.session.followError, isNull);
      final enabledNotifications = notifications;
      f.session.setFollowLeader(true);
      expect(notifications, enabledNotifications);
      clock.elapse(const Duration(seconds: 1));
      f.sample(lat: 38, speed: 5);
      expect(f.session.locationShare.isStationary, isFalse);
      expect(f.session.followLeader, isTrue); // 이미 켠 따라가기는 이동 중에도 유지한다.
      final movingNotifications = notifications;
      f.session.setFollowLeader(true);
      expect(f.session.followError, isNull);
      expect(notifications, movingNotifications);
      f.session.setFollowLeader(false);
      expect(f.session.followLeader, isFalse);
      expect(f.session.followError, isNull);
      f.dispose();
    });
  });

  test('폰은 정차 제한이 없고 그룹장 자신은 no-op이다', () {
    fakeAsync((clock) {
      final phone = _Fixture.create(clock);
      phone.open();
      phone.session.setFollowLeader(true);
      expect(phone.session.followLeader, isTrue);
      expect(phone.session.followError, isNull);
      phone.dispose();
      final leader = _Fixture.create(
        clock,
        handle: 'alice',
        mode: DeviceMode.car,
      );
      leader.open();
      var notifications = 0;
      leader.session.addListener(() => notifications++);
      leader.session.setFollowLeader(true);
      leader.session.setFollowLeader(false);
      expect(leader.session.followLeader, isFalse);
      expect(leader.session.followError, isNull);
      expect(notifications, 0);
      leader.dispose();
    });
  });

  test('서버가 송신자에게 반사하지 않아도 성공한 내 위치·그룹장 궤적을 반영한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, handle: 'alice');
      f.open();
      f.startSharing();
      f.sample();
      expect(f.session.positions['alice']?.seq, 0);
      expect(f.session.leaderTrail.single.seq, 0);
      clock.elapse(const Duration(seconds: 1));
      f.sample(lat: 37.001);
      expect(f.session.leaderTrail.map((fix) => fix.seq), [0, 1]);
      _finish(clock, f.session.locationShare.stop());
      expect(f.session.positions, isEmpty);
      expect(f.session.leaderTrail, hasLength(2));
      f.dispose();
    });
  });

  for (final action in ['leave', 'forget', 'change']) {
    test('$action는 공유를 자동 중지하고 방의 위치·궤적·따라가기 상태를 초기화한다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.open(positions: [_fix('alice', 0)], trail: [_fix('alice', 0)]);
        f.session.setFollowLeader(true);
        f.startSharing();
        f.sample();
        switch (action) {
          case 'leave':
            _finish(clock, f.session.leave());
          case 'forget':
            _finish(clock, f.session.forget());
          case 'change':
            f.session.state = const RoomState(code: 'NEW123');
            clock.flushMicrotasks();
        }
        expect(f.session.locationShare.sharing, isFalse);
        expect(f.source.cancellations, 1);
        expect(f.http.deletes.single.uri.path, '/v1/rooms/ABC123/location');
        expect(f.session.positions, isEmpty);
        expect(f.session.leaderTrail, isEmpty);
        expect(f.session.leaderHandle, isNull);
        expect(f.session.followLeader, isFalse);
        expect(f.session.followError, isNull);
        expect(f.source.watches, 1);
        if (action == 'leave') expect(f.api.leaves, 1);
        f.dispose();
      });
    });
  }
}

T _finish<T>(FakeAsync clock, Future<T> future) {
  var complete = false;
  late T result;
  unawaited(
    future.then((value) {
      result = value;
      complete = true;
    }),
  );
  clock.flushMicrotasks();
  expect(complete, isTrue, reason: 'Future must finish using only microtasks');
  return result;
}

class _Fixture {
  _Fixture(this.clock, this.store, DeviceMode mode) {
    api = _Api(store, http);
    mic = MicRouter(store);
    session = RoomSession(
      api: api,
      mediaEngine: _Media(),
      store: store,
      callService: calls,
      micRouter: mic,
      deviceMode: mode,
      locationSource: source,
      locationNow: now,
    );
  }
  static _Fixture create(
    FakeAsync clock, {
    String handle = 'bob',
    DeviceMode mode = DeviceMode.phone,
  }) {
    SharedPreferences.setMockInitialValues({'token': 'test', 'handle': handle});
    return _Fixture(
      clock,
      SessionStore(_finish(clock, SharedPreferences.getInstance())),
      mode,
    );
  }

  final FakeAsync clock;
  final SessionStore store;
  final http = FakeLocationHttp();
  final source = FakeLocationSource();
  final calls = _Calls();
  late final _Api api;
  late final MicRouter mic;
  late final RoomSession session;
  DateTime now() => DateTime.utc(2026).add(clock.elapsed);
  void open({
    List<LocationFix> positions = const [],
    List<LocationFix> trail = const [],
  }) {
    _finish(clock, session.open('ABC123'));
    _finish(clock, session.leaveCall()); // 위치 테스트에서는 자동 통화를 시작하지 않는다.
    event(
      Hello(
        store.handle!,
        api.members,
        'alice',
        positions,
        LocationTrail('alice', trail),
      ),
    );
  }

  void event(RoomEvent event) {
    api.events.add(event);
    clock.flushMicrotasks();
  }

  void startSharing() {
    _finish(clock, session.locationShare.consent());
    _finish(clock, session.locationShare.start());
  }

  void sample({double lat = 37, double speed = 2}) {
    source.add(LocationSample(lat: lat, lng: 127, speed: speed, at: now()));
    clock.flushMicrotasks();
  }

  void dispose() {
    _finish(clock, session.locationShare.stop());
    session.dispose();
    _finish(clock, api.close());
    _finish(clock, source.close());
    unawaited(http.events.stream.drain<void>());
    _finish(clock, http.close());
    calls.dispose();
    mic.dispose();
    store.dispose();
    clock.flushMicrotasks();
    expect(clock.pendingTimers, isEmpty);
  }
}

class _Api extends ApiClient {
  _Api(SessionStore store, FakeLocationHttp http)
    : super(tokenStore: store, clientFactory: http.client) {
    unawaited(events.done);
  }
  final events = StreamController<RoomEvent>(onCancel: () async {});
  List<Member> members = const [
    Member('alice', '앨리스', '1'),
    Member('bob', '보비', '2'),
  ];
  int leaves = 0;
  Future<void> close() => events.close();
  @override
  Future<RoomDetails> getRoom(String code) async =>
      RoomDetails(Room(code, null, leader: 'alice'), members);
  @override
  Stream<RoomEvent> subscribeEvents(String code) => events.stream;
  @override
  Future<void> leaveRoom(String code) async {
    leaves++;
  }
}

class _Calls extends CallService {
  @override
  bool get supported => false;
}

class _Media extends NoopMediaEngine {
  @override
  Future<void> leave() async {}
}
