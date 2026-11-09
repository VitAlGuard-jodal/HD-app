import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/call/mesh_coordinator.dart';
import 'package:unavo/call/webrtc_media_engine.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';

void main() {
  testWidgets('UNAVO_STATS_LOG는 기존 폴링으로 5초마다 한 줄 통계와 증가분을 기록한다', (
    tester,
  ) async {
    const enabled = bool.fromEnvironment('UNAVO_STATS_LOG');
    final f = await _Fixture.create(tester);
    final lines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null && message.startsWith('[stats] ')) lines.add(message);
    };
    Future<void> poll(int count) async {
      for (var i = 0; i < count; i++) {
        await tester.pump(remoteSpeakingInterval);
      }
    }

    final inbound = StatsReport('in-audio', 'inbound-rtp', 0, {
      'mediaType': 'audio',
      'packetsReceived': 180,
      'packetsLost': 2,
      'jitter': 0.006,
      'concealedSamples': 480,
      'concealmentEvents': 2,
      'removedSamplesForAcceleration': 96,
      'insertedSamplesForDeceleration': 48,
      'jitterBufferDelay': 2.4,
      'jitterBufferEmittedCount': 120,
    });
    f.native.stats = [
      // 먼저 등장한 영상 통계를 오디오 통계로 선택해서는 안 된다.
      for (final type in ['outbound-rtp', 'remote-inbound-rtp', 'inbound-rtp'])
        StatsReport('video-$type', type, 0, {
          'kind': 'video',
          'packetsSent': 999,
          'packetsLost': 999,
        }),
      StatsReport('out-audio', 'outbound-rtp', 0, {
        'kind': 'audio',
        'transportId': 'transport',
        'remoteId': 'remote-audio',
        'packetsSent': 200,
        'bytesSent': 32000,
      }),
      StatsReport('remote-audio', 'remote-inbound-rtp', 0, {
        'kind': 'audio',
        'localId': 'out-audio',
        'packetsLost': 3,
        'fractionLost': 0.015,
        'jitter': '0.004',
      }),
      inbound,
      StatsReport('transport', 'transport', 0, {
        'selectedCandidatePairId': 'pair',
      }),
      // nominated 후보보다 transport가 가리키는 실제 선택 쌍이 우선한다.
      StatsReport('unused-pair', 'candidate-pair', 0, {
        'nominated': true,
        'state': 'succeeded',
        'currentRoundTripTime': 9,
      }),
      StatsReport('pair', 'candidate-pair', 0, {
        'localCandidateId': 'local',
        'remoteCandidateId': 'remote',
        'currentRoundTripTime': 0.042,
      }),
      StatsReport('local', 'local-candidate', 0, {'candidateType': 'srflx'}),
      StatsReport('remote', 'remote-candidate', 0, {'candidateType': 'relay'}),
    ];
    const outgoing =
        '[stats] peer=bob pair=srflx/relay rtt=42.00 '
        'out: sent=200 bytes=32000 remoteLost=3 remoteFrac=0.015 remoteJit=4.00 ';
    const first =
        '${outgoing}in: recv=180 lost=2 jit=6.00 conceal=480 events=2 '
        'accel=96 decel=48 jbDelay=20.00 Δlost=- Δconceal=- Δevents=-';
    const second =
        '${outgoing}in: recv=180 lost=5 jit=6.00 conceal=960 events=3 '
        'accel=96 decel=48 jbDelay=20.00 Δlost=3 Δconceal=480 Δevents=1';
    try {
      await f.open(tester);
      await f.connect(tester);
      await poll(9);
      expect(lines, isEmpty);
      await poll(1);
      expect(lines, enabled ? [first] : <String>[]);
      expect(f.native.statsReads, List.filled(10, 'pc1'));

      // 이전 스냅샷은 보존하고 다음 getStats 응답만 바꾼다.
      f.native.stats[f.native.stats.indexOf(
        inbound,
      )] = StatsReport(inbound.id, inbound.type, 5000, {
        ...inbound.values,
        'packetsLost': 5,
        'concealedSamples': 960,
        'concealmentEvents': 3,
      });
      await poll(9);
      expect(lines, enabled ? [first] : <String>[]);
      await poll(1);
      expect(lines, enabled ? [first, second] : <String>[]);
      expect(f.native.statsReads, List.filled(20, 'pc1'));

      // transport가 없으면 nominated 쌍 사용. 리포트 교체 시 증가분 초기화.
      f.native.stats = [
        StatsReport('fallback', 'candidate-pair', 0, {
          'nominated': true,
          'state': 'succeeded',
          'localCandidateId': 'local',
          'remoteCandidateId': 'remote',
        }),
        StatsReport('local', 'local-candidate', 0, {'candidateType': 'host'}),
        StatsReport('remote', 'remote-candidate', 0, {
          'candidateType': 'relay',
        }),
        StatsReport('new-inbound', 'inbound-rtp', 0, {
          'kind': 'audio',
          'packetsLost': 0,
          'concealedSamples': 0,
          'concealmentEvents': 0,
          'jitter': 'unavailable',
          'jitterBufferDelay': 1,
          'jitterBufferEmittedCount': 0,
        }),
      ];
      await poll(10);
      const missing =
          '[stats] peer=bob pair=host/relay rtt=- '
          'out: sent=- bytes=- remoteLost=- remoteFrac=- remoteJit=- '
          'in: recv=- lost=0 jit=- conceal=0 events=0 '
          'accel=- decel=- jbDelay=- Δlost=- Δconceal=- Δevents=-';
      expect(lines, enabled ? [first, second, missing] : <String>[]);
      expect(f.native.statsReads, List.filled(30, 'pc1'));
    } finally {
      debugPrint = originalDebugPrint;
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('엔진 수신 이득은 직접 2.0을 전달해도 1.0을 넘지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await f.open(tester);
      await f.connect(tester);
      await _complete(tester, f.engine.setVolume(2), '트랙 수신 전 음량');
      await _complete(tester, f.native.track('pc1'), '원격 오디오 트랙 이벤트');
      // onTrack 콜백의 setVolume(invokeMethod) 은 이벤트 전달 뒤 마이크로태스크로 끝난다.
      await tester.pump();
      await tester.pump();
      expect(f.native.volumes, [1]);
      expect(f.native.volumeTargets, ['pc1/remote-audio']);
      // 이미 수신 중인 트랙에도 같은 상한이 적용되어야 한다.
      for (final (input, output) in [(2.0, 1.0), (-1.0, 0.0), (.6, .6)]) {
        await _complete(tester, f.engine.setVolume(input), '수신 음량 $input');
        expect(f.native.volumes.last, output);
      }
      expect(
        f.native.volumes.every((volume) => volume >= 0 && volume <= 1),
        isTrue,
      );
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('TURN 갱신 실패는 연결과 피어를 보존하고 엔진 안에서 재시도한다', (tester) async {
    final f = await _Fixture.create(tester, ttl: 10);
    try {
      await f.open(tester);
      await f.connect(tester);
      expect(f.api.credentialReads, 1);
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      f.api.failCredentials = true;
      // open은 join Future(자격 갱신 타이머 등록 포함)의 완료까지 확인한다.
      // TTL 10초의 80%인 8초 뒤에는 최초 조회 + 첫 갱신 = 2회다.
      await tester.pump(const Duration(seconds: 8));
      expect(f.api.credentialReads, 2);
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      expect(f.session.mediaError, '통화 연결 정보를 갱신하지 못해 다시 시도합니다.');
      // 재시도 간격은 DateTime.now() 기준 잔여 TTL에 따라 최대 5초다.
      // 위젯의 가짜 시간과 벽시계는 다르므로 이후 조회 횟수는 고정하지 않는다.
      await tester.pump(const Duration(seconds: 5));
      expect(f.api.credentialReads, greaterThan(2));
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      expect(f.session.peerStates, {'bob': MeshPeerState.connected});
      expect(f.session.retryAttempts, 0);
      expect(f.engine.joins, 1);
      expect(f.engine.leaves, 0);
      expect(f.native.created, 1);
      expect(f.native.closed, isEmpty);
      expect(f.calls.starts, 1);
      f.api.failCredentials = false;
      final reads = f.api.credentialReads;
      await tester.pump(const Duration(seconds: 5));
      expect(f.api.credentialReads, greaterThan(reads));
      expect(f.session.mediaError, isNull);
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      expect(f.native.configured, ['pc1']);
      expect(f.engine.joins, 1);
      expect(f.engine.leaves, 0);
      expect(f.native.closed, isEmpty);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('실제 엔진의 모든 피어 복구 소진 뒤에만 RoomSession이 한 번 재참여한다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      f.api.members = [
        ...f.api.members,
        const Member('charlie', 'Charlie', '3'),
      ];
      await f.open(tester);
      await f.connect(tester, peerId: 'pc1');
      await f.connect(tester, handle: 'charlie', peerId: 'pc2');
      await _complete(tester, f.native.state('pc1', 'failed'), 'bob 연결 실패');
      for (final seconds in [2, 4, 8, 8]) {
        await tester.pump(Duration(seconds: seconds));
      }
      expect(f.session.peerStates['bob'], MeshPeerState.failed);
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      expect(f.engine.leaves, 0);
      expect(f.engine.joins, 1);
      await _complete(tester, f.native.state('pc2', 'failed'), 'charlie 연결 실패');
      for (final seconds in [2, 4, 8]) {
        expect(f.session.mediaConnection, MediaConnectionState.connecting);
        expect(f.engine.leaves, 0);
        expect(f.engine.joins, 1);
        await tester.pump(Duration(seconds: seconds));
      }
      await tester.pump(meshRecoveryTimeout);
      expect(f.session.peerStates['bob'], MeshPeerState.failed);
      expect(f.session.peerStates['charlie'], MeshPeerState.failed);
      expect(f.session.mediaConnection, MediaConnectionState.failed);
      expect(f.engine.joins, 1);
      final rejoined = f.engine.nextJoin;
      await tester.pump(const Duration(seconds: 1));
      await _complete(tester, rejoined, '복구 소진 뒤 재참여');
      expect(f.engine.leaves, 1);
      expect(f.engine.joins, 2);
      expect(f.calls.starts, 1);
      await f.connect(tester, peerId: 'pc3');
      await f.connect(tester, handle: 'charlie', peerId: 'pc4');
      await tester.pump(const Duration(seconds: 30));
      expect(f.session.mediaConnection, MediaConnectionState.connected);
      expect(f.engine.joins, 2);
      expect(f.engine.leaves, 1);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

// 각 작업은 메모리 fake/즉시 채널 응답으로 끝나야 한다. 최대 8회 반복과
// 마지막 1회의 0ms pump 뒤에도 미완료이면 단계 이름으로 즉시 실패시킨다.
// SDK의 StreamSubscription.cancel() 등은 root-zone의 캐시된 nullFuture를
// 반환할 수 있다. 빈 runAsync는 그 microtask만 통과시키며 타이머를 기다리지
// 않는다. 엔진 생성·join·타이머는 계속 testWidgets의 가짜 시간에 속한다.
Future<T> _complete<T>(
  WidgetTester tester,
  Future<T> future,
  String step,
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
    // pump가 fake-zone microtask와 즉시 mock 응답을 처리한다.
    await tester.pump(Duration.zero);
    if (!done) await tester.runAsync(() async {});
  }
  // 마지막 root-zone 반환 뒤의 fake-zone continuation도 처리한다.
  await tester.pump(Duration.zero);
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  expect(done, isTrue, reason: '$step: 즉시 mock 응답으로 완료되어야 합니다.');
  return value;
}

class _Fixture {
  _Fixture(this.store, this.native, int ttl) {
    api = _Api(store, ttl);
    mic = _Mic(store);
    calls = _Calls();
    engine = _Engine(api: api, micRouter: mic);
    session = RoomSession(
      api: api,
      mediaEngine: engine,
      store: store,
      callService: calls,
      micRouter: mic,
    );
  }
  static Future<_Fixture> create(WidgetTester tester, {int ttl = 3600}) async {
    SharedPreferences.setMockInitialValues({
      'token': 'test',
      'handle': 'alice',
    });
    // SharedPreferences의 in-memory store가 즉시 응답한다(디스크/채널 없음).
    final preferences = await _complete(
      tester,
      SharedPreferences.getInstance(),
      '설정 초기화',
    );
    final native = _Native(tester.binding.defaultBinaryMessenger)..install();
    return _Fixture(SessionStore(preferences), native, ttl);
  }

  final SessionStore store;
  final _Native native;
  late final _Api api;
  late final _Mic mic;
  late final _Calls calls;
  late final _Engine engine;
  late final RoomSession session;

  Future<void> open(WidgetTester tester) async {
    // getRoom/setMembers는 메모리 응답이며 hello 자체를 기다리지 않는다.
    await _complete(tester, session.open('ABC123'), '방 열기');
    final joined = engine.nextJoin;
    api.events.add(Hello('alice', api.members));
    // hello가 자동 join을 시작한다. createPeerConnection/SDP/신호 전송까지
    // 완료되고 TURN 갱신 타이머가 등록된 후 super.join이 완료된다.
    await _complete(tester, joined, 'hello 뒤 엔진 초기화');
    expect(session.joiningCall, isFalse);
    expect(engine.joins, 1);
    expect(native.created, api.members.length - 1);
  }

  Future<void> connect(
    WidgetTester tester, {
    String handle = 'bob',
    String? peerId,
  }) async {
    // 저장한 offer의 negotiationId와 즉시 setRemoteDescription 응답이 완료원.
    await _complete(
      tester,
      engine.onSignal(handle, 'answer', {
        'type': 'answer',
        'sdp': 'answer',
        'negotiationId': api.offers.lastWhere(
          (offer) => offer['to'] == handle,
        )['negotiationId'],
      }),
      '$handle SDP answer',
    );
    await _complete(
      tester,
      native.state(peerId ?? 'pc${native.created}', 'connected'),
      '$handle 연결 이벤트',
    );
    expect(session.peerStates[handle], MeshPeerState.connected);
  }

  Future<void> dispose(WidgetTester tester) async {
    try {
      // leave가 모든 엔진 타이머를 취소하고 즉시 close/dispose mock을 받는다.
      await _complete(tester, session.leaveCall(), '통화 정리');
    } finally {
      session.dispose();
      try {
        // RoomSession.dispose가 시작한 미디어 해제도 끝난 후 채널을 제거한다.
        await _complete(tester, engine.disposed!, '엔진 해제');
        await _complete(tester, api.close(), 'SSE 정리');
      } finally {
        mic.dispose();
        calls.dispose();
        store.dispose();
        native.uninstall();
      }
    }
    expect(native.unexpected, isEmpty);
  }
}

class _Engine extends WebRtcMediaEngine {
  _Engine({required super.api, required super.micRouter});
  int joins = 0, leaves = 0;
  Completer<void> _nextJoin = Completer<void>();
  Future<void> get nextJoin => _nextJoin.future;
  Future<void>? disposed;
  @override
  Future<void> join(String roomCode, String selfHandle) {
    joins++;
    final completed = _nextJoin;
    _nextJoin = Completer<void>();
    final operation = super.join(roomCode, selfHandle);
    unawaited(
      operation.then<void>(
        (_) => completed.complete(),
        onError: (Object error, StackTrace stack) =>
            completed.completeError(error, stack),
      ),
    );
    return operation;
  }

  @override
  Future<void> leave() {
    leaves++;
    return super.leave();
  }

  @override
  Future<void> dispose() => disposed ??= super.dispose();
}

class _Api extends ApiClient {
  _Api(SessionStore store, this.ttl) : super(tokenStore: store);
  final int ttl;
  final _streams = <StreamController<RoomEvent>>[];
  StreamController<RoomEvent> get events => _streams.last;
  Future<void> close() async {
    for (final stream in _streams) {
      // done은 구독 당시 이 fake-zone에 만들었고 session.dispose가 취소했다.
      await stream.close();
    }
  }

  List<Member> members = const [
    Member('alice', 'Alice', '1'),
    Member('bob', 'Bob', '2'),
  ];
  final offers = <Map<String, Object?>>[];
  int credentialReads = 0;
  bool failCredentials = false;
  @override
  Future<IceServerCredentials> fetchIceServers() async {
    credentialReads++;
    if (failCredentials) throw const ApiException(503, 'unavailable', '일시 실패');
    return IceServerCredentials(const [], ttl);
  }

  @override
  Future<RoomDetails> getRoom(String code) async =>
      RoomDetails(Room(code, null), members);
  @override
  Stream<RoomEvent> subscribeEvents(String code) {
    final stream = StreamController<RoomEvent>(onCancel: () async {});
    // 취소 후 처음 done을 읽으면 SDK의 root-zone nullFuture가 반환된다.
    // 미리 할당하면 cancel/close가 현재 테스트 zone에서 완료된다.
    unawaited(stream.done);
    _streams.add(stream);
    return stream.stream;
  }

  @override
  Future<void> sendSignal(
    String code,
    String to,
    String kind,
    Object? payload,
  ) async {
    if (kind == 'offer')
      offers.add({...Map<String, Object?>.from(payload as Map), 'to': to});
  }
}

class _Mic extends MicRouter {
  _Mic(super.store) {
    permissions = const AudioPermissions(microphone: true);
  }
  @override
  Future<void> stopPreview() async {}
  @override
  Future<void> refreshPermissions() async {}
  @override
  Future<void> refreshOutputRoute() async {}
  @override
  Future<void> applyOutputRoute() async {}
}

class _Calls extends CallService {
  int starts = 0;
  @override
  Future<void> start(String roomCode, String handle) async {
    starts++;
    state = CallState(roomCode: roomCode, selfHandle: handle, isActive: true);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    state = const CallState();
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {}
}

// flutter_webrtc 1.6.3/lib/src/native의 실제 호출 계약에 맞춘다.
// null은 반환값을 읽지 않는 void 메서드/listen/cancel의 성공 응답에만 쓴다.
// 실제 엔진·MeshCoordinator·TURN 타이머·RoomSession은 그대로 실행한다.
class _Native {
  _Native(this.messenger);
  final TestDefaultBinaryMessenger messenger;
  final channels = <MethodChannel>[];
  final closed = <String>[];
  final configured = <String>[];
  final unexpected = <String>[];
  final volumes = <double>[];
  final volumeTargets = <String>[];
  final statsReads = <String>[];
  List<StatsReport> stats = [];
  int created = 0;
  static const _audioTrack = <String, Object?>{
    'id': 'local-audio',
    'kind': 'audio',
    'label': 'microphone',
    'enabled': true,
  };
  static const _rtpParameters = <String, Object?>{
    'encodings': <Object?>[],
    'headerExtensions': <Object?>[],
    'codecs': <Object?>[],
    'rtcp': <String, Object?>{'reducedSize': false},
  };

  void mock(String name, Object? Function(MethodCall) handler) {
    final channel = MethodChannel(name);
    channels.add(channel);
    // 핸들러 안에는 await/타이머/실제 I/O가 없다.
    messenger.setMockMethodCallHandler(
      channel,
      (call) => SynchronousFuture<Object?>(handler(call)),
    );
  }

  Never unknown(String channel, MethodCall call) {
    unexpected.add('$channel.${call.method}');
    throw PlatformException(
      code: 'unexpected-test-call',
      message: unexpected.last,
    );
  }

  void eventChannel(String name) {
    mock(
      name,
      (call) => switch (call.method) {
        'listen' || 'cancel' => null,
        _ => unknown(name, call),
      },
    );
  }

  void install() {
    eventChannel('FlutterWebRTC.Event');
    eventChannel('unavo/audio/levels');
    eventChannel('unavo/audio/routes');
    eventChannel('unavo/call/events');
    mock(
      'unavo/noise',
      (call) => switch (call.method) {
        'configure' => <String, Object?>{
          'supported': true,
          'enabled': (call.arguments as Map)['enabled'],
        },
        'exportDump' => <String, Object?>{'supported': true},
        _ => unknown('unavo/noise', call),
      },
    );
    // MicRouter/CallService는 fake를 쓰되 관련 채널도 즉시 응답하도록 한다.
    mock(
      'unavo/audio',
      (call) => switch (call.method) {
        'getState' || 'choose' => <String, Object?>{'level': 0.0},
        'permissions' || 'requestPermissions' => <String, Object?>{
          'microphone': true,
          'notifications': true,
        },
        'getOutputRoute' || 'setOutputRoute' => <String, Object?>{
          'route': 'speaker',
          'available': ['speaker', 'receiver'],
        },
        'setSpeakerphone' => (call.arguments as Map)['enabled'],
        'stopPreview' => null,
        _ => unknown('unavo/audio', call),
      },
    );
    mock(
      'unavo/call',
      (call) => switch (call.method) {
        'getState' => <String, Object?>{'isActive': false},
        'start' => <String, Object?>{
          'roomCode': (call.arguments as Map)['roomCode'],
          'selfHandle': (call.arguments as Map)['handle'],
          'isActive': true,
        },
        'stop' || 'setMuted' => null,
        _ => unknown('unavo/call', call),
      },
    );
    mock('FlutterWebRTC.Method', (call) {
      switch (call.method) {
        case 'initialize':
        case 'setAndroidAudioConfiguration':
        case 'setAppleAudioConfiguration':
        case 'setLocalDescription':
        case 'setRemoteDescription':
        case 'addCandidate':
        case 'mediaStreamTrackSetEnable':
        case 'trackDispose':
        case 'streamDispose':
        case 'peerConnectionDispose':
          return null;
        case 'getUserMedia':
          return {
            'streamId': 'local',
            'audioTracks': [_audioTrack],
            'videoTracks': <Object?>[],
          };
        case 'createPeerConnection':
          final id = 'pc${++created}';
          eventChannel('FlutterWebRTC/peerConnectionEvent$id');
          return {'peerConnectionId': id};
        case 'addTrack':
          return {
            'senderId': 'sender-${(call.arguments as Map)['peerConnectionId']}',
            'track': _audioTrack,
            'ownsTrack': false,
            'rtpParameters': _rtpParameters,
          };
        case 'createOffer':
          return {'type': 'offer', 'sdp': 'offer'};
        case 'getStats':
          statsReads.add((call.arguments as Map)['peerConnectionId'] as String);
          return {
            'stats': [
              for (final report in stats)
                {
                  'id': report.id,
                  'type': report.type,
                  'timestamp': report.timestamp,
                  'values': report.values,
                },
            ],
          };
        case 'setVolume':
          // 핸들러 안의 expect 는 실패해도 테스트에 드러나지 않고 호출만 삼킨다 — 기록만 하고 본문에서 검증.
          final args = call.arguments as Map;
          volumeTargets.add('${args['peerConnectionId']}/${args['trackId']}');
          volumes.add((args['volume'] as num).toDouble());
          return null;
        case 'setConfiguration':
          configured.add((call.arguments as Map)['peerConnectionId'] as String);
          return null;
        case 'peerConnectionClose':
          closed.add((call.arguments as Map)['peerConnectionId'] as String);
          return null;
        default:
          return unknown('FlutterWebRTC.Method', call);
      }
    });
  }

  Future<void> state(String id, String state) =>
      messenger.handlePlatformMessage(
        'FlutterWebRTC/peerConnectionEvent$id',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'event': 'peerConnectionState',
          'state': state,
        }),
        (_) {},
      );
  Future<void> track(String id) {
    const track = {
      'id': 'remote-audio',
      'kind': 'audio',
      'label': 'remote',
      'enabled': true,
    };
    return messenger.handlePlatformMessage(
      'FlutterWebRTC/peerConnectionEvent$id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'onTrack',
        'streams': <Object?>[],
        'track': track,
        'receiver': {
          'receiverId': 'receiver',
          'track': track,
          'rtpParameters': _rtpParameters,
        },
      }),
      (_) {},
    );
  }

  void uninstall() {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  }
}
