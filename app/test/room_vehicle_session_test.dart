import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/core/vehicle_state.dart';
import 'package:unavo/location/follow_voice_guidance.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';

import 'support/consent_fakes.dart' show completeConsentFuture, pumpConsentUi;
import 'support/location_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in DeviceMode.values) {
    testWidgets('$mode 준비 토글과 차량 문·기어 자동 취소', (tester) async {
      final f = await _Fixture.create(tester, mode: mode);
      try {
        await f.open(tester);
        await f.update(tester, left: 1, parked: true);
        await completeConsentFuture(tester, f.room.toggleReady());
        expect(f.room.selfReady, mode == DeviceMode.phone);
        if (mode == DeviceMode.car) {
          expect(f.room.vehicleNotice, '문이 열려 있습니다');
          expect(f.room.exitProtected, isTrue);
          expect(f.room.muted, isTrue);
          await tester.pump(const Duration(milliseconds: 5999));
          expect(f.room.vehicleNotice, '문이 열려 있습니다');
          await tester.pump(const Duration(milliseconds: 1));
          expect(f.room.vehicleNotice, '내리는 중이라 차량 마이크와 위치 보내기를 멈췄습니다');
          expect(f.room.exitProtected, isTrue);
          expect(f.room.muted, isTrue);
          await f.update(tester, parked: false);
          await completeConsentFuture(tester, f.room.toggleReady());
          expect(f.room.vehicleNotice, 'P단에서 준비할 수 있습니다');
          await f.update(tester, parked: true);
          await completeConsentFuture(tester, f.room.toggleReady());
          expect(f.room.selfReady, isTrue);
          await f.update(tester, rightRear: 1);
          expect(f.room.selfReady, isFalse);
          expect(f.api.readyWrites, [true, false]);
          expect(f.voice.spoken, ['준비가 취소됐습니다']);
          await f.update(tester, rightRear: 1);
          expect(f.api.readyWrites, [true, false]);
          await f.update(tester);
          expect(f.room.selfReady, isFalse); // closing never re-readies
          await completeConsentFuture(tester, f.room.toggleReady());
          await f.update(tester, parked: false);
          expect(f.room.selfReady, isFalse);
          expect(f.voice.spoken, ['준비가 취소됐습니다', '준비가 취소됐습니다']);
        } else {
          await f.update(tester, parked: false);
          expect(f.room.selfReady, isTrue);
          await completeConsentFuture(tester, f.room.toggleReady());
          expect(f.room.selfReady, isFalse);
          expect(f.voice.spoken, isEmpty);
        }
      } finally {
        await f.close(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('차량 신호 불가 시 수동 준비, 복구된 열린 문은 준비 취소', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await f.open(tester);
      f.signals.add({'available': false});
      await pumpConsentUi(tester);
      await completeConsentFuture(tester, f.room.toggleReady());
      expect(f.room.selfReady, isTrue);
      await f.update(tester, left: 1);
      expect(f.room.selfReady, isFalse);
      expect(f.api.readyWrites, [true, false]);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('준비 PUT 대기 중 문이 열리면 늦은 true 다음 false를 서버에 보낸다', (tester) async {
    final f = await _Fixture.create(tester);
    final gate = Completer<void>();
    try {
      await f.open(tester);
      await f.update(tester);
      f.api.readyGate = gate.future;
      final preparing = f.room.toggleReady();
      await tester.pump();
      expect(f.api.readyWrites, [true]);
      await f.update(tester, rightRear: 1);
      expect(f.room.selfReady, isFalse);
      gate.complete();
      await completeConsentFuture(tester, preparing);
      await pumpConsentUi(tester);
      expect(f.api.readyWrites, [true, false]);
      expect(f.room.selfReady, isFalse);
      expect(f.room.readyBusy, isFalse);
      f.api.events.add(const ReadyChanged('alice', true, 1)); // stale true
      await pumpConsentUi(tester);
      expect(f.room.selfReady, isFalse);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await f.close(tester);
    }
  });

  testWidgets('자동 준비 취소의 네트워크 실패는 재시도하고 준비를 되살리지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await f.open(tester);
      await f.update(tester);
      await completeConsentFuture(tester, f.room.toggleReady());
      f.api.failCancel = true;
      await f.update(tester, parked: false);
      expect(f.room.selfReady, isFalse);
      expect(f.room.readyBusy, isTrue);
      f.api.failCancel = false;
      await tester.pump(const Duration(seconds: 2));
      await pumpConsentUi(tester);
      expect(f.room.readyBusy, isFalse);
      expect(f.api.readyWrites, [true, false, false]);
      expect(f.voice.spoken, ['준비가 취소됐습니다']);
    } finally {
      await f.close(tester);
    }
  });

  for (final action in ExitProtection.values) {
    testWidgets('하차 보호 $action, 같은 이벤트 중복과 문 닫힘 자동 재개 없음', (tester) async {
      final f = await _Fixture.create(tester);
      try {
        await completeConsentFuture(tester, f.store.setExitProtection(action));
        await f.open(tester);
        await f.update(tester);
        await completeConsentFuture(
          tester,
          f.room.locationShare.start(token: Object(), stillValid: () => true),
        );
        expect(f.room.call.isActive, isTrue);
        await f.update(tester, left: 1, parked: false);
        expect(f.room.muted, isFalse); // open in Drive is not an exit
        await f.update(tester, left: 1, parked: true);
        expect(f.room.muted, action != ExitProtection.none);
        expect(f.media.muted, action != ExitProtection.none);
        expect(
          f.room.locationShare.sharing,
          action != ExitProtection.micAndLocation,
        );
        expect(f.media.leaves, 0); // exit only changes local transmission
        final deletes = f.api.stops;
        await f.update(tester, left: 1);
        expect(f.api.stops, deletes);
        await f.update(tester);
        expect(f.room.muted, action != ExitProtection.none);
        expect(
          f.room.locationShare.sharing,
          action != ExitProtection.micAndLocation,
        );
        if (action != ExitProtection.none) {
          expect(f.room.exitProtected, isTrue);
          await completeConsentFuture(tester, f.room.resumeAfterExit());
          expect(f.room.muted, isFalse);
          expect(f.room.locationShare.sharing, isTrue);
          expect(f.room.exitProtected, isFalse);
        }
        expect(f.api.subscriptions, 1); // never initiates another device/entry
      } finally {
        await f.close(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('기기 설정은 로그아웃 후에도 이 기기에 남는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      expect(f.store.exitProtection, ExitProtection.micAndLocation);
      await completeConsentFuture(
        tester,
        f.store.setExitProtection(ExitProtection.micOnly),
      );
      await completeConsentFuture(tester, f.store.clear());
      expect(f.store.exitProtection, ExitProtection.micOnly);
      final restored = SessionStore(f.store.preferences);
      expect(restored.exitProtection, ExitProtection.micOnly);
      restored.dispose();
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('최초 hello 전에는 다른 기기의 준비 스냅샷을 취소하지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      f.api.members = [
        f.api.members.first.withReady(true, 5),
        f.api.members.last,
      ];
      await completeConsentFuture(tester, f.room.open('ABC123'));
      await f.update(tester, left: 1);
      expect(f.api.readyWrites, isEmpty);
      expect(f.room.exitProtected, isFalse);
      f.api.members = [
        f.api.members.first.withReady(false, 6),
        f.api.members.last,
      ];
      f.api.events.add(Hello('alice', f.api.members));
      await pumpConsentUi(tester);
      expect(f.room.selfReady, isFalse);
      expect(f.room.exitProtected, isTrue);
      expect(f.api.readyWrites, isEmpty);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('SSE 단절 중에도 하차 보호는 로컬 마이크와 위치를 멈춘다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await f.open(tester);
      await f.update(tester);
      await completeConsentFuture(
        tester,
        f.room.locationShare.start(token: Object(), stillValid: () => true),
      );
      f.api.events.add(const Disconnected('연결 대기', 2000));
      await pumpConsentUi(tester);
      expect(f.room.state.isConnected, isFalse);
      await f.update(tester, left: 1);
      expect(f.room.muted, isTrue);
      expect(f.room.locationShare.sharing, isFalse);
      expect(f.room.exitProtected, isTrue);
    } finally {
      await f.close(tester);
    }
  });

  testWidgets('이어받음은 마이크·수신·위치를 즉시 끊고 직접 다시 가져오기만 재입장한다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await f.open(tester);
      await f.update(tester);
      await completeConsentFuture(
        tester,
        f.room.locationShare.start(token: Object(), stillValid: () => true),
      );
      f.api.events.add(const DeviceReplaced());
      await pumpConsentUi(tester);
      expect(f.room.deviceReplaced, isTrue);
      expect(f.room.muted, isTrue);
      expect(f.room.speakerphone, isFalse);
      expect(f.media.muted, isTrue);
      expect(f.media.volume, 0);
      expect(f.media.leaves, 1);
      expect(f.room.call.isActive, isFalse);
      expect(f.room.locationShare.sharing, isFalse);
      expect(f.api.stops, 0); // cannot delete the new device's location
      expect(f.room.vehicleNotice, '다른 기기에서 이어받았습니다');
      await f.update(tester);
      await tester.pump(const Duration(seconds: 30));
      await completeConsentFuture(tester, f.room.reconnect());
      expect(f.api.subscriptions, 1);
      expect(f.media.joins, 1);
      f.room.setMuted(false);
      await completeConsentFuture(tester, f.room.setCallVolume(100));
      expect(f.room.muted, isTrue);
      expect(f.media.volume, 0);
      await completeConsentFuture(tester, f.room.takeBack());
      expect(f.api.subscriptions, 2);
      f.api.events.add(Hello('alice', f.api.members));
      await pumpConsentUi(tester);
      expect(f.room.deviceReplaced, isFalse);
      expect(f.media.joins, 2);
      expect(f.room.call.isActive, isTrue);
      expect(
        f.room.locationShare.sharing,
        isFalse,
      ); // needs explicit location action
      expect(f.room.state.members.map((m) => m.handle).toSet(), {
        'alice',
        'bob',
      });
      f.api.events.add(const MemberDeviceChanged('bob'));
      await pumpConsentUi(tester);
      expect(f.media.memberUpdates[f.media.memberUpdates.length - 2], [
        'alice',
      ]);
      expect(f.media.memberUpdates.last, ['alice', 'bob']);
    } finally {
      await f.close(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('늦은 멤버 조회와 중복 hello는 준비 revision과 단일 계정 목록을 보존한다', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, mode: DeviceMode.phone);
    try {
      await f.open(tester);
      f.api.events.add(const ReadyChanged('bob', true, 5));
      f.api.events.add(Hello('alice', [...f.api.members, f.api.members.last]));
      await pumpConsentUi(tester);
      expect(f.room.state.members, hasLength(2));
      expect(f.room.state.members.last.ready, isTrue);
      expect(f.room.readyCount, 1);
      expect(f.media.memberUpdates.last, ['alice', 'bob']);
    } finally {
      await f.close(tester);
    }
  });
}

class _Fixture {
  _Fixture(this.store, DeviceMode mode) {
    api = _Api(store);
    mic = _Mic(store);
    room = RoomSession(
      api: api,
      mediaEngine: media,
      store: store,
      callService: calls,
      micRouter: mic,
      deviceMode: mode,
      locationSource: source,
      vehicle: VehicleState(mode: mode, events: signals.stream),
      vehicleVoice: FollowVoiceGuidance(
        enabled: () => mode == DeviceMode.car,
        output: voice,
      ),
    );
  }
  static Future<_Fixture> create(
    WidgetTester tester, {
    DeviceMode mode = DeviceMode.car,
  }) async {
    SharedPreferences.setMockInitialValues({
      'handle': 'alice',
      'token': 'test',
    });
    final prefs = await completeConsentFuture(
      tester,
      SharedPreferences.getInstance(),
    );
    return _Fixture(SessionStore(prefs), mode);
  }

  final SessionStore store;
  final signals = StreamController<Object?>.broadcast();
  final media = _Media();
  final calls = _Calls();
  final voice = _Voice();
  final source = FakeLocationSource();
  late final _Api api;
  late final _Mic mic;
  late final RoomSession room;
  Future<void> open(WidgetTester tester) async {
    await completeConsentFuture(tester, room.open('ABC123'));
    api.events.add(Hello('alice', api.members));
    await pumpConsentUi(tester);
  }

  Future<void> update(
    WidgetTester tester, {
    int left = 0,
    int rightRear = 0,
    bool parked = true,
  }) async {
    signals.add({
      'available': true,
      'doors': {'ROW_1_LEFT': left, 'ROW_2_RIGHT': rightRear},
      'parked': parked,
      'exitDoor': 'ROW_1_LEFT',
    });
    await pumpConsentUi(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await completeConsentFuture(tester, room.shutdown());
    await completeConsentFuture(tester, source.close());
    await completeConsentFuture(tester, signals.close());
    await completeConsentFuture(tester, api.closeEvents());
    api.close();
    calls.dispose();
    mic.dispose();
    store.dispose();
  }
}

class _Api extends ApiClient {
  _Api(SessionStore store) : super(tokenStore: store);
  final events = StreamController<RoomEvent>.broadcast();
  Future<void> closeEvents() => events.close();
  List<Member> members = const [
    Member('alice', '앨리스', '1'),
    Member('bob', '보비', '2'),
  ];
  final readyWrites = <bool>[];
  Future<void>? readyGate;
  bool failCancel = false;
  int revision = 0, stops = 0, subscriptions = 0;
  @override
  Future<ReadyChanged> setReady(String code, bool ready) async {
    readyWrites.add(ready);
    if (ready) await readyGate;
    if (!ready && failCancel)
      throw const ApiException(503, 'unavailable', '연결 실패');
    final event = ReadyChanged('alice', ready, ++revision);
    members = [
      for (final member in members)
        member.handle == 'alice' ? member.withReady(ready, revision) : member,
    ];
    return event;
  }

  @override
  Stream<RoomEvent> subscribeEvents(String code) {
    subscriptions++;
    return events.stream;
  }

  @override
  Future<RoomDetails> getRoom(String code) async =>
      RoomDetails(Room(code, '테스트'), members);
  @override
  Future<void> stopLocation(String code) async {
    stops++;
  }

  @override
  Future<bool> sendLocation(String code, LocationFix fix) async => false;
  @override
  Future<void> sendSignal(
    String code,
    String to,
    String kind,
    Object? payload,
  ) async {}
}

class _Mic extends MicRouter {
  _Mic(super.store) {
    permissions = const AudioPermissions(microphone: true);
  }
  @override
  Future<void> refreshPermissions() async {}
  @override
  Future<void> refreshOutputRoute() async {}
  @override
  Future<void> stopPreview() async {}
  @override
  Future<void> applyOutputRoute() async {}
}

class _Calls extends CallService {
  @override
  Future<void> start(String code, String handle) async {
    state = CallState(roomCode: code, selfHandle: handle, isActive: true);
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

class _Media extends NoopMediaEngine {
  bool muted = false;
  double volume = 1;
  int joins = 0, leaves = 0;
  final memberUpdates = <List<String>>[];
  @override
  Future<void> join(String code, String handle) async {
    joins++;
    connectionChanged?.call(MediaConnectionState.connected, null);
  }

  @override
  Future<void> leave() async {
    leaves++;
  }

  @override
  Future<void> setMembers(List<String> handles) async {
    memberUpdates.add(List.of(handles));
  }

  @override
  void setMuted(bool value) {
    muted = value;
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }
}

class _Voice implements FollowSpeechOutput {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, DateTime expiresAt) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}
}
