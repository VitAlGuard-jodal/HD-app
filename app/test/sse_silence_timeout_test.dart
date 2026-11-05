import 'dart:async';
import 'dart:convert';
import 'dart:io';

// fake_async is already supplied by flutter_test.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';

void main() {
  test('기본 SSE 침묵 타임아웃은 20초다', () {
    expect(ApiClient.sseSilenceTimeout, const Duration(seconds: 20));
  });

  test('hello 이후 200ms 침묵하면 Disconnected를 보내고 재접속한다', () {
    fakeAsync((clock) {
      final f = _Fixture();
      try {
        clock.flushMicrotasks();
        expect(f.events, [isA<Hello>()]);
        expect(f.clients, hasLength(1));

        clock.elapse(const Duration(milliseconds: 199));
        expect(f.events.whereType<Disconnected>(), isEmpty);
        expect(f.clients.single.closed, isFalse);

        clock.elapse(const Duration(milliseconds: 1));
        expect(f.events, [isA<Hello>(), isA<Disconnected>()]);
        final disconnected = f.events.whereType<Disconnected>().single;
        expect(disconnected.retryInMillis, 2000);
        expect(f.clients.single.closed, isTrue);

        // 기존 SSE 재접속 대기도 실제로 기다리지 않고 가상 시간으로 넘긴다.
        clock.elapse(Duration(milliseconds: disconnected.retryInMillis - 1));
        expect(f.clients, hasLength(1));
        clock.elapse(const Duration(milliseconds: 1));
        expect(f.clients, hasLength(2));
        expect(f.clients.last.closed, isFalse);
        expect(f.events, [
          isA<Hello>(),
          isA<Disconnected>(),
          isA<Reconnected>(),
          isA<Hello>(),
        ]);
      } finally {
        f.dispose(clock);
      }
    });
  });

  test('침묵 타임아웃 안에 : ping이 오면 Disconnected 없이 연결을 유지한다', () {
    fakeAsync((clock) {
      final f = _Fixture();
      try {
        clock.flushMicrotasks();
        expect(f.events, [isA<Hello>()]);
        final client = f.clients.single;

        // hello 외 이벤트 없이도 원시 바이트 수신이 타임아웃을 갱신해야 한다.
        for (var i = 0; i < 5; i++) {
          clock.elapse(const Duration(milliseconds: 150));
          expect(f.events.whereType<Disconnected>(), isEmpty);
          client.response.send(': ping\n\n');
          clock.flushMicrotasks();
        }
        clock.elapse(const Duration(milliseconds: 199));
        expect(f.events.whereType<Disconnected>(), isEmpty);
        expect(f.events, [isA<Hello>()]);
        expect(f.clients, hasLength(1));
        expect(client.closed, isFalse);
      } finally {
        f.dispose(clock);
      }
    });
  });
}

class _Fixture {
  _Fixture() {
    final api = ApiClient(
      tokenStore: _Store(),
      sseSilenceTimeout: const Duration(milliseconds: 200),
      clientFactory: () {
        final client = _Client();
        clients.add(client);
        return client;
      },
    );
    subscription = api.subscribeEvents('ABC123').listen(events.add);
  }

  final clients = <_Client>[];
  final events = <RoomEvent>[];
  late final StreamSubscription<RoomEvent> subscription;

  void dispose(FakeAsync clock) {
    unawaited(subscription.cancel());
    clock.flushMicrotasks();
    expect(clients.every((client) => client.closed), isTrue);
    expect(clock.pendingTimers, isEmpty);
  }
}

class _Store implements TokenStore {
  @override
  String get token => 'fake';
  @override
  String get baseUrl => 'https://example.invalid';
}

class _Client implements HttpClient {
  final response = _Response();
  bool closed = false;

  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(response);

  @override
  void close({bool force = false}) {
    if (closed) return;
    closed = true;
    response.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final _Response response;

  @override
  HttpHeaders get headers => _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response() {
    // 완료·취소 Future를 fake_async 영역 안에 두어 정리까지 재현한다.
    unawaited(_bytes.done);
    send('event: hello\ndata: {"self":"alice","members":[]}\n\n');
  }

  final _bytes = StreamController<List<int>>(onCancel: () async {});

  void send(String text) => _bytes.add(utf8.encode(text));
  void close() => unawaited(_bytes.close());

  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _bytes.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
