import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/net/api_client.dart';

import 'support/location_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('1초 이내 표본은 최신 것 하나만 보류하고 시한에 전송한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.start();
      f.add(lat: 37);
      expect(f.http.posts, hasLength(1));
      clock.elapse(const Duration(milliseconds: 250));
      f.add(lat: 37.001);
      clock.elapse(const Duration(milliseconds: 250));
      f.add(lat: 37.002);
      clock.elapse(const Duration(milliseconds: 499));
      expect(f.http.posts, hasLength(1));
      clock.elapse(const Duration(milliseconds: 1));
      expect(f.http.posts, hasLength(2));
      expect(f.http.posts.last.body['lat'], 37.002);
      expect(f.http.posts.map((call) => call.body['seq']), [0, 1]);
      expect(f.share.lastSent?.lat, 37.002);
      f.dispose();
    });
  });

  test('속도 0.5 미만·3m 미만이면 5초, 다시 이동하면 1초 간격이다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.start();
      f.add(speed: 0);
      for (var second = 1; second <= 3; second++) {
        clock.elapse(const Duration(seconds: 1));
        f.add(speed: 0);
      }
      expect(f.share.isStationary, isTrue);
      expect(f.http.posts, hasLength(1));
      clock.elapse(const Duration(milliseconds: 1999));
      expect(f.http.posts, hasLength(1));
      clock.elapse(const Duration(milliseconds: 1));
      expect(f.http.posts, hasLength(2));
      clock.elapse(const Duration(milliseconds: 500));
      f.add(speed: 0, lat: 37.001); // 속도만 낮고 실제로 이동하면 5초 제한을 푼다.
      clock.elapse(const Duration(milliseconds: 500));
      expect(f.http.posts, hasLength(3));
      f.dispose();
    });
  });

  test('최근 3초 이동 또는 속도로 정차를 판단하고 오래된 표본은 허용하지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.start();
      f.add(speed: null);
      expect(f.share.isStationary, isFalse);
      for (var second = 1; second <= 3; second++) {
        clock.elapse(const Duration(seconds: 1));
        f.add(speed: null);
      }
      expect(f.share.isStationary, isTrue); // 속도가 없으면 3m 미만 이동으로 판단한다.
      clock.elapse(const Duration(seconds: 3));
      expect(f.share.isStationary, isFalse);
      f.add(speed: 3, lat: 37.1);
      for (var second = 1; second <= 3; second++) {
        clock.elapse(const Duration(seconds: 1));
        f.add(speed: 3, lat: 37.1 + second * .001);
      }
      expect(f.share.isStationary, isFalse);
      f.dispose();
    });
  });

  test('실패 3회 뒤에는 다음 성공까지 5초 간격이며 공유와 seq를 유지한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.http.failures = 3;
      f.start();
      f.add();
      for (var second = 1; second <= 2; second++) {
        clock.elapse(const Duration(seconds: 1));
        f.add(lat: 37 + second * .001);
      }
      expect(f.share.sharing, isTrue);
      expect(f.share.error, '위치 전송 실패');
      expect(f.share.lastSent, isNull);
      clock.elapse(const Duration(seconds: 1));
      f.add(lat: 37.003);
      clock.elapse(const Duration(milliseconds: 3999));
      expect(f.http.posts, hasLength(3));
      clock.elapse(const Duration(milliseconds: 1));
      expect(f.http.posts, hasLength(4));
      expect(f.share.error, isNull);
      expect(f.share.lastSent?.seq, 3);
      clock.elapse(const Duration(seconds: 1));
      f.add(lat: 37.008);
      expect(f.http.posts, hasLength(5));
      expect(f.http.posts.map((call) => call.body['seq']), [0, 1, 2, 3, 4]);
      f.dispose();
    });
  });

  test('중지는 하드웨어 구독·보류 타이머·서버 위치를 끝내며 재시작 seq는 이어진다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.start();
      f.add();
      final stream = f.http.posts.single.body['stream'];
      expect(stream, matches(RegExp(r'^[0-9a-f]{16}$')));
      clock.elapse(const Duration(milliseconds: 100));
      f.add(lat: 37.001);
      _finish(clock, f.share.stop());
      expect(f.share.sharing, isFalse);
      expect(f.source.cancellations, 1);
      expect(f.http.deletes.single.uri.path, '/v1/rooms/ABC123/location');
      clock.elapse(const Duration(seconds: 10));
      expect(f.http.posts, hasLength(1));
      expect(clock.pendingTimers, isEmpty);
      _finish(clock, f.share.start());
      f.add(lat: 37.002);
      expect(f.http.posts.last.body['seq'], 1);
      expect(f.http.posts.last.body['stream'], stream);
      f.http.deleteFails = true;
      _finish(clock, f.share.stop());
      expect(f.share.sharing, isFalse);
      expect(f.source.cancellations, 2);
      f.dispose();
    });
  });

  test('이전 POST가 완료된 뒤 DELETE하며 중지 중 늦은 응답은 상태를 되살리지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      final gate = Completer<void>();
      f.http.sendGate = gate.future;
      f.start();
      f.add();
      final stopping = f.share.stop();
      clock.flushMicrotasks();
      expect(f.share.sharing, isFalse);
      expect(f.source.cancellations, 1);
      expect(f.http.deletes, isEmpty);
      gate.complete();
      _finish(clock, stopping);
      expect(f.http.calls.map((call) => call.method), ['POST', 'DELETE']);
      expect(f.share.lastSent, isNull);
      f.dispose();
    });
  });

  test('방 코드 변경·나가기는 이전 방 DELETE로 정리하고 자동 재시작하지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.start();
      f.add();
      f.code = 'NEW123';
      f.share.roomChanged();
      clock.flushMicrotasks();
      expect(f.share.sharing, isFalse);
      expect(f.http.deletes.single.uri.path, '/v1/rooms/ABC123/location');
      expect(f.source.watches, 1);
      _finish(clock, f.share.start());
      f.add();
      expect(f.http.posts.last.uri.path, '/v1/rooms/NEW123/location');
      f.code = null;
      f.share.roomChanged();
      clock.flushMicrotasks();
      expect(f.http.deletes.last.uri.path, '/v1/rooms/NEW123/location');
      expect(f.share.sharing, isFalse);
      f.dispose();
    });
  });

  test('중지 완료를 기다리던 재시작도 뒤이은 중지로 취소된다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      final gate = Completer<void>();
      f.http.sendGate = gate.future;
      f.start();
      f.add();
      final stopping = f.share.stop();
      final restarting = f.share.start();
      clock.flushMicrotasks();
      unawaited(f.share.stop());
      gate.complete();
      _finish(clock, stopping);
      _finish(clock, restarting);
      expect(f.share.sharing, isFalse);
      expect(f.source.watches, 1);
      expect(f.http.deletes, hasLength(1));
      f.dispose();
    });
  });

  test('동의 이력이 있어도 이번 실행은 동의·명시 시작을 각각 기다린다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, savedConsent: true);
      expect(f.share.consented, isFalse);
      expect(f.share.sharing, isFalse);
      _finish(clock, f.share.start());
      expect(f.source.requests, 0);
      expect(f.share.error, '위치 공유 동의가 필요합니다');
      _finish(clock, f.share.consent());
      expect(f.preferences.getBool(LocationShare.consentKey), isTrue);
      expect(f.source.requests, 0);
      expect(f.share.sharing, isFalse);
      _finish(clock, f.share.start());
      expect(f.share.sharing, isTrue);
      f.dispose();
    });
  });

  for (final permission in LocationPermissionState.values.where(
    (value) => value != LocationPermissionState.granted,
  )) {
    test('$permission은 상태 문구를 표시하고 watch를 열지 않는다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.source.permission = permission;
        f.start();
        expect(f.share.permission, permission);
        expect(f.share.sharing, isFalse);
        expect(f.source.watches, 0);
        expect(
          f.share.error,
          permission == LocationPermissionState.serviceOff
              ? '위치 서비스가 꺼져 있습니다'
              : '위치 권한이 없습니다',
        );
        f.dispose();
      });
    });
  }

  test('source가 없으면 사용 불가이며 권한 요청 중 방을 떠나도 구독을 시작하지 않는다', () {
    fakeAsync((clock) {
      final unavailable = _Fixture.create(clock, available: false);
      unavailable.start();
      expect(unavailable.share.available, isFalse);
      expect(unavailable.share.error, '위치 공유를 사용할 수 없습니다');
      expect(unavailable.source.watches, 0);
      unavailable.dispose();

      final f = _Fixture.create(clock);
      f.source.pendingPermission = Completer<LocationPermissionState>();
      _finish(clock, f.share.consent());
      final starting = f.share.start();
      clock.flushMicrotasks();
      f.code = null;
      f.share.roomChanged();
      f.source.pendingPermission!.complete(LocationPermissionState.granted);
      _finish(clock, starting);
      expect(f.source.watches, 0);
      expect(f.share.sharing, isFalse);
      f.dispose();
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

class _Fixture {
  _Fixture(this.clock, this.preferences, {required bool available}) {
    share = LocationShare(
      api: ApiClient(
        tokenStore: LocationTestTokenStore(),
        clientFactory: http.client,
      ),
      source: available ? source : null,
      roomCode: () => code,
      selfHandle: () => 'alice',
      preferences: preferences,
      now: now,
    );
  }
  static _Fixture create(
    FakeAsync clock, {
    bool available = true,
    bool savedConsent = false,
  }) {
    SharedPreferences.setMockInitialValues({
      LocationShare.consentKey: savedConsent,
    });
    return _Fixture(
      clock,
      _finish(clock, SharedPreferences.getInstance()),
      available: available,
    );
  }

  final FakeAsync clock;
  final SharedPreferences preferences;
  final source = FakeLocationSource();
  final http = FakeLocationHttp();
  late final LocationShare share;
  String? code = 'ABC123';
  DateTime now() => DateTime.utc(2026).add(clock.elapsed);
  void start() {
    _finish(clock, share.consent());
    _finish(clock, share.start());
  }

  void add({double lat = 37, double? speed = 2}) {
    source.add(LocationSample(lat: lat, lng: 127, speed: speed, at: now()));
    clock.flushMicrotasks();
  }

  void dispose() {
    _finish(clock, share.stop());
    share.dispose();
    _finish(clock, source.close());
    unawaited(http.events.stream.drain<void>());
    _finish(clock, http.close());
    clock.flushMicrotasks();
    expect(clock.pendingTimers, isEmpty);
  }
}
