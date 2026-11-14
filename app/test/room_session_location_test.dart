import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/app_services.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/core/driving_state.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/location/follow_voice_guidance.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/net/meeting_plan.dart';
import 'package:unavo/room/room_session.dart';

import 'support/location_fakes.dart';
import 'support/meeting_plan_fakes.dart' as meeting;
import 'support/consent_fakes.dart' show testConsent;

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

  test('합류 계획 hello는 위치 revision과 독립이며 빈 재접속은 ②를 종료한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.store.updateConsent(
        testConsent(),
        sessionRevision: f.store.sessionRevision,
      );
      f.open();
      f.startSharing();
      final plan = meeting.planJson(leader: 'alice')
        ..['roomCode'] = 'ABC123'
        ..['participantFollowRequestIds'] = ['alice-request'];
      final runtime = meeting.runtimeJson(leader: 'alice', follower: 'bob');
      runtime['enrollments'] = [
        {'handle': 'bob', 'followRequestId': 'alice-request'},
      ];
      (runtime['vehicles'] as List)[1]['followRequestId'] = 'alice-request';
      final snapshot = MeetingPlanSnapshot.fromJson({
        'plan': plan,
        'runtime': runtime,
      });
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          'alice',
          const [],
          5000,
          null,
          'alice-request',
          f.now().millisecondsSinceEpoch,
          const FollowRouteFeature(enabled: true),
          [snapshot],
          const [],
          meeting.planFeatures,
        ),
      );
      expect(f.session.meetingPlan.selected, isTrue);
      expect(f.session.meetingPlan.restored, isTrue);
      expect(f.session.followRoute.state, isNull);
      f.event(
        FollowPlanProgress(
          MeetingRuntime.fromJson(runtime..['runtimeRevision'] = 2),
        ),
      );
      expect(f.session.meetingPlan.active!.runtime!.runtimeRevision, 2);
      f.event(const Reconnected());
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          null,
          const [],
          0,
          null,
          null,
          f.now().millisecondsSinceEpoch,
          const FollowRouteFeature(enabled: true),
          const [],
          const [],
          meeting.planFeatures,
        ),
      );
      expect(f.session.meetingPlan.active, isNull);
      expect(f.session.followRoute.state, isNull);
      expect(f.session.locationShare.sharing, isTrue);
      f.dispose();
    });
  });

  for (final reason in ['stopped', 'stale']) {
    test('D2 $reason SSE는 차량 음성과 기존 화면 알림에 각각 한 번 전달된다', () {
      fakeAsync((clock) {
        final speech = _FollowSpeech();
        final f = _Fixture.create(clock, mode: DeviceMode.car, speech: speech);
        f.open();
        f.startSharing();
        _finish(clock, f.session.startFollowing('alice'));
        f.event(LocationStopped('alice', reason: reason, revision: 20));
        f.event(LocationStopped('alice', reason: reason, revision: 20));
        f.event(
          FollowResponse(
            'alice',
            false,
            requestId: 'alice-request',
            reason: reason,
            revision: 20,
          ),
        );
        expect(speech.texts, [
          reason == 'stopped'
              ? '앨리스 님이 위치 공유를 중지했습니다'
              : '앨리스 님 위치가 잠시 갱신되지 않고 있습니다',
        ]);
        expect(f.session.followTarget, isNull);
        expect(f.session.takeFollowNotice()?.reason, reason);
        expect(f.session.takeFollowNotice(), isNull);
        f.dispose();
      });
    }, timeout: _timeout);
  }

  test('D2 차량은 측정 시각 90초 지연과 후속 서버 stale을 한 번만 말한다', () {
    fakeAsync((clock) {
      final speech = _FollowSpeech();
      final f = _Fixture.create(clock, mode: DeviceMode.car, speech: speech);
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      f.event(
        LocationUpdated(
          LocationFix(
            handle: 'alice',
            stream: '0123456789abcdef',
            lat: 37,
            lng: 127,
            at: f.now().millisecondsSinceEpoch,
            seq: 1,
          ),
        ),
      );
      clock.elapse(const Duration(seconds: 90));
      clock.flushMicrotasks();
      expect(speech.texts, ['앨리스 님 위치가 잠시 갱신되지 않고 있습니다']);
      f.event(const LocationStopped('alice', reason: 'stale', revision: 20));
      expect(speech.texts, hasLength(1));
      expect(f.session.takeFollowNotice()?.reason, 'stale');
      f.dispose();
    });
  }, timeout: _timeout);

  for (final action in ['leave', 'stop-follow', 'stop-share']) {
    test('D2 $action는 RoomSession에서 음성 stop까지 전달된다', () {
      fakeAsync((clock) {
        final speech = _FollowSpeech();
        final f = _Fixture.create(clock, mode: DeviceMode.car, speech: speech);
        f.open();
        f.startSharing();
        _finish(clock, f.session.startFollowing('alice'));
        switch (action) {
          case 'leave':
            _finish(clock, f.session.leave());
          case 'stop-follow':
            _finish(clock, f.session.stopFollowing());
          case 'stop-share':
            _finish(clock, f.session.locationShare.stop());
        }
        clock.flushMicrotasks();
        expect(speech.stops, 1);
        clock.elapse(const Duration(seconds: 91));
        clock.flushMicrotasks();
        expect(speech.texts, isEmpty);
        f.dispose();
      });
    }, timeout: _timeout);
  }

  for (final leaveFails in [true, false]) {
    test(
      leaveFails
          ? '공유 중 DELETE·leave 실패로 방에 남으면 삭제 작업을 유지하고 다음 재시도에 성공한다'
          : 'DELETE 실패 뒤 leave가 성공하면 삭제 작업과 재시도 타이머를 정리한다',
      () {
        fakeAsync((clock) {
          final f = _Fixture.create(clock);
          f.open();
          f.startSharing();
          f.sample();
          f.http.deleteFails = true;
          f.api.leaveFails = leaveFails;
          Object? failure;
          _finish(
            clock,
            f.session.leave().catchError((Object error) {
              failure = error;
            }),
          );
          expect(failure, leaveFails ? isA<ApiException>() : isNull);
          expect(f.session.state.code, leaveFails ? 'ABC123' : isNull);
          expect(f.session.state.isLeaving, isFalse);
          expect(f.session.locationShare.sharing, isFalse);
          expect(f.session.locationShare.deletionPending, leaveFails);
          expect(f.http.deletes, hasLength(1));
          f.http.deleteFails = false;
          clock.elapse(const Duration(seconds: 1));
          clock.flushMicrotasks();
          expect(f.http.deletes, hasLength(leaveFails ? 2 : 1));
          expect(f.session.locationShare.deletionPending, isFalse);
          f.dispose();
        });
      },
      timeout: _timeout,
    );
  }

  test('나가기 중에는 방 식별자를 유지해도 새 위치 공유를 시작하지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.session.state = f.session.state.copyWith(isLeaving: true);
      f.startSharing();
      expect(f.session.state.code, 'ABC123');
      expect(f.source.requests, 0);
      expect(f.source.watches, 0);
      expect(f.session.locationShare.sharing, isFalse);
      f.dispose();
    });
  }, timeout: _timeout);

  for (final connected in [true, false]) {
    test(
      connected
          ? '연결된 상태에서 요청 오류 뒤 멤버 refresh가 성공하면 오류를 지운다'
          : 'SSE 미연결 상태에서는 멤버 refresh가 성공해도 재접속 안내를 유지한다',
      () {
        fakeAsync((clock) {
          final f = _Fixture.create(clock);
          f.open();
          f.api.roomRead = () async =>
              throw const ApiException(0, 'timeout', '서버 응답 없음');
          f.event(const MemberJoined('alice'));
          expect(f.session.state.error, '서버 응답 없음');
          if (!connected) {
            f.event(const Disconnected('서버 응답 없음', 2000));
          }
          final error = f.session.state.error;
          f.api.roomRead = null;
          f.event(const MemberJoined('alice'));
          expect(f.session.state.isConnected, connected);
          expect(f.session.state.error, connected ? isNull : error);
          f.dispose();
        });
      },
      timeout: _timeout,
    );
  }

  for (final deleteFails in [false, true]) {
    test(
      'AppServices.dispose는 위치 DELETE 완료 뒤 client를 한 번 닫는다 (실패 $deleteFails)',
      () {
        fakeAsync((clock) {
          final http = FakeLocationHttp()..deleteFails = deleteFails;
          final source = FakeLocationSource();
          var clients = 0, closes = 0;
          HttpOverrides.runZoned(
            () {
              SharedPreferences.setMockInitialValues({
                'token': 'test',
                'handle': 'bob',
              });
              final store = SessionStore(
                _finish(clock, SharedPreferences.getInstance()),
              );
              final services = AppServices(
                store,
                mediaEngine: _Media(),
                locationSource: source,
                deviceMode: DeviceMode.phone,
              );
              services.rooms.state = const RoomState(code: 'ABC123');
              _finish(
                clock,
                services.locationShare.start(
                  token: Object(),
                  stillValid: () => true,
                ),
              );
              final post = Completer<void>();
              final deletion = Completer<void>();
              http.sendGate = post.future;
              http.deleteGate = deletion.future;
              source.add(
                LocationSample(lat: 37, lng: 127, at: DateTime.utc(2026)),
              );
              clock.flushMicrotasks();
              expect(http.posts, hasLength(1));
              expect(clients, 1);
              services.dispose();
              clock.flushMicrotasks();
              expect(closes, 0);
              expect(http.deletes, isEmpty);
              post.complete();
              clock.flushMicrotasks();
              expect(http.deletes, hasLength(1));
              expect(closes, 0);
              deletion.complete();
              _finish(clock, services.rooms.shutdown());
              expect(closes, 1);
              expect(clients, 1, reason: 'DELETE도 종료 전 공유 client를 사용한다');
              expect(services.locationShare.deletionPending, isFalse);
              services.dispose();
              clock.elapse(const Duration(minutes: 1));
              expect(closes, 1);
              expect(clients, 1);
            },
            createHttpClient: (_) {
              clients++;
              return _TrackedClient(http.client(), () => closes++);
            },
          );
          _finish(clock, source.close());
          unawaited(http.events.stream.drain<void>());
          _finish(clock, http.close());
          expect(clock.pendingTimers, isEmpty);
        });
      },
      timeout: _timeout,
    );
  }

  test('shutdown은 늦은 follow POST와 후속 DELETE 완료까지 기다린다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.startSharing();
      final post = Completer<void>();
      final deletion = Completer<void>();
      f.api.followGate = post.future;
      f.api.stopGate = deletion.future;
      final following = f.session.startFollowing('alice');
      clock.flushMicrotasks();
      var complete = false;
      final shutdown = f.session.shutdown().then((_) => complete = true);
      clock.flushMicrotasks();
      expect(f.http.deletes, hasLength(1));
      expect(complete, isFalse);
      post.complete();
      clock.flushMicrotasks();
      expect(f.api.unfollows, 1);
      expect(complete, isFalse);
      deletion.complete();
      _finish(clock, following);
      _finish(clock, shutdown);
      expect(complete, isTrue);
      f.dispose();
    });
  }, timeout: _timeout);

  test(
    '서버 재시작: revision 5000 세션이 재접속해 revision 3 hello 를 받으면 스냅샷·followRequests 를 적용한다',
    () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.open();
        f.event(LocationUpdated(_fix('alice', 100), revision: 5000));
        f.event(const Reconnected());
        expect(f.session.followServerRevision, 0);
        f.api.members = const [Member('bob', '보비', '2')];
        final fix = _fix('alice', 0, stream: '1111111111111111');
        f.event(
          Hello(
            'bob',
            f.api.members,
            'bob',
            [fix],
            const {},
            null,
            const [
              FollowRequest('alice', requestId: 'after-restart', revision: 3),
            ],
            3,
          ),
        );
        expect(f.session.followServerRevision, 3);
        expect(f.session.positions, {'alice': fix});
        expect(f.session.leaderHandle, 'bob');
        expect(f.session.state.members.map((m) => m.handle), ['bob']);
        expect(f.session.followRequests.keys, ['after-restart']);
        f.dispose();
      });
    },
    timeout: _timeout,
  );

  for (final restarted in [false, true]) {
    test('자동 복구 restart=$restarted: 위치 관찰은 유지하고 따라가기는 hello를 따른다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.open();
        f.startSharing();
        f.sample();
        _finish(clock, f.session.startFollowing('alice'));
        final requestId = f.session.followRequestId;
        final fix = _fix('alice', 100);
        f.event(LocationUpdated(fix, revision: 5000));
        f.event(const Disconnected('연결 복구 중', 2000));
        f.http.failures = 1;
        clock.elapse(const Duration(seconds: 1));
        f.sample(lat: 37.001);
        expect(f.session.locationShare.error, isNotNull);
        expect(f.session.locationShare.sharing, isTrue);
        expect(f.source.watches, 1);
        expect(f.source.cancellations, 0);

        f.event(const Reconnected());
        f.event(
          Hello(
            'bob',
            f.api.members,
            'alice',
            restarted ? const [] : [fix],
            restarted
                ? const {}
                : {
                    'alice': [fix],
                  },
            restarted ? null : 'alice',
            const [],
            restarted ? 0 : 5000,
            null,
            restarted ? null : requestId,
          ),
        );
        expect(f.session.state.code, 'ABC123');
        expect(f.session.state.isConnected, isTrue);
        expect(f.session.deviceReplaced, isFalse);
        expect(f.session.followTarget, restarted ? isNull : 'alice');
        expect(f.session.followRequestId, restarted ? isNull : requestId);
        expect(f.session.trailOf('alice'), restarted ? isEmpty : [fix]);
        expect(f.api.follows, [
          'alice',
        ]); // no silent re-request after lost consent
        expect(f.session.locationShare.sharing, isTrue);

        // The existing location subscription supplies the next fix without a
        // permission prompt, another watch, or a user action.
        clock.elapse(const Duration(seconds: 1));
        f.sample(lat: 37.002);
        expect(f.session.locationShare.error, isNull);
        expect(f.session.locationShare.lastSent?.lat, 37.002);
        expect(f.source.requests, 1);
        expect(f.source.watches, 1);
        expect(f.source.cancellations, 0);
        expect(f.http.deletes, isEmpty);
        f.dispose();
      });
    }, timeout: _timeout);
  }

  test('이전 연결의 보류 수락 응답은 재접속 뒤 완료된 POST 에 적용되지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.startSharing();
      final gate = Completer<void>();
      f.api.followGate = gate.future;
      f.api.followResult = const FollowResult('old-request', 5000, false);
      final pending = f.session.startFollowing('alice');
      clock.flushMicrotasks();
      f.event(
        const FollowResponse(
          'alice',
          true,
          requestId: 'old-request',
          revision: 5001,
        ),
      );
      f.event(const Reconnected());
      final fix = _fix('alice', 0);
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          [fix],
          {
            'alice': [fix],
          },
          null,
          const [],
          3,
          'alice',
          'new-request',
        ),
      );
      expect(
        f.session.followRequestId,
        isNull,
        reason: 'POST 중에는 hello의 follow 필드만 보류한다',
      );
      expect(f.session.positions['alice'], fix);
      final next = _fix('alice', 1);
      f.event(LocationUpdated(next, revision: 4));
      f.event(
        const FollowRequest('alice', requestId: 'new-incoming', revision: 5),
      );
      gate.complete();
      _finish(clock, pending);
      expect(f.session.followTarget, isNull);
      expect(f.session.pendingFollow, 'alice');
      expect(f.session.followRequestId, 'new-request');
      expect(f.session.trailOf('alice'), [fix, next]);
      expect(f.session.positions['alice'], next);
      expect(f.session.followRequests.keys, ['new-incoming']);
      expect(f.session.followServerRevision, 5);
      f.event(
        const FollowResponse(
          'alice',
          true,
          requestId: 'new-request',
          revision: 6,
        ),
      );
      expect(f.session.followTarget, 'alice');
      f.dispose();
    });
  }, timeout: _timeout);

  test('이전 연결 DELETE 완료는 새 hello follow와 낮은 revision을 덮지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      final gate = Completer<void>();
      f.api.stopGate = gate.future;
      f.api.revision = 5000;
      final stopping = f.session.stopFollowing();
      clock.flushMicrotasks();
      f.event(const Reconnected());
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          'alice',
          const [],
          3,
          null,
          'new-request',
        ),
      );
      expect(f.session.followTarget, isNull);
      gate.complete();
      _finish(clock, stopping);
      expect(f.session.followTarget, 'alice');
      expect(f.session.followRequestId, 'new-request');
      expect(f.session.followServerRevision, 3);
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          null,
          const [],
          4,
        ),
      );
      expect(
        f.session.followIntent,
        isNull,
        reason: '이전 연결의 HTTP revision이 새 hello를 막으면 안 된다',
      );
      f.dispose();
    });
  }, timeout: _timeout);

  test('이전 연결 respond 완료는 새 연결의 수신 요청을 제거하거나 응답 완료로 기록하지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      const request = FollowRequest('alice', requestId: 'same-id', revision: 1);
      f.event(request);
      final gate = Completer<void>();
      f.api.responseGate = gate.future;
      f.api.revision = 5000;
      final responding = f.session.respondToFollow('same-id', accepted: false);
      clock.flushMicrotasks();
      f.event(const Reconnected());
      final hello = Hello(
        'bob',
        f.api.members,
        'alice',
        const [],
        const {},
        null,
        const [request],
        3,
      );
      f.event(hello);
      gate.complete();
      _finish(clock, responding);
      expect(f.session.followRequests.keys, ['same-id']);
      f.event(hello);
      expect(f.session.followRequests.keys, ['same-id']);
      expect(f.session.followServerRevision, 3);
      f.dispose();
    });
  }, timeout: _timeout);

  test('보류 hello의 이전 대상이 중지되어도 새 대상 POST 의도는 유지한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.api.members = [...f.api.members, const Member('charlie', '찰리', '3')];
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      final gate = Completer<void>();
      f.api.followGate = gate.future;
      f.api.followResult = const FollowResult('charlie-new', 5, true);
      final pending = f.session.startFollowing('charlie');
      clock.flushMicrotasks();
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          'alice',
          const [],
          2,
          null,
          'alice-request',
        ),
      );
      f.event(const LocationStopped('alice', revision: 3));
      expect(f.session.pendingFollow, 'charlie');
      gate.complete();
      _finish(clock, pending);
      expect(f.session.followTarget, 'charlie');
      expect(f.session.followRequestId, 'charlie-new');
      expect(f.session.followServerRevision, 3);
      f.dispose();
    });
  }, timeout: _timeout);

  for (final stopped in ['alice', 'charlie']) {
    test('재접속 보류 hello는 $stopped 종료를 반영한 뒤 이전 POST 완료에서 복원한다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.api.members = [...f.api.members, const Member('charlie', '찰리', '3')];
        f.open();
        f.startSharing();
        final gate = Completer<void>();
        f.api.followGate = gate.future;
        f.api.followResult = const FollowResult('old-request', 5000, true);
        final pending = f.session.startFollowing('alice');
        clock.flushMicrotasks();
        f.event(const Reconnected());
        f.event(
          Hello(
            'bob',
            f.api.members,
            'alice',
            const [],
            const {},
            null,
            const [],
            3,
            'charlie',
            'charlie-new',
          ),
        );
        f.event(
          const FollowResponse(
            'charlie',
            true,
            requestId: 'charlie-new',
            revision: 4,
          ),
        );
        f.event(LocationStopped(stopped, revision: 5));
        gate.complete();
        _finish(clock, pending);
        expect(f.session.followTarget, stopped == 'alice' ? 'charlie' : null);
        expect(f.session.pendingFollow, isNull);
        expect(
          f.session.followRequestId,
          stopped == 'alice' ? 'charlie-new' : null,
        );
        expect(f.session.followServerRevision, 5);
        f.dispose();
      });
    }, timeout: _timeout);
  }

  test('requester-stale 종료 응답은 현재 requestId일 때만 따라가기를 끝낸다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      f.event(
        const FollowResponse(
          'alice',
          false,
          requestId: 'old-request',
          reason: 'requester-stale',
          revision: 2,
        ),
      );
      expect(f.session.followTarget, 'alice');
      expect(f.session.hasFollowNotice, isFalse);
      f.event(
        const FollowResponse(
          'alice',
          false,
          requestId: 'alice-request',
          reason: 'requester-stale',
          revision: 3,
        ),
      );
      expect(f.session.followIntent, isNull);
      expect(f.session.takeFollowNotice()?.reason, 'requester-stale');
      f.dispose();
    });
  }, timeout: _timeout);

  test(
    'HTTP 응답 revision 뒤 낮은 revision 의 정상 FollowRequest·LocationStopped 를 적용한다',
    () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.open(positions: [_fix('alice', 0)]);
        f.startSharing();
        f.api.followResult = const FollowResult('alice-request', 20, true);
        _finish(clock, f.session.startFollowing('alice'));
        expect(f.session.followServerRevision, 0);
        f.event(
          const FollowRequest('alice', requestId: 'incoming', revision: 2),
        );
        expect(f.session.followRequests.keys, ['incoming']);
        f.event(const LocationStopped('alice', revision: 3));
        expect(f.session.positions.containsKey('alice'), isFalse);
        expect(f.session.followIntent, isNull);
        expect(f.session.followServerRevision, 3);
        f.dispose();
      });
    },
    timeout: _timeout,
  );

  test('DELETE 완료 뒤 지연된 같은 연결 hello 가 follow 를 되살리지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      _finish(clock, f.session.stopFollowing());
      final fix = _fix('alice', 3);
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          [fix],
          {
            'alice': [fix],
          },
          'alice',
          const [FollowRequest('alice', requestId: 'incoming', revision: 1)],
          1,
          null,
          'alice-request',
        ),
      );
      expect(f.session.followIntent, isNull);
      expect(f.session.followRequestId, isNull);
      expect(f.session.trailOf('alice'), isEmpty);
      expect(f.session.positions['alice'], fix);
      expect(f.session.followRequests.keys, ['incoming']);
      expect(f.session.followServerRevision, 1);
      f.dispose();
    });
  }, timeout: _timeout);

  test('응답 완료한 수신 요청 id 는 늦은 hello 에 있어도 다시 뜨지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      const request = FollowRequest(
        'alice',
        requestId: 'answered',
        revision: 1,
      );
      f.event(request);
      f.api.revision = 10;
      _finish(clock, f.session.respondToFollow('answered', accepted: false));
      final fix = _fix('alice', 1);
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          [fix],
          const {},
          null,
          const [
            request,
            FollowRequest('alice', requestId: 'other', revision: 2),
          ],
          2,
        ),
      );
      expect(f.session.followRequests.keys, ['other']);
      expect(f.session.positions['alice'], fix);
      expect(f.session.followServerRevision, 2);
      f.event(const Reconnected());
      f.event(
        Hello('bob', f.api.members, 'alice', const [], const {}, null, const [
          request,
        ], 1),
      );
      expect(f.session.followRequests.keys, [
        'answered',
      ], reason: '응답 완료 기록은 연결을 넘지 않는다');
      f.dispose();
    });
  }, timeout: _timeout);

  for (final fails in [false, true]) {
    test(
      '지연된 멤버 조회 A 는 퇴장 이벤트·조회 B 뒤에 완료돼도 퇴장자를 명단·미디어에 되살리지 않는다 (실패 $fails)',
      () {
        fakeAsync((clock) {
          final f = _Fixture.create(clock);
          f.open();
          final old = RoomDetails(const Room('ABC123', '옛 방'), f.api.members);
          final gate = Completer<RoomDetails>();
          f.api.roomRead = () => gate.future;
          f.event(
            const FollowRequest('charlie', requestId: 'refresh-a', revision: 1),
          );
          f.api.roomRead = null;
          f.api.members = const [Member('bob', '보비', '2')];
          f.event(const MemberLeft('alice', revision: 2));
          final mediaCalls = f.media.memberUpdates.length;
          if (fails) {
            gate.completeError(const ApiException(403, 'forbidden', '옛 조회 오류'));
          } else {
            gate.complete(old);
          }
          clock.flushMicrotasks();
          expect(f.session.state.code, 'ABC123');
          expect(f.session.state.error, isNull);
          expect(f.session.state.members.map((m) => m.handle), ['bob']);
          expect(f.media.memberUpdates, hasLength(mediaCalls));
          expect(f.media.memberUpdates.last, ['bob']);
          f.dispose();
        });
      },
      timeout: _timeout,
    );
  }

  test('위치·궤적이 바뀌지 않으면 positions·trailOf 는 같은 스냅샷 객체를 돌려준다', () {
    fakeAsync((clock) {
      for (final removal in ['location-stopped', 'member-left']) {
        final f = _Fixture.create(clock);
        final trail = List.generate(7200, (seq) => _fix('alice', seq));
        f.open(positions: [trail.last]);
        f.startSharing();
        _finish(clock, f.session.startFollowing('alice'));
        f.event(TrailUpdated('alice', trail, revision: 1));
        final positions = f.session.positions;
        final snapshot = f.session.trailOf('alice');
        expect(snapshot, hasLength(7200));
        expect(f.session.positions, same(positions));
        expect(f.session.trailOf('alice'), same(snapshot));
        expect(f.session.trailOf(null), same(const <LocationFix>[]));
        expect(f.session.trailOf('missing'), same(const <LocationFix>[]));
        expect(() => positions.clear(), throwsUnsupportedError);
        expect(() => snapshot.add(trail.last), throwsUnsupportedError);

        var notifications = 0;
        f.session.addListener(() => notifications++);
        for (var i = 0; i < 20; i++) {
          f.media.remoteSpeaking!('alice', i.isEven);
          expect(f.session.positions, same(positions));
          expect(f.session.trailOf('alice'), same(snapshot));
        }
        expect(notifications, 20);
        f.event(LocationUpdated(_fix('alice', 7199)));
        f.event(LocationUpdated(_fix('alice', 7198)));
        expect(notifications, 20);
        expect(f.session.positions, same(positions));
        expect(f.session.trailOf('alice'), same(snapshot));

        f.event(
          TrailUpdated(
            'alice',
            List.generate(7200, (seq) => _fix('alice', seq)),
            revision: 1,
          ),
        );
        expect(f.session.positions, same(positions));
        expect(f.session.trailOf('alice'), same(snapshot));
        f.event(
          Hello(
            'bob',
            f.api.members,
            'alice',
            [_fix('alice', 7199)],
            {'alice': List.generate(7200, (seq) => _fix('alice', seq))},
            'alice',
            const [],
            1,
            null,
            'alice-request',
          ),
        );
        expect(f.session.positions, same(positions));
        expect(f.session.trailOf('alice'), same(snapshot));

        final next = _fix('alice', 7200);
        f.event(LocationUpdated(next));
        expect(f.session.positions, isNot(same(positions)));
        expect(f.session.trailOf('alice'), isNot(same(snapshot)));
        expect(f.session.positions['alice'], next);
        expect(f.session.trailOf('alice'), hasLength(7200));
        expect(f.session.trailOf('alice').first.seq, 1);
        expect(f.session.trailOf('alice').last, next);
        expect(positions['alice'], trail.last);
        expect(snapshot.first.seq, 0);
        expect(snapshot.last, trail.last);

        if (removal == 'location-stopped') {
          f.event(const LocationStopped('alice', revision: 1));
        } else {
          f.api.members = const [Member('bob', '보비', '2')];
          f.event(const MemberLeft('alice', revision: 1));
        }
        expect(f.session.positions.containsKey('alice'), isFalse);
        expect(f.session.trailOf('alice'), same(const <LocationFix>[]));
        final emptyPositions = f.session.positions;
        f.event(const LocationStopped('alice', revision: 1));
        expect(f.session.positions, same(emptyPositions));
        f.dispose();
      }
    });
  }, timeout: _timeout);

  test('멤버가 퇴장해도 종료 알림은 마지막 스냅샷의 표시 이름을 조회한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.api.members = const [
        Member('alice', '새 앨리스', '1'),
        Member('bob', '보비', '2'),
      ];
      f.event(Hello('bob', f.api.members));
      f.event(
        const MemberUpdated('alice', Avatar(kind: 'mascot-02', version: 1)),
      );
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      f.api.members = const [Member('bob', '보비', '2')];
      f.event(const MemberLeft('alice', revision: 2));
      expect(
        f.session.state.members.any((member) => member.handle == 'alice'),
        isFalse,
        reason: '퇴장한 상대는 현재 멤버 명단에 없어야 한다',
      );
      final notice = f.session.takeFollowNotice();
      expect(
        notice?.reason,
        'left',
        reason: '실제 member-left 경로로 종료 알림이 생성되어야 한다',
      );
      expect(
        f.session.displayNameOf(notice!.target),
        '새 앨리스',
        reason: 'hello와 member-updated 뒤의 표시 이름을 퇴장 후에도 보존한다',
      );
      expect(
        f.session.displayNameOf('unknown'),
        'unknown',
        reason: '어느 경로에서도 모르는 이름만 handle로 대체한다',
      );
      f.dispose();
    });
  }, timeout: _timeout);

  test('hello 의 따라가기 요청 이름은 명단에서 빠져도 보존한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.event(
        Hello('bob', f.api.members, 'alice', const [], const {}, null, const [
          FollowRequest(
            'request-only',
            requestId: 'snapshot',
            displayName: '요청 이름',
          ),
        ]),
      );
      f.event(Hello('bob', const []));
      expect(
        f.session.displayNameOf('alice'),
        '앨리스',
        reason: '새 hello에서 멤버가 사라져도 이전 이름을 유지한다',
      );
      expect(
        f.session.displayNameOf('request-only'),
        '요청 이름',
        reason: 'hello에서 요청이 사라져도 표시 이름 캐시는 유지한다',
      );
      f.dispose();
    });
  }, timeout: _timeout);

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
      f.startSharing();
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
      expect(f.session.trailOf('alice'), isEmpty);
      f.dispose();
    });
  });

  test('location-stopped·member-left는 종료된 대상 위치와 궤적을 지운다', () {
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
      expect(f.session.trailOf('alice'), isEmpty);
      expect(notifications, 1);
      f.event(const LocationStopped('alice'));
      expect(notifications, 1);
      f.api.members = [const Member('alice', '앨리스', '1')];
      f.event(const MemberLeft('bob'));
      expect(f.session.positions, isEmpty);
      expect(f.session.leaderHandle, 'alice');
      expect(f.session.trailOf('alice'), isEmpty);
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

  for (final restricted in [false, true]) {
    for (final motion in LocationMotionState.values) {
      test('차량 주행 제한 $restricted·GPS $motion은 주행 제한만으로 시작을 판정한다', () {
        fakeAsync((clock) {
          final f = _Fixture.create(clock, mode: DeviceMode.car);
          f.open();
          f.startSharing();
          if (motion == LocationMotionState.moving) f.sample(speed: 3);
          if (motion == LocationMotionState.stationary) {
            for (var second = 0; second <= 3; second++) {
              if (second > 0) clock.elapse(const Duration(seconds: 1));
              f.sample(speed: 0);
            }
          }
          expect(f.session.locationShare.motionState, motion);
          f.drive(restricted);
          expect(f.session.followNeedsStop, restricted);
          expect(f.session.checkFollowAllowed('alice'), !restricted);
          _finish(clock, f.session.startFollowing('alice'));
          expect(f.api.follows, restricted ? isEmpty : ['alice']);
          expect(f.session.followTarget, restricted ? isNull : 'alice');
          expect(
            f.session.followError,
            restricted ? '정차 후 설정할 수 있습니다' : isNull,
          );
          expect(f.session.locationShare.sharing, isTrue);
          if (restricted) {
            f.drive(false);
            _finish(clock, f.session.startFollowing('alice'));
            expect(f.session.followTarget, 'alice');
            expect(f.session.followError, isNull);
          }
          f.dispose();
        });
      }, timeout: _timeout);
    }
  }

  test('동의·공유 시작 사이 주행 제한이 켜지면 follow POST를 거부한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock, mode: DeviceMode.car);
      f.open();
      f.drive(false);
      expect(f.session.checkFollowAllowed('alice'), isTrue);
      f.startSharing();
      f.drive(true);
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.api.follows, isEmpty);
      expect(f.session.followTarget, isNull);
      expect(f.session.followError, '정차 후 설정할 수 있습니다');
      expect(f.session.locationShare.sharing, isTrue);
      f.dispose();
    });
  }, timeout: _timeout);

  for (final failure in ['unavailable', 'invalid', 'error', 'done']) {
    test('차량 주행 상태 $failure는 화면 잠금처럼 제한을 해제하고 GPS moving도 허용한다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock, mode: DeviceMode.car);
        f.open();
        f.startSharing();
        f.sample(speed: 3);
        f.drive(true);
        switch (failure) {
          case 'unavailable':
            f.drivingEvents.add({'restricted': true, 'available': false});
          case 'invalid':
            f.drivingEvents.add('invalid');
          case 'error':
            f.drivingEvents.addError(StateError('unavailable'));
          case 'done':
            _finish(clock, f.drivingEvents.close());
        }
        clock.flushMicrotasks();
        expect(f.driving.available, isFalse);
        expect(f.driving.restricted, isFalse);
        expect(f.session.followNeedsStop, isFalse);
        _finish(clock, f.session.startFollowing('alice'));
        expect(f.session.followTarget, 'alice');
        f.dispose();
      });
    }, timeout: _timeout);
  }

  for (final pendingPost in [false, true]) {
    test('첫 GPS moving 표본은 시작한 follow를 취소하지 않는다 (POST 대기 $pendingPost)', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock, mode: DeviceMode.car);
        f.open();
        f.startSharing();
        final gate = Completer<void>();
        if (pendingPost) f.api.followGate = gate.future;
        final following = f.session.startFollowing('alice');
        clock.flushMicrotasks();
        f.sample(speed: 3);
        expect(f.session.followIntent, 'alice');
        expect(f.session.followError, isNull);
        gate.complete();
        _finish(clock, following);
        f.drive(true);
        f.sample(speed: 5);
        expect(f.session.followTarget, 'alice');
        expect(f.session.locationShare.sharing, isTrue);
        expect(f.api.unfollows, 0);
        _finish(clock, f.session.stopFollowing());
        expect(f.session.followTarget, isNull);
        expect(f.api.unfollows, 1);
        f.dispose();
      });
    }, timeout: _timeout);
  }

  test('폰은 정차 제한이 없고 그룹장 자신은 no-op이다', () {
    fakeAsync((clock) {
      final phone = _Fixture.create(clock);
      phone.open();
      phone.drive(true);
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
      expect(f.session.trailOf('alice'), isEmpty);
      clock.elapse(const Duration(seconds: 1));
      f.sample(lat: 37.001);
      expect(f.session.trailOf('alice'), isEmpty);
      _finish(clock, f.session.locationShare.stop());
      expect(f.session.positions, isEmpty);
      expect(f.session.trailOf('alice'), isEmpty);
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
      f.event(TrailUpdated('bob', [_fix('bob', 0)], revision: 1));
      f.event(LocationUpdated(_fix('bob', 1)));
      expect(f.session.trailOf('bob').map((fix) => fix.seq), [0, 1]);
      expect(f.session.trailOf('charlie'), isEmpty);
      _finish(clock, f.session.startFollowing('charlie'));
      f.event(
        const FollowResponse('bob', false, requestId: 'bob-request'),
      ); // 이전 대상의 늦은 응답
      expect(f.session.followTarget, 'charlie');
      f.event(
        const FollowResponse('charlie', false, requestId: 'charlie-request'),
      );
      expect(f.session.followTarget, isNull);
      expect(f.session.takeFollowNotice()?.target, 'charlie');
      expect(f.session.locationShare.sharing, isTrue);
      f.event(const LocationStopped('charlie'));
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
      f.event(const FollowResponse('alice', true, requestId: 'alice-request'));
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
        f.event(
          const FollowRequest(
            'request-only',
            requestId: 'request-name',
            displayName: '요청 이름',
            revision: 2,
          ),
        );
        expect(
          f.session.displayNameOf('alice'),
          '앨리스',
          reason: '퇴장 전에는 멤버 이름을 알고 있다',
        );
        expect(
          f.session.displayNameOf('request-only'),
          '요청 이름',
          reason: '퇴장 전에는 요청에서 받은 이름을 알고 있다',
        );
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
        for (final handle in ['alice', 'request-only']) {
          expect(
            f.session.displayNameOf(handle),
            handle,
            reason: '$action 뒤에는 어떤 출처의 이름도 다음 방으로 넘어가지 않는다',
          );
        }
        expect(f.source.watches, 1);
        if (action == 'leave') expect(f.api.leaves, 1);
        f.dispose();
      });
    });
  }
  for (final action in ['leave', 'forget']) {
    test('R2 $action는 위치 POST 완료 전에 미디어와 통화 서비스를 종료한다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock);
        f.open();
        f.startSharing();
        final gate = Completer<void>();
        f.http.sendGate = gate.future;
        f.sample();
        final mediaLeaves = f.media.leaves;
        final callStops = f.calls.stops;
        final leaving = action == 'leave'
            ? f.session.leave()
            : f.session.forget();
        clock.flushMicrotasks();
        expect(f.media.leaves, mediaLeaves + 1);
        expect(f.calls.stops, callStops + 1);
        expect(f.session.mediaConnection, MediaConnectionState.idle);
        expect(f.session.state.isLeaving, isTrue);
        expect(f.http.deletes, isEmpty);
        gate.complete();
        _finish(clock, leaving);
        expect(f.http.deletes, hasLength(1));
        f.dispose();
      });
    });
  }

  test('C5 오래된 hello→SSE 수락→POST 완료 순서와 수락 A→B 전환을 조정한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.api.members = [...f.api.members, const Member('charlie', '찰리', '3')];
      f.open();
      f.startSharing();
      _finish(clock, f.session.startFollowing('alice'));
      final gate = Completer<void>();
      f.api.followGate = gate.future;
      f.api.followResult = const FollowResult('b-new', 5, false);
      final pending = f.session.startFollowing('charlie');
      clock.flushMicrotasks();
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          'alice',
          const [],
          2,
          null,
          'alice-request',
        ),
      );
      expect(f.session.pendingFollow, 'charlie');
      expect(f.session.followTarget, isNull);
      f.event(
        const FollowResponse('charlie', true, requestId: 'b-new', revision: 6),
      );
      gate.complete();
      _finish(clock, pending);
      expect(f.session.followTarget, 'charlie');
      expect(f.session.followRequestId, 'b-new');
      expect(f.session.followServerRevision, 6);
      f.event(const LocationStopped('charlie', revision: 4));
      expect(f.session.followTarget, 'charlie');
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          'alice',
          const [],
          4,
          null,
          'alice-request',
        ),
      );
      expect(f.session.followTarget, 'charlie');
      f.event(
        const FollowResponse('charlie', false, requestId: 'b-old', revision: 7),
      );
      expect(f.session.followTarget, 'charlie');
      f.dispose();
    });
  });

  test('C4 hello는 수락·pending·수신 요청을 복원하되 새 실행은 공유를 켜지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      final hello = Hello(
        'bob',
        f.api.members,
        'alice',
        [_fix('alice', 0)],
        const {},
        null,
        const [
          FollowRequest('alice', requestId: 'incoming', displayName: '앨리스'),
        ],
        3,
        'alice',
        'pending-id',
      );
      f.event(hello);
      expect(f.session.locationShare.sharing, isFalse);
      expect(f.session.pendingFollow, isNull);
      expect(f.source.requests, 0);
      expect(f.session.followRequests.keys, ['incoming']);
      f.startSharing();
      f.event(hello);
      expect(f.session.pendingFollow, 'alice');
      expect(f.session.followTarget, isNull);
      expect(f.session.followRequestId, 'pending-id');
      f.event(
        Hello(
          'bob',
          f.api.members,
          'alice',
          const [],
          const {},
          'alice',
          const [],
          4,
          null,
          'pending-id',
        ),
      );
      expect(f.session.followTarget, 'alice');
      expect(f.session.pendingFollow, isNull);
      f.dispose();
    });
  });

  test('C6 알려지지 않은 requester를 보관하고 refresh 중 취소를 즉시 반영한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      final gate = Completer<void>();
      f.api.roomGate = gate.future;
      f.event(
        const FollowRequest(
          'charlie',
          requestId: 'unknown-request',
          displayName: '이벤트 이름',
          revision: 1,
        ),
      );
      expect(
        f.session.followRequests['unknown-request']?.displayName,
        '이벤트 이름',
      );
      expect(f.session.readyFollowRequests, isEmpty);
      expect(
        f.session.displayNameOf('charlie'),
        '이벤트 이름',
        reason: '멤버 조회 대기 중에도 따라가기 요청의 이름을 기억한다',
      );
      f.event(
        const FollowCancelled(
          'charlie',
          requestId: 'unknown-request',
          revision: 2,
        ),
      );
      expect(f.session.followRequests, isEmpty);
      f.api.members = [...f.api.members, const Member('charlie', '찰리', '3')];
      gate.complete();
      clock.flushMicrotasks();
      expect(f.session.readyFollowRequests, isEmpty);
      expect(
        f.session.displayNameOf('charlie'),
        '찰리',
        reason: '현재 멤버 표시 이름은 요청 캐시보다 우선한다',
      );
      f.event(
        const FollowRequest(
          'charlie',
          requestId: 'new-request',
          displayName: '이벤트 이름',
          revision: 3,
        ),
      );
      expect(f.session.readyFollowRequests.single.requestId, 'new-request');
      expect(
        f.session.displayNameOf('charlie'),
        '찰리',
        reason: '요청으로 캐시가 갱신되어도 members 조회가 우선이다',
      );
      f.dispose();
    });
  });

  for (final cancelledBy in ['cancel', 'left', 'room']) {
    test('C2 권한 대기 중 $cancelledBy는 요청 토큰을 무효화한다', () {
      fakeAsync((clock) {
        final f = _Fixture.create(clock, handle: 'alice');
        f.open();
        f.event(const FollowRequest('bob', requestId: 'req', revision: 1));
        final token = f.session.beginLocationStart('bob', requestId: 'req');
        f.source.pendingPermission = Completer<LocationPermissionState>();
        final start = f.session.locationShare.start(
          token: token,
          stillValid: () => f.session.locationStartValid(token),
        );
        clock.flushMicrotasks();
        switch (cancelledBy) {
          case 'cancel':
            f.event(
              const FollowCancelled('bob', requestId: 'req', revision: 2),
            );
          case 'left':
            f.event(const MemberLeft('bob'));
          case 'room':
            f.session.state = const RoomState(code: 'NEW123');
        }
        f.source.pendingPermission!.complete(LocationPermissionState.granted);
        _finish(clock, start);
        expect(f.session.locationShare.sharing, isFalse);
        expect(f.source.watches, 0);
        expect(f.http.posts, isEmpty);
        f.dispose();
      });
    });
  }

  test('C2 수락 전 outbound 토큰은 새 공유를 정리하고 기존 공유는 유지한다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.open();
      f.api.accepted = false;
      final token = f.session.beginLocationStart('alice');
      _finish(
        clock,
        f.session.locationShare.start(
          token: token,
          stillValid: () => f.session.locationStartValid(token),
        ),
      );
      _finish(clock, f.session.startFollowing('alice'));
      expect(f.session.pendingFollow, 'alice');
      f.event(const MemberLeft('alice'));
      expect(f.session.locationShare.sharing, isFalse);
      expect(f.source.cancellations, 1);
      f.startSharing();
      final existingToken = f.session.beginLocationStart('alice');
      _finish(
        clock,
        f.session.locationShare.start(
          token: existingToken,
          stillValid: () => true,
        ),
      );
      f.session.cancelLocationStart(existingToken);
      expect(f.session.locationShare.sharing, isTrue);
      f.dispose();
    });
  });
  test('C5 pending 대상 전환은 이전 토큰의 늦은 무효화로 기존 공유를 끄지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture.create(clock);
      f.api.members = [...f.api.members, const Member('charlie', '찰리', '3')];
      f.api.accepted = false;
      f.open();
      final first = f.session.beginLocationStart('alice');
      _finish(
        clock,
        f.session.locationShare.start(
          token: first,
          stillValid: () => f.session.locationStartValid(first),
        ),
      );
      _finish(clock, f.session.startFollowing('alice'));
      final next = f.session.beginLocationStart('charlie');
      _finish(
        clock,
        f.session.locationShare.start(
          token: next,
          stillValid: () => f.session.locationStartValid(next),
        ),
      );
      _finish(clock, f.session.startFollowing('charlie'));
      f.sample();
      expect(f.session.pendingFollow, 'charlie');
      expect(f.session.locationShare.sharing, isTrue);
      expect(f.source.watches, 1);
      expect(f.source.cancellations, 0);
      f.event(
        const FollowResponse(
          'alice',
          false,
          requestId: 'alice-request',
          revision: 3,
        ),
      );
      expect(f.session.pendingFollow, 'charlie');
      expect(f.session.locationShare.sharing, isTrue);
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
  _Fixture(
    this.clock,
    this.store,
    DeviceMode mode,
    FollowSpeechOutput? speech,
  ) {
    api = _Api(store, http);
    mic = MicRouter(store);
    unawaited(drivingEvents.done);
    driving = DrivingState(mode: mode, events: drivingEvents.stream);
    session = RoomSession(
      api: api,
      mediaEngine: media,
      store: store,
      callService: calls,
      micRouter: mic,
      deviceMode: mode,
      driving: driving,
      locationSource: source,
      locationNow: now,
      followVoice: speech == null
          ? null
          : FollowVoiceGuidance(
              enabled: () => mode == DeviceMode.car,
              output: speech,
              now: now,
            ),
    );
  }
  static _Fixture create(
    FakeAsync clock, {
    String handle = 'bob',
    DeviceMode mode = DeviceMode.phone,
    FollowSpeechOutput? speech,
  }) {
    SharedPreferences.setMockInitialValues({'token': 'test', 'handle': handle});
    return _Fixture(
      clock,
      SessionStore(_finish(clock, SharedPreferences.getInstance())),
      mode,
      speech,
    );
  }

  final FakeAsync clock;
  final SessionStore store;
  final http = FakeLocationHttp();
  final source = FakeLocationSource();
  final calls = _Calls();
  final media = _Media();
  late final _Api api;
  late final MicRouter mic;
  late final RoomSession session;
  final drivingEvents = StreamController<Object?>.broadcast(sync: true);
  late final DrivingState driving;

  void drive(bool restricted) {
    drivingEvents.add({'restricted': restricted, 'available': true});
    clock.flushMicrotasks();
  }

  DateTime now() => DateTime.utc(2026).add(clock.elapsed);
  void open({
    List<LocationFix> positions = const [],
    List<LocationFix> trail = const [],
  }) {
    _finish(clock, session.open('ABC123'));
    _finish(clock, session.leaveCall()); // 위치 테스트에서는 자동 통화를 시작하지 않는다.
    if (trail.isNotEmpty) startSharing();
    event(
      Hello(store.handle!, api.members, 'alice', positions, {'alice': trail}),
    );
  }

  void event(RoomEvent event) {
    api.events.add(event);
    clock.flushMicrotasks();
  }

  void startSharing() {
    _finish(
      clock,
      session.locationShare.start(token: Object(), stillValid: () => true),
    );
  }

  void sample({double lat = 37, double speed = 2}) {
    source.add(LocationSample(lat: lat, lng: 127, speed: speed, at: now()));
    clock.flushMicrotasks();
  }

  void dispose() {
    _finish(clock, session.locationShare.stop());
    session.dispose();
    driving.dispose();
    _finish(clock, drivingEvents.close());
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

class _FollowSpeech implements FollowSpeechOutput {
  final texts = <String>[];
  int stops = 0;
  @override
  Future<void> speak(String text, DateTime expiresAt) async {
    texts.add(text);
  }

  @override
  Future<void> stop() async {
    stops++;
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
  Future<void>? stopGate, responseGate;
  int unfollows = 0;
  @override
  Future<FollowResult> follow(String code, String target) async {
    follows.add(target);
    final result = FollowResult('$target-request', ++revision, accepted);
    await followGate;
    return followResult ?? result;
  }

  int revision = 0;
  bool accepted = true;
  FollowResult? followResult;
  Future<void>? roomGate;
  Future<RoomDetails> Function()? roomRead;
  bool roomFails = false;

  @override
  Future<Room> joinRoom(String code) async => Room(code, null);

  @override
  Future<int> respondFollow(
    String code,
    String requestId, {
    required bool accepted,
  }) async {
    final result = ++revision;
    await responseGate;
    return result;
  }

  @override
  Future<int> stopFollowing(String code) async {
    unfollows++;
    final result = ++revision;
    await stopGate;
    return result;
  }

  int leaves = 0;
  bool leaveFails = false;
  @override
  Future<void> close() {
    super.close();
    return events.close();
  }

  @override
  Future<RoomDetails> getRoom(String code) async {
    if (roomRead != null) return roomRead!();
    await roomGate;
    if (roomFails) throw const ApiException(503, 'unavailable', '조회 실패');
    return RoomDetails(Room(code, null, leader: 'alice'), members);
  }

  @override
  Stream<RoomEvent> subscribeEvents(String code) => events.stream;
  @override
  Future<void> leaveRoom(String code) async {
    leaves++;
    if (leaveFails) throw const ApiException(503, 'unavailable', '퇴장 실패');
  }
}

class _TrackedClient implements HttpClient {
  _TrackedClient(this.delegate, this.onClose);
  final HttpClient delegate;
  final void Function() onClose;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      delegate.openUrl(method, url);
  @override
  void close({bool force = false}) {
    onClose();
    delegate.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Calls extends CallService {
  int stops = 0;
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  bool get supported => false;
}

class _Media extends NoopMediaEngine {
  int leaves = 0;
  final memberUpdates = <List<String>>[];
  @override
  Future<void> setMembers(List<String> members) async {
    memberUpdates.add(List.of(members));
  }

  @override
  Future<void> leave() async {
    leaves++;
  }
}
