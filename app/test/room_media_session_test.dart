import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/call/mesh_coordinator.dart';
import 'package:unavo/core/app_services.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/ui/widgets/panel_button.dart';
import 'package:unavo/ui/widgets/status_chip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SessionStore> storeFor(String handle) async {
    SharedPreferences.setMockInitialValues({'token': 'test', 'handle': handle});
    return SessionStore(await SharedPreferences.getInstance());
  }

  test('hello 멤버를 보존하고 preview → native call → media 순서로 시작·역순 종료한다', () async {
    final store = await storeFor('alice');
    final order = <String>[];
    final api = _Api(store);
    final mic = _Mic(store, order);
    final calls = _Calls(order);
    final media = _Media(order);
    final session = RoomSession(
      api: api,
      mediaEngine: media,
      store: store,
      callService: calls,
      micRouter: mic,
    );
    addTearDown(() async {
      session.dispose();
      await api.close();
      calls.dispose();
      mic.dispose();
      store.dispose();
    });

    await session.open('ABC123');
    api.members = const [Member('alice', '앨리스', '1'), Member('bob', '보비', '2')];
    api.events.add(Hello('alice', api.members));
    await Future<void>.delayed(Duration.zero);
    expect(media.members, ['alice', 'bob']);
    expect(session.callJoinBlockedReason, isNull);
    await session.joinCall();
    expect(order, [
      'preview-stop',
      'native-start',
      'media-start',
      'speaker:false',
    ]);
    expect(session.mediaConnection, MediaConnectionState.connected);
    media.remoteSpeaking?.call('bob', true);
    expect(session.speaking, {'bob'});
    session.setMuted(true);
    expect(media.muted, isTrue);

    api.members = const [Member('alice', '앨리스', '1')];
    api.events.add(const MemberLeft('bob'));
    await Future<void>.delayed(Duration.zero);
    expect(media.members, ['alice']);
    expect(session.speaking, isEmpty);
    await session.leaveCall();
    expect(order.sublist(order.length - 2), ['media-stop', 'native-stop']);
    expect(session.call.isActive, isFalse);
    expect(session.mediaConnection, MediaConnectionState.idle);
  });

  test('미디어 초기화 실패는 네이티브 통화를 종료하고 실패 상태를 남긴다', () async {
    final store = await storeFor('alice');
    final order = <String>[];
    final api = _Api(store);
    final mic = _Mic(store, order);
    final calls = _Calls(order);
    final media = _Media(order)..failJoin = true;
    final session = RoomSession(
      api: api,
      mediaEngine: media,
      store: store,
      callService: calls,
      micRouter: mic,
    );
    addTearDown(() async {
      session.dispose();
      await api.close();
      calls.dispose();
      mic.dispose();
      store.dispose();
    });
    await session.open('ABC123');
    api.events.add(Hello('alice', api.members));
    await Future<void>.delayed(Duration.zero);
    await expectLater(session.joinCall(), throwsStateError);
    expect(calls.state.isActive, isFalse);
    expect(session.mediaConnection, MediaConnectionState.failed);
    expect(session.mediaError, 'capture unavailable');
    expect(order.sublist(order.length - 2), ['media-stop', 'native-stop']);
  });

  testWidgets('5번째 참여자는 버튼 비활성·사유 칩, 기존 4번째는 참여 가능', (tester) async {
    final members = [
      for (final name in ['alice', 'bob', 'charlie', 'david', 'aaron'])
        Member(name, name, ''),
    ];
    for (final handle in ['aaron', 'david']) {
      final store = await storeFor(handle);
      final services = AppServices(store, mediaEngine: NoopMediaEngine());
      services.rooms.state = RoomState(
        code: 'ABC123',
        members: members,
        isConnected: true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RoomScreen(
              services: services,
              mode: DeviceMode.phone,
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final join = tester.widget<PanelButton>(
        find.byWidgetPredicate(
          (widget) => widget is PanelButton && widget.label == '통화 참여',
        ),
      );
      expect(join.onPressed == null, handle == 'aaron');
      if (handle == 'aaron') {
        final chip = tester.widget<StatusChip>(find.byType(StatusChip));
        expect(chip.label, meshCapacityReason);
        expect(chip.showLabel, isTrue);
        expect(find.text(meshCapacityReason), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      services.dispose();
    }
  });
}

class _Api extends ApiClient {
  _Api(SessionStore store) : super(tokenStore: store);
  final events = StreamController<RoomEvent>();
  Future<void> close() => events.close();
  List<Member> members = const [Member('alice', '앨리스', '1')];
  @override
  Future<RoomDetails> getRoom(String code) async =>
      RoomDetails(const Room('ABC123', null), members);
  @override
  Stream<RoomEvent> subscribeEvents(String code) => events.stream;
}

class _Mic extends MicRouter {
  _Mic(super.store, this.order) {
    permissions = const AudioPermissions(microphone: true);
  }
  final List<String> order;
  @override
  Future<void> refreshPermissions() async {}
  @override
  Future<void> stopPreview() async {
    order.add('preview-stop');
  }

  @override
  Future<bool> setSpeakerphone(bool enabled) async {
    order.add('speaker:$enabled');
    return enabled;
  }
}

class _Calls extends CallService {
  _Calls(this.order);
  final List<String> order;
  @override
  Future<void> start(String roomCode, String handle) async {
    order.add('native-start');
    state = CallState(roomCode: roomCode, selfHandle: handle, isActive: true);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    order.add('native-stop');
    state = const CallState();
    notifyListeners();
  }
}

class _Media extends NoopMediaEngine {
  _Media(this.order);
  final List<String> order;
  List<String> members = [];
  bool failJoin = false;
  bool muted = false;
  @override
  Future<void> setMembers(List<String> handles) async {
    members = handles;
  }

  @override
  Future<void> join(String roomCode, String selfHandle) async {
    order.add('media-start');
    if (failJoin) throw StateError('capture unavailable');
    connectionChanged?.call(MediaConnectionState.connected, null);
  }

  @override
  Future<void> leave() async {
    order.add('media-stop');
    connectionChanged?.call(MediaConnectionState.idle, null);
  }

  @override
  void setMuted(bool value) {
    muted = value;
  }

  @override
  void onRemoteSpeaking(String handle) {}
}
