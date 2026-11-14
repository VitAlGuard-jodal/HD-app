import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';

import 'support/location_fakes.dart';

const _fixJson = <String, dynamic>{
  'handle': 'alice',
  'stream': '0123456789abcdef',
  'lat': 37.5,
  'lng': 127,
  'acc': 3,
  'speed': 2,
  'heading': 90,
  'at': 1000,
  'seq': 0,
  'receivedAt': 1001,
};

void main() {
  test(
    'vehicle source round-trips without fabricating accuracy and participates in equality',
    () {
      final json = {..._fixJson}..remove('acc');
      final legacy = LocationFix.fromJson(json);
      final vehicle = LocationFix.fromJson({...json, 'src': 'vehicle'});
      expect(legacy.src, isNull);
      expect(vehicle.src, 'vehicle');
      expect(vehicle.acc, isNull);
      expect(vehicle.toJson()['src'], 'vehicle');
      expect(vehicle.toJson().containsKey('acc'), isFalse);
      expect(vehicle, isNot(legacy));
      expect({legacy, vehicle}, hasLength(2));
      expect(
        LocationFix.fromJson({
          ...vehicle.toJson(),
          'handle': vehicle.handle,
          'receivedAt': vehicle.receivedAt,
        }),
        vehicle,
      );
      for (final src in [
        null,
        'phone',
        'Vehicle',
        'unknown',
        1,
        true,
        <String, Object?>{},
      ]) {
        expect(
          () => LocationFix.fromJson({...json, 'src': src}),
          throwsFormatException,
        );
      }
      for (final acc in [null, -1, double.nan, double.infinity, '25']) {
        expect(
          () => LocationFix.fromJson({...json, 'src': 'vehicle', 'acc': acc}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'vehicle source survives location POST, positions, hello, trail and location SSE',
    () {
      fakeAsync((clock) {
        final json = {..._fixJson, 'src': 'vehicle'}..remove('acc');
        final fix = LocationFix.fromJson(json);
        final http = FakeLocationHttp();
        final api = ApiClient(
          tokenStore: LocationTestTokenStore(),
          clientFactory: http.client,
        );
        _finish(clock, api.sendLocation('ABC123', fix));
        expect(http.posts.single.body['src'], 'vehicle');
        expect(http.posts.single.body.containsKey('acc'), isFalse);
        final snapshot = <String, dynamic>{
          'positions': [json],
          'trails': {
            'alice': [json],
          },
        };
        http.snapshot = snapshot;
        final positions = _finish(clock, api.positions('ABC123'));
        expect(positions.positions.single, fix);
        expect(positions.trails['alice']!.single, fix);
        final events = <RoomEvent>[];
        final subscription = api.subscribeEvents('ABC123').listen(events.add);
        clock.flushMicrotasks();
        http.event('hello', {...snapshot, 'self': 'bob'});
        http.event('location', json);
        http.event('trail', {
          'handle': 'alice',
          'points': [json],
          'revision': 1,
        });
        clock.flushMicrotasks();
        final hello = events.whereType<Hello>().single;
        expect(hello.positions.single, fix);
        expect(hello.trails['alice']!.single, fix);
        expect(events.whereType<LocationUpdated>().single.fix, fix);
        expect(events.whereType<TrailUpdated>().single.points.single, fix);
        unawaited(subscription.cancel());
        unawaited(http.close());
        api.close();
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  test('LocationFix는 서버 필드를 읽고 송신 JSON에서는 handle·receivedAt을 뺀다', () {
    final fix = LocationFix.fromJson(_fixJson);
    expect(fix.lng, 127.0);
    expect(fix.acc, 3.0);
    expect(fix.receivedAt, 1001);
    expect(fix.stream, '0123456789abcdef');
    expect(
      fix.toJson().keys,
      unorderedEquals([
        'stream',
        'lat',
        'lng',
        'acc',
        'speed',
        'heading',
        'at',
        'seq',
      ]),
    );
    expect(
      LocationFix.fromJson({
        ...fix.toJson(),
        'handle': fix.handle,
        'receivedAt': fix.receivedAt,
      }),
      fix,
    );
    final minimal = LocationFix.fromJson({
      'handle': 'bob',
      'stream': '0123456789abcdef',
      'lat': 0,
      'lng': 0,
      'at': 0,
      'seq': 0,
      'receivedAt': 1,
    });
    expect(minimal.toJson(), {
      'stream': '0123456789abcdef',
      'lat': 0.0,
      'lng': 0.0,
      'at': 0,
      'seq': 0,
    });
    expect(
      Room.fromJson({'code': 'ABC123', 'leader': 'alice'}).leader,
      'alice',
    );
    expect(Room.fromJson({'code': 'OLD123'}).leader, isNull);
  });

  test('실제 SSE 디코더가 hello 스냅샷과 위치/중지 이벤트를 읽는다', () {
    fakeAsync((clock) {
      final http = FakeLocationHttp();
      final api = ApiClient(
        tokenStore: LocationTestTokenStore(),
        clientFactory: http.client,
      );
      final events = <RoomEvent>[];
      final subscription = api.subscribeEvents('ABC123').listen(events.add);
      clock.flushMicrotasks();
      http.event('hello', {
        'self': {'handle': 'bob', 'displayName': '보비'},
        'members': [
          {'handle': 'alice', 'displayName': '앨리스', 'joinedAt': '1'},
        ],
        'leader': 'alice',
        'positions': [_fixJson],
        'trails': {
          'alice': [_fixJson],
        },
      });
      http.event('location', _fixJson);
      http.event('location-stopped', {'handle': 'alice'});
      http.event('follow-request', {
        'requester': 'alice',
        'requestId': 'r1',
        'revision': 1,
        'displayName': '앨리스',
      });
      http.event('follow-response', {
        'target': 'alice',
        'requestId': 'r1',
        'requester': 'bob',
        'revision': 2,
        'accepted': false,
        'reason': 'left',
      });
      http.event('follow-cancelled', {
        'requester': 'alice',
        'requestId': 'r1',
        'revision': 2,
      });
      http.event('trail', {
        'handle': 'alice',
        'points': [_fixJson],
        'revision': 2,
      });
      clock.flushMicrotasks();
      final hello = events[0] as Hello;
      expect(hello.self, 'bob');
      expect(hello.members.single.displayName, '앨리스');
      expect(hello.leader, 'alice');
      expect(hello.positions.single, LocationFix.fromJson(_fixJson));
      expect(hello.trails.keys, ['alice']);
      expect(hello.trails['alice']?.single, hello.positions.single);
      expect((events[1] as LocationUpdated).fix, hello.positions.single);
      expect((events[2] as LocationStopped).handle, 'alice');
      expect((events[3] as FollowRequest).requester, 'alice');
      expect((events[4] as FollowResponse).reason, 'left');
      expect((events[4] as FollowResponse).accepted, isFalse);
      expect((events[5] as FollowCancelled).requester, 'alice');
      expect((events[6] as TrailUpdated).points, [hello.positions.single]);
      final old = Hello.fromJson({'self': 'bob'});
      expect(old.positions, isEmpty);
      expect(old.leader, isNull);
      expect(old.trails, isEmpty);
      unawaited(subscription.cancel());
      unawaited(http.close());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('위치 API는 가짜 시계 안에서 POST 결과 dropped와 GET 스냅샷·DELETE를 전달한다', () {
    fakeAsync((clock) {
      final http = FakeLocationHttp();
      final api = ApiClient(
        tokenStore: LocationTestTokenStore(),
        clientFactory: http.client,
      );
      final fix = LocationFix.fromJson(_fixJson);
      expect(_finish(clock, api.sendLocation('ABC123', fix)), isFalse);
      http.dropped = true;
      expect(_finish(clock, api.sendLocation('ABC123', fix)), isTrue);
      expect(http.posts.first.body, fix.toJson());
      http.snapshot = {
        'positions': [_fixJson],
        'trails': {
          'alice': [_fixJson],
        },
      };
      final snapshot = _finish(clock, api.positions('ABC123'));
      expect(snapshot.positions.single, fix);
      expect(snapshot.trails['alice']?.single, fix);
      _finish(clock, api.stopLocation('ABC123'));
      expect(http.deletes.single.uri.path, '/v1/rooms/ABC123/location');
      // SSE를 구독하지 않은 controller도 종료가 완료되게 drain한다.
      final drain = http.events.stream.drain<void>();
      _finish(clock, http.close());
      _finish(clock, drain);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('follow API는 POST target·응답 accepted·DELETE를 서버 경로로 보낸다', () {
    fakeAsync((clock) {
      final http = FakeLocationHttp();
      final api = ApiClient(
        tokenStore: LocationTestTokenStore(),
        clientFactory: http.client,
      );
      _finish(clock, api.follow('ABC123', 'alice'));
      _finish(clock, api.respondFollow('ABC123', 'bob', accepted: false));
      _finish(clock, api.stopFollowing('ABC123'));
      expect(http.calls.map((call) => (call.method, call.uri.path)), [
        ('POST', '/v1/rooms/ABC123/follow'),
        ('POST', '/v1/rooms/ABC123/follow/respond'),
        ('DELETE', '/v1/rooms/ABC123/follow'),
      ]);
      expect(http.posts[0].body, {'target': 'alice'});
      expect(http.posts[1].body, {'requestId': 'bob', 'accepted': false});
      unawaited(http.events.stream.drain<void>());
      _finish(clock, http.close());
      expect(clock.pendingTimers, isEmpty);
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final method in ['POST', 'GET', 'DELETE']) {
    test('위치 $method 타임아웃도 서버 응답 없음으로 변환한다', () {
      fakeAsync((clock) {
        final http = FakeLocationHttp()..hang = true;
        final api = ApiClient(
          tokenStore: LocationTestTokenStore(),
          clientFactory: http.client,
          retryDelay: Duration.zero,
        );
        Object? error;
        final Future<Object?> request = switch (method) {
          'POST' => api.sendLocation('ABC123', LocationFix.fromJson(_fixJson)),
          'GET' => api.positions('ABC123'),
          _ => api.stopLocation('ABC123').then<Object?>((_) => null),
        };
        unawaited(
          request.then<void>(
            (_) {},
            onError: (Object value) {
              error = value;
            },
          ),
        );
        clock.flushMicrotasks();
        clock.elapse(Duration(seconds: method == 'GET' ? 30 : 15));
        expect(error, isA<ApiException>());
        expect((error! as ApiException).message, '서버 응답 없음');
        expect((error! as ApiException).code, 'timeout');
        expect(http.calls, hasLength(method == 'GET' ? 2 : 1));
        unawaited(http.events.stream.drain<void>());
        unawaited(http.close());
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }
  test('C1 num 정수 표본을 허용하고 안전 범위를 벗어난 값은 거른다', () {
    expect(LocationFix.fromJson({..._fixJson, 'seq': 1.0}).seq, 1);
    expect(
      LocationFix.fromJson({..._fixJson, 'seq': 9007199254740991}).seq,
      9007199254740991,
    );
    for (final seq in [1e100, 9007199254740992, -1, double.nan, 1.5]) {
      expect(
        () => LocationFix.fromJson({..._fixJson, 'seq': seq}),
        throwsFormatException,
      );
    }
    for (final bad in [
      {'lat': 91},
      {'lng': double.infinity},
      {'acc': -1},
      {'speed': -1},
      {'heading': 361},
    ]) {
      expect(
        () => LocationFix.fromJson({..._fixJson, ...bad}),
        throwsFormatException,
      );
    }
  });

  test('C1 잘못된 hello·trail·location 표본만 건너뛰고 SSE 시그널을 계속 받는다', () {
    fakeAsync((clock) {
      final http = FakeLocationHttp();
      final api = ApiClient(
        tokenStore: LocationTestTokenStore(),
        clientFactory: http.client,
      );
      final events = <RoomEvent>[];
      final logs = <String?>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message);
      final subscription = api.subscribeEvents('ABC123').listen(events.add);
      clock.flushMicrotasks();
      final bad = {..._fixJson, 'seq': 1e100};
      http.event('hello', {
        'self': 'bob',
        'revision': 1,
        'positions': [bad, _fixJson, null],
        'trails': {
          'alice': [bad, _fixJson],
        },
      });
      http.event('location', bad);
      http.event('trail', {
        'handle': 'alice',
        'points': [bad, _fixJson],
        'revision': 1,
      });
      http.event('location', {..._fixJson, 'seq': 1.0});
      http.event('signal', {
        'from': 'alice',
        'kind': 'custom',
        'payload': 'alive',
      });
      clock.flushMicrotasks();
      expect(events.whereType<Disconnected>(), isEmpty);
      expect(events.whereType<Hello>().single.positions, hasLength(1));
      expect(events.whereType<TrailUpdated>().single.points, hasLength(1));
      expect(events.whereType<LocationUpdated>().single.fix.seq, 1);
      expect(events.whereType<Signal>().single.payload, 'alive');
      expect(logs, ['잘못된 위치 표본을 건너뛰었습니다']);
      debugPrint = previousPrint;
      unawaited(subscription.cancel());
      unawaited(http.close());
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });
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
