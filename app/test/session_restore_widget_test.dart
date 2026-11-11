import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_restore.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/app_services.dart';
import 'package:unavo/map/map_provider.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/car/car_dashboard.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/screens/phone/rooms.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/widgets/panel_button.dart';
import 'package:unavo/ui/widgets/room_code.dart';

import 'support/icon_bundle.dart';

void main() {
  for (final car in [false, true]) {
    testWidgets('${car ? '차' : '폰'} 새 실행 복원은 메인에 복귀 카드만 표시하고 자동으로 열지 않는다', (
      tester,
    ) async {
      final f = await _Fixture.create(tester);
      try {
        await f.mount(tester, car: car);
        // 표지/앱 전체 대신 실제 restoreSession과 대상 메인 화면을 검증한다.
        // 시간이 지나도 방 열기/SSE/통화가 저절로 시작되지 않아야 한다.
        await tester.pump(const Duration(milliseconds: 1200));
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(RoomsScreen), findsOneWidget);
        expect(find.byType(RoomScreen), findsNothing);
        expect(find.byType(CarDashboard), car ? findsOneWidget : findsNothing);
        f.expectRestorableCard();
        expect(f.services.api.meReads, 1);
        expect(f.services.rooms.state.code, isNull);
        expect(f.opened, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await f.dispose(tester);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    for (final tapButton in [false, true]) {
      testWidgets(
        '${car ? '차' : '폰'} 복귀 카드 ${tapButton ? '아이콘' : '이름'} 탭 뒤에만 open·hello·통화',
        (tester) async {
          final f = await _Fixture.create(tester);
          try {
            await f.mount(tester, car: car);
            f.expectRestorableCard();
            final card = find.byKey(const ValueKey('current-room-card'));
            expect(
              tester
                  .widget<RoomCode>(
                    find.descendant(of: card, matching: find.byType(RoomCode)),
                  )
                  .code,
              'ABC123',
            );
            final button = tester.widget<PanelButton>(
              find.descendant(of: card, matching: find.byType(PanelButton)),
            );
            expect(button.iconOnly, isTrue);
            expect(button.icon, 'login');
            expect(find.text('방 입장'), findsNothing);
            // tap은 포인터 전달까지만 완료한다. open의 완료는 별도로 확인한다.
            await tester.tap(
              tapButton ? find.byTooltip('방 입장') : find.text('이전 방'),
            );
            expect(f.services.rooms.lastOpen, isNotNull);
            await _complete(tester, f.services.rooms.lastOpen!, '카드 탭 후 방 열기');
            await tester.pump(const Duration(milliseconds: 100));
            expect(f.services.rooms.opens, 1);
            expect(f.services.api.roomReads, 1);
            expect(f.services.api.subscriptions, 1);
            expect(f.services.rooms.state.code, 'ABC123');
            expect(f.services.rooms.restorableRoom, isNull);
            expect(f.opened, ['ABC123']);
            // open만 완료한 상태를 hello와 분리한다. 시간 경과도 동의가 아니다.
            await tester.pump(const Duration(seconds: 5));
            expect(f.services.rooms.state.isConnected, isFalse);
            expect(f.services.media.joins, 0);
            expect(f.services.calls.starts, 0);
            f.services.api.events.add(Hello('alice', f.services.api.members));
            // 수동 hello -> RoomSession.joinCall -> 즉시 _Media.join이 완료원.
            await _complete(
              tester,
              f.services.media.joined.future,
              'hello 후 통화',
            );
            expect(f.services.rooms.state.isConnected, isTrue);
            expect(f.services.rooms.joiningCall, isFalse);
            expect(f.services.media.joins, 1);
            expect(f.services.calls.starts, 1);
            expect(
              f.services.rooms.mediaConnection,
              MediaConnectionState.connected,
            );
            await tester.pump(const Duration(seconds: 1));
            expect(f.services.rooms.opens, 1);
            expect(f.services.media.joins, 1);
            expect(f.services.calls.starts, 1);
            expect(tester.takeException(), isNull);
          } finally {
            await f.dispose(tester);
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }
}

// 모든 Future는 아래 메모리 fake에서 완료된다. 최대 8회 반복과 마지막
// 1회의 0ms pump 뒤에도 미완료이면 단계 이름과 함께 실패한다. 미완료 시
// 빈 runAsync로 root-zone microtask도 통과시킨다(타이머/네트워크 대기 없음).
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
    // pump가 fake-zone microtask와 UI 갱신을 처리한다.
    await tester.pump(Duration.zero);
    if (!done) await tester.runAsync(() async {});
  }
  await tester.pump(Duration.zero);
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  expect(done, isTrue, reason: '$step: 메모리 fake에서 완료되어야 합니다.');
  return value;
}

class _Fixture {
  _Fixture(this.services);
  final _Services services;
  final appearance = AppearanceController();
  final opened = <String>[];

  static Future<_Fixture> create(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'token': 'test',
      'handle': 'alice',
    });
    // SharedPreferences는 공식 in-memory store로 응답하며 채널을 호출하지 않는다.
    final preferences = await _complete(
      tester,
      SharedPreferences.getInstance(),
      '설정 초기화',
    );
    return _Fixture(_Services(SessionStore(preferences)));
  }

  Future<void> mount(WidgetTester tester, {required bool car}) async {
    tester.view.physicalSize = car
        ? const Size(1320, 940)
        : const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // api.me 즉시 응답 + in-memory store.save가 완료한다. 실제 복원 함수다.
    await _complete(
      tester,
      restoreSession(
        api: services.api,
        store: services.store,
        rooms: services.rooms,
        isCurrent: () => true,
      ),
      '새 실행 복원',
    );
    // 전체 앱의 표지/내비게이터 대신 복귀 카드가 있는 실제 화면만 띄운다.
    await tester.pumpWidget(
      UnavoAppearance(
        controller: appearance,
        child: MaterialApp(
          builder: testIconBuilder,
          home: car
              ? CarDashboard(
                  services: services,
                  showRoom: false,
                  onRoom: opened.add,
                )
              : Scaffold(
                  body: RoomsScreen(services: services, onRoom: opened.add),
                ),
        ),
      ),
    );
    // 차량 FriendsScreen.listContacts의 즉시 응답과 첫 화면 갱신만 처리한다.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(Duration.zero);
  }

  void expectRestorableCard() {
    expect(find.byKey(const ValueKey('current-room-card')), findsOneWidget);
    expect(find.text('이전 방'), findsOneWidget);
    expect(services.rooms.restorableRoom?.code, 'ABC123');
    expect(services.rooms.opens, 0);
    expect(services.api.roomReads, 0);
    expect(services.api.subscriptions, 0);
    expect(services.media.joins, 0);
    expect(services.calls.starts, 0);
  }

  Future<void> dispose(WidgetTester tester) async {
    try {
      // 위젯 listener/애니메이션을 먼저 해제한다.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      // _Media.leave/_Calls.stop은 즉시 완료되는 fake다.
      await _complete(tester, services.rooms.leaveCall(), '통화 정리');
    } finally {
      services.dispose();
      try {
        // dispose가 시작한 비동기 작업까지 끝낸 후 픽스처를 버린다.
        await _complete(tester, services.media.disposed!, '미디어 해제');
        await _complete(tester, services.api.close(), 'SSE 정리');
      } finally {
        appearance.dispose();
      }
    }
  }
}

class _Services implements AppServices {
  _Services(this.store) {
    _api = _Api(store);
    _mic = _Mic(store);
    _calls = _Calls();
    media = _Media();
    _rooms = _Rooms(
      api: api,
      mediaEngine: media,
      store: store,
      callService: calls,
      micRouter: mic,
    );
  }
  @override
  final SessionStore store;
  @override
  MapProvider mapProvider = MapProvider.vworld;
  @override
  final mapAuthError = ValueNotifier<String?>(null);
  late final _Api _api;
  @override
  _Api get api => _api;
  late final _Mic _mic;
  @override
  _Mic get mic => _mic;
  late final _Calls _calls;
  @override
  _Calls get calls => _calls;
  late final _Rooms _rooms;
  @override
  _Rooms get rooms => _rooms;
  late final _Media media;
  @override
  void dispose() {
    mapAuthError.dispose();
    rooms.dispose();
    calls.dispose();
    mic.dispose();
    store.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rooms extends RoomSession {
  _Rooms({
    required super.api,
    required super.mediaEngine,
    required super.store,
    required super.callService,
    required super.micRouter,
  });
  int opens = 0;
  Future<void>? lastOpen;
  @override
  Future<void> open(String code, {bool force = false}) {
    opens++;
    return lastOpen = super.open(code, force: force);
  }
}

class _Api extends ApiClient {
  _Api(SessionStore store) : super(tokenStore: store);
  final _streams = <StreamController<RoomEvent>>[];
  StreamController<RoomEvent> get events => _streams.last;
  Future<void> close() async {
    for (final stream in _streams) {
      // 구독 시 done을 할당했으며 rooms.dispose가 구독을 취소해 완료한다.
      await stream.close();
    }
  }

  final members = const [Member('alice', 'Alice', '1')];
  int meReads = 0, roomReads = 0, subscriptions = 0;
  @override
  Future<MeResult> me() async {
    meReads++;
    return const MeResult(User('alice', 'Alice'), Room('ABC123', '이전 방'));
  }

  @override
  Future<List<User>> listContacts() async => [];
  @override
  Future<RoomDetails> getRoom(String code) async {
    roomReads++;
    return RoomDetails(Room(code, '이전 방'), members);
  }

  @override
  Stream<RoomEvent> subscribeEvents(String code) {
    subscriptions++;
    // 실제 SSE처럼 구독 요청마다 생성한다. 새 실행에는 미구독 스트림이 없다.
    final stream = StreamController<RoomEvent>(onCancel: () async {});
    // 취소 후 done을 처음 읽을 때 root-zone nullFuture로 빠지는 것을 막는다.
    unawaited(stream.done);
    _streams.add(stream);
    return stream.stream;
  }
}

// 이 화면 경로의 미디어/마이크/통화 작업은 모두 메모리에서 끝난다.
// flutter_webrtc, unavo/noise, unavo/audio(/routes), unavo/call(/events)의
// 실제 초기화나 첫 이벤트를 기다리는 구독은 생성하지 않는다.
class _Media extends NoopMediaEngine {
  int joins = 0;
  final joined = Completer<void>();
  Future<void>? disposed;
  @override
  Future<void> join(String roomCode, String selfHandle) async {
    joins++;
    connectionChanged?.call(MediaConnectionState.connected, null);
    if (!joined.isCompleted) joined.complete();
  }

  @override
  Future<void> leave() async {}
  @override
  void setMuted(bool muted) {}
  @override
  Future<void> dispose() => disposed ??= super.dispose();
}

class _Mic extends MicRouter {
  _Mic(super.store) {
    permissions = const AudioPermissions(microphone: true);
  }
  @override
  Future<void> refreshPermissions() async {}
  @override
  Future<void> stopPreview() async {}
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
