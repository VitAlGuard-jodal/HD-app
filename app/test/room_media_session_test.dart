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

  test('레벨·RMS·dBFS만 바뀌면 첫 이벤트부터 RoomSession 알림은 0회다', () async {
    final f = await _Fixture.create();
    try {
      var roomNotifications = 0;
      var levelNotifications = 0;
      f.session.addListener(() => roomNotifications++);
      f.mic.addListener(() => levelNotifications++);
      for (var tick = 1; tick <= 10; tick++) {
        f.mic.state = MicState(
          level: tick / 10,
          rms: tick * 100,
          dbfs: -60.0 + tick,
        );
        f.mic.changed();
      }
      expect(roomNotifications, 0);
      expect(levelNotifications, 10);
      expect(f.mic.state.level, 1);
      expect(f.mic.state.rms, 1000);
      expect(f.mic.state.dbfs, -50);
    } finally {
      await f.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('동일한 장치 맵의 미리보기 레벨은 건너뛰고 선택·출력·인터럽션 변경은 알린다', () async {
    final f = await _Fixture.create();
    MicState frame({int selectedId = 1, double level = 0}) => MicState.fromMap({
      'mode': 'phone',
      'devices': [
        {'id': 1, 'type': 15, 'name': '내장', 'webrtcDeviceId': 'built-in'},
        {'id': 2, 'type': 7, 'name': '헤드셋', 'webrtcDeviceId': 'bluetooth'},
      ],
      'selected': selectedId == 1
          ? {'id': 1, 'type': 15, 'name': '내장', 'webrtcDeviceId': 'built-in'}
          : {'id': 2, 'type': 7, 'name': '헤드셋', 'webrtcDeviceId': 'bluetooth'},
      'isRecording': true,
      'isPreviewing': true,
      'level': level,
      'rms': (level * 1000).round(),
      'dbfs': -60 + level * 60,
    });
    try {
      f.mic.state = frame();
      f.mic.changed();
      var notifications = 0;
      f.session.addListener(() => notifications++);
      for (var tick = 1; tick <= 10; tick++) {
        // 네이티브 이벤트마다 MicDevice/List 객체가 새로 만들어지는 경로.
        f.mic.state = frame(level: tick / 10);
        f.mic.changed();
      }
      expect(notifications, 0);
      f.mic.state = frame(selectedId: 2);
      f.mic.changed();
      expect(notifications, 1);
      f.mic.state = frame(selectedId: 2, level: .5);
      f.mic.changed();
      expect(notifications, 1);
      f.mic.availableOutputRoutes = [
        OutputRoute.bluetooth,
        OutputRoute.speaker,
        OutputRoute.receiver,
      ];
      f.mic.changed();
      expect(notifications, 2);
      f.mic.availableOutputRoutes = List.of(f.mic.availableOutputRoutes);
      f.mic.changed();
      expect(notifications, 2);
      f.mic.outputRoute = OutputRoute.receiver;
      f.mic.changed();
      expect(notifications, 3);
      expect(f.session.speakerphone, isFalse);
      expect(f.session.outputLabel, startsWith('현재 수화부.'));
      f.mic.audioInterrupted = true;
      f.mic.changed();
      expect(notifications, 4);
      expect(f.media.interrupted, isTrue);
      f.mic.changed();
      expect(notifications, 4);
      f.mic.audioInterrupted = false;
      f.mic.changed();
      expect(notifications, 5);
      expect(f.media.interrupted, isFalse);
      f.mic.outputError = '선택한 출력 장치가 연결되어 있지 않습니다.';
      f.mic.changed();
      expect(notifications, 6);
    } finally {
      await f.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('새 기동은 me만 읽고 restorableRoom만 채우며 통화를 시작하지 않는다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.api.currentRoom = const Room('ABC123', '이전 방');
      _microtasksOnly(clock, f.restore());
      expect(f.store.displayName, '새 이름');
      expect(f.session.restorableRoom?.code, 'ABC123');
      expect(f.session.restorableRoom?.name, '이전 방');
      expect(f.session.state.code, isNull);
      expect(f.api.roomReads, 0);
      expect(f.api.subscriptions, 0);
      expect(f.api.joins, 0);
      clock.elapse(const Duration(minutes: 1));
      expect(f.calls.starts, 0);
      expect(f.media.joins, 0);
      expect(clock.pendingTimers, isEmpty);
      // Only an explicit card action opens the room and enables hello auto-call.
      _microtasksOnly(clock, f.session.open(f.session.restorableRoom!.code));
      expect(f.session.restorableRoom, isNull);
      expect(f.calls.starts, 0);
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.media.joins, 1);
      expect(f.calls.starts, 1);
      _microtasksOnly(clock, f.session.leave());
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('새 기동: me에 방이 없으면 복귀 카드·세션·통화 모두 비어 있다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.session.setRestorableRoom(const Room('OLD123', null));
      _microtasksOnly(clock, f.restore());
      expect(f.session.restorableRoom, isNull);
      expect(f.session.state.code, isNull);
      expect(f.api.roomReads, 0);
      expect(f.api.subscriptions, 0);
      expect(f.calls.starts, 0);
      expect(f.media.joins, 0);
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('새 기동: me 네트워크 오류는 저장된 로그인 정보를 유지한다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.api.meError = TimeoutException('offline');
      _microtasksOnly(clock, f.restore());
      expect(f.store.token, 'test');
      expect(f.session.state.code, isNull);
      expect(f.session.restorableRoom, isNull);
      expect(f.api.subscriptions, 0);
      expect(f.calls.starts, 0);
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('새 기동: me 401은 복귀 정보와 로그인 상태를 정리한다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      f.session.setRestorableRoom(const Room('ABC123', null));
      f.api.meError = const ApiException(401, 'expired', '토큰 만료');
      _microtasksOnly(clock, f.restore());
      expect(f.store.token, isNull);
      expect(f.session.restorableRoom, isNull);
      expect(f.session.state.code, isNull);
      expect(f.media.joins, 0);
      expect(clock.pendingTimers, isEmpty);
      _microtasksOnly(clock, f.dispose());
    });
  });

  for (final status in [401, 403, 404]) {
    for (final stage in ['room', 'events', 'call']) {
      test('복귀 카드로 입장한 뒤 $stage $status는 방과 재시도를 정리한다', () {
        fakeAsync((clock) {
          final f = _microtasksOnly(clock, _Fixture.create());
          f.api.currentRoom = const Room('ABC123', null);
          _microtasksOnly(clock, f.restore());
          final error = ApiException(status, 'gone', '접근할 수 없음');
          if (stage == 'room') f.api.roomError = error;
          _microtasksOnly(clock, f.session.open('ABC123'));
          if (stage == 'events') f.api.events.addError(error);
          if (stage == 'call') {
            f.api.roomError = error;
            f.api.events.add(Hello('alice', f.api.members));
          }
          clock.flushMicrotasks();
          expect(f.session.state.code, isNull);
          expect(f.session.restorableRoom, isNull);
          expect(f.session.state.error, isNull);
          expect(f.calls.starts, 0);
          expect(f.media.joins, 0);
          expect(f.store.token, status == 401 ? null : 'test');
          expect(clock.pendingTimers, isEmpty);
          _microtasksOnly(clock, f.dispose());
        });
      });
    }
  }

  test('새 기동: me 응답 전 다른 방이 열렸으면 그 세션을 덮어쓰지 않는다', () {
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
      expect(f.session.restorableRoom, isNull);
      expect(f.api.roomReads, reads);
      expect(f.api.subscriptions, 1);
      _microtasksOnly(clock, f.session.leave());
      _microtasksOnly(clock, f.dispose());
    });
  });

  test('새 기동: me 응답 전 로그아웃하면 오래된 응답을 버린다', () {
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
      expect(f.session.restorableRoom, isNull);
      expect(f.api.subscriptions, 0);
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

  test('로컬 발화는 바뀔 때만 알리고 음소거 중 콜백을 무시한다', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    await f.open();
    var notifications = 0;
    f.session.addListener(() => notifications++);
    expect(f.session.localSpeaking, isFalse);
    f.media.speakLocally(false);
    expect(notifications, 0);
    f.media.speakLocally(true);
    expect(f.session.localSpeaking, isTrue);
    expect(notifications, 1);
    f.media.speakLocally(true);
    expect(notifications, 1);
    f.media.speakLocally(false);
    expect(f.session.localSpeaking, isFalse);
    expect(notifications, 2);
    f.media.speakLocally(true);
    f.session.setMuted(true);
    expect(f.session.localSpeaking, isFalse);
    final mutedNotifications = notifications;
    f.media.speakLocally(true);
    f.media.speakLocally(false);
    expect(f.session.localSpeaking, isFalse);
    expect(notifications, mutedNotifications);
    f.session.setMuted(false);
    expect(f.session.localSpeaking, isFalse);
    f.media.speakLocally(true);
    expect(f.session.localSpeaking, isTrue);
  });

  for (final leaveRoom in [false, true]) {
    test('${leaveRoom ? '방 나가기' : '통화 종료'}는 로컬 발화를 초기화한다', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      await f.open();
      f.media.speakLocally(true);
      expect(f.session.localSpeaking, isTrue);
      if (leaveRoom) {
        await f.session.leave();
        expect(f.session.state.code, isNull);
      } else {
        final stopping = f.session.leaveCall();
        expect(f.session.localSpeaking, isFalse);
        await stopping;
        expect(f.session.state.code, 'ABC123');
      }
      expect(f.session.localSpeaking, isFalse);
      f.media.speakLocally(true);
      expect(f.session.localSpeaking, isFalse);
    });
  }

  test('정원 초과로 메시를 해제하면 네이티브 통화가 남아도 로컬 발화는 꺼진다', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    await f.open();
    f.media.speakLocally(true);
    f.api.members = [
      for (final name in ['bob', 'charlie', 'david', 'eve', 'alice'])
        Member(name, name, ''),
    ];
    f.api.events.add(Hello('alice', f.api.members));
    await Future<void>.delayed(Duration.zero);
    expect(f.media.leaves, 1);
    expect(f.calls.state.isActive, isTrue);
    expect(f.session.localSpeaking, isFalse);
    expect(f.session.mediaError, meshCapacityReason);
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
    expect(f.media.reconciliations, [
      ['alice', 'bob'],
    ]);
    await f.dispose();
  });

  test('터널 복귀 Reconnected·Hello는 기존 통화를 유지하며 피어만 reconcile한다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      _microtasksOnly(clock, f.session.open('ABC123'));
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.media.reconciliations, isEmpty);
      f.api.events.add(const Disconnected('연결을 다시 시도합니다.', 2000));
      f.api.events.add(const Reconnected());
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.api.joins, 1);
      expect(f.media.reconciliations, [
        ['alice', 'bob'],
        ['alice', 'bob'],
      ]);
      expect(f.media.joins, 1);
      expect(f.media.leaves, 0);
      expect(f.session.state.isConnected, isTrue);
      _microtasksOnly(clock, f.session.leaveCall());
      f.api.events.add(const Reconnected());
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      expect(f.media.reconciliations, hasLength(2));
      expect(f.media.joins, 1); // Explicitly ended calls stay ended.
      _microtasksOnly(clock, f.session.leave());
      _microtasksOnly(clock, f.dispose());
    });
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

  test('모든 피어의 종단 실패가 반복되어도 leave·join 재참여는 한 번이다', () {
    fakeAsync((clock) {
      final f = _microtasksOnly(clock, _Fixture.create());
      _microtasksOnly(clock, f.session.open('ABC123'));
      f.api.events.add(Hello('alice', f.api.members));
      clock.flushMicrotasks();
      for (var i = 0; i < 3; i++) {
        f.media.changePeers({
          'bob': MeshPeerState.failed,
          'charlie': MeshPeerState.failed,
        });
      }
      expect(f.session.mediaConnection, MediaConnectionState.failed);
      expect(clock.nonPeriodicTimerCount, 1);
      clock.elapse(const Duration(seconds: 1));
      expect(f.media.leaves, 1);
      expect(f.media.joins, 2);
      expect(f.calls.starts, 1);
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      clock.elapse(const Duration(seconds: 30));
      expect(f.media.joins, 2);
      _microtasksOnly(clock, f.session.leave());
      _microtasksOnly(clock, f.dispose());
    });
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

  test('저장된 200%와 범위 밖 변경은 세션·저장소·엔진 전달에서 0~100%로 제한한다', () async {
    final f = await _Fixture.create(volume: 200);
    expect(f.store.callVolume, 100);
    expect(f.session.callVolume, 100);
    await f.open();
    expect(f.media.volume, 1);
    await f.session.setCallVolume(200);
    expect(f.session.callVolume, 100);
    expect(f.media.volume, 1);
    expect(f.store.preferences.getInt('callVolume'), 100);
    await f.session.setCallVolume(-1);
    expect(f.session.callVolume, 0);
    expect(f.media.volume, 0);
    expect(f.store.preferences.getInt('callVolume'), 0);
    await f.store.setCallVolume(200);
    expect(f.store.preferences.getInt('callVolume'), 100);
    await f.store.setCallVolume(-1);
    expect(f.store.callVolume, 0);
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
  final reconciliations = <List<String>>[];
  bool failJoin = false, muted = false, interrupted = false;
  int joins = 0, leaves = 0;
  double volume = 1;
  void speakLocally(bool speaking) => localSpeaking?.call(speaking);

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
  Future<void> reconcilePeers(List<String> handles) async {
    reconciliations.add(List.of(handles));
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
