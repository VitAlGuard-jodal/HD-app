import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
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
      'lat': 0,
      'lng': 0,
      'at': 0,
      'seq': 0,
      'receivedAt': 1,
    });
    expect(minimal.toJson(), {
      'stream': '',
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
        'trail': {
          'handle': 'alice',
          'points': [_fixJson],
        },
      });
      http.event('location', _fixJson);
      http.event('location-stopped', {'handle': 'alice'});
      clock.flushMicrotasks();
      final hello = events[0] as Hello;
      expect(hello.self, 'bob');
      expect(hello.members.single.displayName, '앨리스');
      expect(hello.leader, 'alice');
      expect(hello.positions.single, LocationFix.fromJson(_fixJson));
      expect(hello.trail?.handle, 'alice');
      expect(hello.trail?.points.single, hello.positions.single);
      expect((events[1] as LocationUpdated).fix, hello.positions.single);
      expect((events[2] as LocationStopped).handle, 'alice');
      final old = Hello.fromJson({'self': 'bob'});
      expect(old.positions, isEmpty);
      expect(old.leader, isNull);
      expect(old.trail, isNull);
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
        'trail': {
          'handle': 'alice',
          'points': [_fixJson],
        },
      };
      final snapshot = _finish(clock, api.positions('ABC123'));
      expect(snapshot.positions.single, fix);
      expect(snapshot.trail?.points.single, fix);
      _finish(clock, api.stopLocation('ABC123'));
      expect(http.deletes.single.uri.path, '/v1/rooms/ABC123/location');
      // SSE를 구독하지 않은 controller도 종료가 완료되게 drain한다.
      final drain = http.events.stream.drain<void>();
      _finish(clock, http.close());
      _finish(clock, drain);
      expect(clock.pendingTimers, isEmpty);
    });
  });

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
