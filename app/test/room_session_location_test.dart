import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';

import 'support/location_fakes.dart';

const _timeout = Timeout(Duration(seconds: 30));

LocationFix _fix(
  String handle,
  int seq, {
  String stream = '0123456789abcdef',
}) => LocationFix(
  handle: handle,
  stream: stream,
  lat: 37 + seq / 100000,
  lng: 127,
  speed: 2,
  at: 1000 + seq * 1000,
  seq: seq,
  receivedAt: 1001 + seq * 1000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('새 stream의 seq 0과 교차 stream 궤적을 받되 같은 stream 중복은 버린다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      final previous = _fix('alice', 100);
      final restarted = _fix('alice', 0, stream: '1111111111111111');
      f.open(positions: [previous], trail: [previous]);
      f.event(LocationUpdated(restarted));
      expect(f.session.positions['alice'], restarted);
      expect(f.session.trailOf('alice'), [previous, restarted]);
      f.event(LocationUpdated(restarted));
      expect(f.session.trailOf('alice'), [previous, restarted]);
      final resumed = _fix('alice', 101);
      f.event(LocationUpdated(resumed));
      expect(f.session.trailOf('alice'), [previous, restarted, resumed]);
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          [resumed],
          {
            'alice': [previous, restarted, resumed, previous],
          },
        ),
      );
      expect(f.session.trailOf('alice'), [previous, restarted, resumed]);
      f.dispose();
    });
  });

  test('hello 스냅샷·그룹장 궤적을 초기화하고 중복/역순 위치에는 알리지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open(
        positions: [_fix('alice', 1), _fix('bob', 0)],
        trail: [_fix('alice', 0), _fix('alice', 1), _fix('alice', 1)],
      );
      expect(f.session.leaderHandle, 'alice');
      expect(f.session.positions.keys, unorderedEquals(['alice', 'bob']));
      expect(f.session.trailOf('alice').map((fix) => fix.seq), [0, 1]);
      var notifications = 0;
      f.session.addListener(() => notifications++);
      f.event(LocationUpdated(_fix('alice', 2)));
      expect(f.session.positions['alice']?.seq, 2);
      expect(f.session.trailOf('alice').map((fix) => fix.seq), [0, 1, 2]);
      expect(notifications, 1);
      f.event(LocationUpdated(_fix('alice', 2)));
      f.event(LocationUpdated(_fix('alice', 1)));
      expect(notifications, 1);
      f.event(LocationUpdated(_fix('bob', 1)));
      expect(f.session.trailOf('alice'), hasLength(3));
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
        Hello('bob', f.api.members, 'alice', [trail.last], {'alice': trail}),
      );
      expect(f.session.positions.keys, ['alice']);
      expect(f.session.trailOf('alice'), hasLength(7200));
      expect(f.session.trailOf('alice').first.seq, 5);
      f.event(LocationUpdated(_fix('alice', 7205)));
      expect(f.session.trailOf('alice'), hasLength(7200));
      expect(f.session.trailOf('alice').first.seq, 6);
      expect(f.session.trailOf('alice').last.seq, 7205);
      f.event(const LocationStopped('alice'));
      f.event(LocationUpdated(_fix('alice', 0)));
      expect(f.session.trailOf('alice').first.seq, 6); // 이미 잘린 seq도 재누적하지 않는다.
      expect(f.session.trailOf('alice').last.seq, 7205);
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
      expect(f.session.trailOf('alice'), hasLength(1));
      expect(notifications, 1);
      f.event(const LocationStopped('alice'));
      expect(notifications, 1);
      f.api.members = [const Member('alice', '앨리스', '1')];
      f.event(const MemberLeft('bob'));
      expect(f.session.positions, isEmpty);
      expect(f.session.leaderHandle, 'alice');
      expect(f.session.trailOf('alice'), hasLength(1));
      f.dispose();
    });
  });

  test('차량은 표본 없는 unknown에서 동의 확인과 공유 시작 후 follow를 허용한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, mode: DeviceMode.car);
      f.open();
      expect(f.session.locationShare.motionState, LocationMotionState.unknown);
      expect(f.session.followNeedsStop, isFalse);
      expect(f.session.checkFollowAllowed('alice'), isTrue);
      expect(f.source.requests, 0);
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.session.followTarget, isNull); // 공유 동의 전에는 POST하지 않는다.
      expect(f.session.followError, isNull);
      expect(f.api.follows, isEmpty);
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.source.watches, 1);
      expect(f.session.locationShare.motionState, LocationMotionState.unknown);
      expect(f.api.follows, ['alice']);
      expect(f.session.followTarget, 'alice');
      expect(f.session.followError, isNull);
      f.dispose();
    });
  }, timeout: _timeout);

  test('차량은 moving만 차단하고 stationary에서 시작한 따라가기와 중지는 허용한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, mode: DeviceMode.car);
      f.open();
      f.startSharing();
      f.sample(speed: .5);
      expect(f.session.locationShare.motionState, LocationMotionState.moving);
      expect(f.session.followNeedsStop, isTrue);
      var notifications = 0;
      f.session.addListener(() => notifications++);
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.session.followTarget, isNull);
      expect(f.session.followError, '정차 후 설정할 수 있습니다');
      expect(f.api.follows, isEmpty);
      expect(notifications, 1);
      _finish(clock, f.session.startFollowing('alice'));
      expect(notifications, 1);
      for (var second = 0; second <= 3; second++) {
        if (second > 0) clock.elapse(const Duration(seconds: 1));
        f.sample(lat: 37 + second * .001, speed: 3);
      }
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.session.followTarget, isNull);
      for (var second = 0; second < 4; second++) {
        clock.elapse(const Duration(seconds: 1));
        f.sample(lat: 37.003, speed: 0);
      }
      expect(f.session.locationShare.isStationary, isTrue);
      expect(f.session.followNeedsStop, isFalse);
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.session.followTarget, 'alice');
      expect(f.session.followError, isNull);
      final enabledNotifications = notifications;
      _finish(clock, f.session.startFollowing('alice'));
      expect(notifications, enabledNotifications);
      clock.elapse(const Duration(seconds: 1));
      f.sample(lat: 38, speed: 5);
      expect(f.session.locationShare.isStationary, isFalse);
      expect(f.session.followTarget, 'alice'); // 이미 켠 따라가기는 이동 중에도 유지한다.
      final movingNotifications = notifications;
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.session.followError, isNull);
      expect(notifications, movingNotifications);
      _finish(clock, f.session.stopFollowing());
      expect(f.session.followTarget, isNull);
      expect(f.session.followError, isNull);
      f.dispose();
    });
  }, timeout: _timeout);

  test('동의 후 start가 돌려주기 전에 moving이면 followTarget과 POST를 거부한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, mode: DeviceMode.car);
      f.open();
      expect(f.session.checkFollowAllowed('alice'), isTrue);
      f.source.initialSample = LocationSample(
        lat: 37,
        lng: 127,
        speed: .5,
        at: f.now(),
      );
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.session.followTarget, isNull);
      expect(f.session.followError, '정차 후 설정할 수 있습니다');
      expect(f.api.follows, isEmpty);
      expect(f.session.locationShare.sharing, isTrue);
      expect(f.source.cancellations, 0);
      f.dispose();
    });
  }, timeout: _timeout);

  for (final pendingPost in [false, true]) {
    test(
      'unknown 따라가기의 첫 moving 판정은 공유를 유지하고 follow를 정리한다 (POST 대기 $pendingPost)',
      () {
        fakeAsync((clock) {
          final f = _Fixture.create(clock, mode: DeviceMode.car);
          f.open();
          f.startSharing();
          final gate = Completer<void>();
          if (pendingPost) f.api.followGate = gate.future;
          final following = f.session.startFollowing('alice');
          clock.flushMicrotasks();
          expect(f.api.follows, ['alice']);
          expect(f.session.followTarget, 'alice');
          final locationGate = Completer<void>();
          f.http.sendGate = locationGate.future;
          f.sample(speed: .5);
          expect(f.session.locationShare.lastSent, isNull);
          expect(f.session.followTarget, isNull);
          expect(f.session.followError, '정차 후 설정할 수 있습니다');
          expect(f.session.locationShare.sharing, isTrue);
          expect(f.source.cancellations, 0);
          expect(f.http.deletes, isEmpty);
          expect(f.api.unfollows, pendingPost ? 0 : 1);
          gate.complete();
          _finish(clock, following);
          expect(f.api.unfollows, 1);
          f.event(const FollowResponse('alice', true));
          expect(f.session.followTarget, isNull);
          f.sample(speed: 2);
          expect(f.api.unfollows, 1); // 최초 판정 때 한 번만 취소한다.
          locationGate.complete();
          clock.flushMicrotasks();
          f.dispose();
        });
      },
      timeout: _timeout,
    );
  }

  test('같은 대상의 hello를 받아도 unknown 따라가기의 첫 이동 검사는 유지한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, mode: DeviceMode.car);
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      f.event(
        Hello('bob', f.api.members, 'alice', const [], const {}, 'alice'),
      );
      f.sample(speed: .5);
      expect(f.session.followTarget, isNull);
      expect(f.session.followError, '정차 후 설정할 수 있습니다');
      expect(f.session.locationShare.sharing, isTrue);
      expect(f.api.unfollows, 1);
      f.dispose();
    });
  }, timeout: _timeout);

  test('unknown에서 시작해 첫 stationary 판정을 마치면 이후 이동 중에도 따라간다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, mode: DeviceMode.car);
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      for (var second = 0; second <= 3; second++) {
        if (second > 0) clock.elapse(const Duration(seconds: 1));
        f.sample(speed: 0);
        expect(f.session.followTarget, 'alice');
      }
      expect(
        f.session.locationShare.motionState,
        LocationMotionState.stationary,
      );
      f.sample(speed: 3);
      expect(f.session.locationShare.motionState, LocationMotionState.moving);
      expect(f.session.followTarget, 'alice');
      expect(f.session.followError, isNull);
      expect(f.api.unfollows, 0);
      f.dispose();
    });
  }, timeout: _timeout);

  test('폰은 정차 제한이 없고 그룹장 자신은 no-op이다', () {
    fakeAsync((clock) {
      final phone = _Fixture.create(clock);
      phone.open();
      phone.startSharing();
      _finish(clock, phone.session.startFollowing('alice'));
      expect(phone.session.followTarget, 'alice');
      expect(phone.session.followError, isNull);
      phone.sample(speed: 3);
      expect(phone.session.followTarget, 'alice');
      expect(phone.session.followNeedsStop, isFalse);
      _finish(clock, phone.session.stopFollowing());
      _finish(clock, phone.session.startFollowing('alice'));
      expect(phone.session.followTarget, 'alice');
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
      _finish(clock, leader.session.startFollowing('alice'));
      _finish(clock, leader.session.stopFollowing());
      expect(leader.session.followTarget, isNull);
      expect(leader.session.followError, isNull);
      expect(notifications, 0);
      leader.dispose();
    });
  }, timeout: _timeout);

  test('서버가 송신자에게 반사하지 않아도 성공한 내 위치·그룹장 궤적을 반영한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, handle: 'alice');
      f.open();
      f.startSharing();
      f.sample();
      expect(f.session.positions['alice']?.seq, 0);
      expect(f.session.trailOf('alice').single.seq, 0);
      clock.elapse(const Duration(seconds: 1));
      f.sample(lat: 37.001);
      expect(f.session.trailOf('alice').map((fix) => fix.seq), [0, 1]);
      _finish(clock, f.session.locationShare.stop());
      expect(f.session.positions, isEmpty);
      expect(f.session.trailOf('alice'), hasLength(2));
      f.dispose();
    });
  });

  test('방장도 다른 참여자를 따르며 대상 변경·거절·마지막 팔로워 궤적 삭제를 반영한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, handle: 'alice');
      f.api.members = [...f.api.members, const Member('charlie', '찰리', '3')];
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('bob'));
      expect(f.session.followTarget, 'bob');
      expect(f.api.follows, ['bob']);
      f.event(
        TrailsUpdated({
          'bob': [_fix('bob', 0)],
          'charlie': [_fix('charlie', 0)],
        }),
      );
      f.event(LocationUpdated(_fix('bob', 1)));
      expect(f.session.trailOf('bob').map((fix) => fix.seq), [0, 1]);
      expect(f.session.trailOf('charlie').map((fix) => fix.seq), [0]);
      _finish(clock, f.session.startFollowing('charlie'));
      f.event(const FollowResponse('bob', false)); // 이전 대상의 늦은 응답
      expect(f.session.followTarget, 'charlie');
      f.event(const FollowResponse('charlie', false));
      expect(f.session.followTarget, isNull);
      expect(f.session.takeFollowNotice()?.target, 'charlie');
      expect(f.session.locationShare.sharing, isTrue);
      f.event(const TrailsUpdated({}));
      expect(f.session.trailOf('bob'), isEmpty);
      expect(f.session.trailOf('charlie'), isEmpty);
      f.dispose();
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('진행 중 follow POST 뒤 중지는 DELETE로 정리하고 늦은 수락으로 되살리지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.startSharing();
      final gate = Completer<void>();
      f.api.followGate = gate.future;
      final pending = f.session.startFollowing('alice');
      clock.flushMicrotasks();
      final stopping = f.session.stopFollowing();
      clock.flushMicrotasks();
      expect(f.session.followTarget, isNull);
      expect(f.api.unfollows, 0);
      gate.complete();
      _finish(clock, pending);
      _finish(clock, stopping);
      expect(f.api.unfollows, 1);
      f.event(const FollowResponse('alice', true));
      expect(f.session.followTarget, isNull);
      f.dispose();
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final action in ['leave', 'forget', 'change']) {
    test('$action는 공유를 자동 중지하고 방의 위치·궤적·따라가기 상태를 초기화한다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.open(positions: [_fix('alice', 0)], trail: [_fix('alice', 0)]);
        f.startSharing();
        _finish(clock, f.session.startFollowing('alice'));
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
        expect(f.session.trailOf('alice'), isEmpty);
        expect(f.session.leaderHandle, isNull);
        expect(f.session.followTarget, isNull);
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
      Hello(store.handle!, api.members, 'alice', positions, {'alice': trail}),
    );
  }

  void event(RoomEvent event) {
    api.events.add(event);
    clock.flushMicrotasks();
  }

  void startSharing() {
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
  final follows = <String>[];
  Future<void>? followGate;
  int unfollows = 0;
  @override
  Future<void> follow(String code, String target) async {
    follows.add(target);
    await followGate;
  }

  @override
  Future<void> stopFollowing(String code) async {
    unfollows++;
  }

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
