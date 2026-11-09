import 'dart:async';
import 'dart:io';

// Match api_retry_test and sse_silence_timeout_test: no real sockets or waits.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/core/errors.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';

void main() {
  for (final stage in ['open', 'headers', 'body', 'error-body']) {
    test('$stage 타임아웃은 ApiException과 서버 응답 없음 문구를 전달한다', () {
      fakeAsync((clock) {
        final clients = <_Client>[];
        final api = ApiClient(
          tokenStore: _Store(),
          clientFactory: () {
            final client = _Client(stage);
            clients.add(client);
            return client;
          },
        );
        Object? failure;
        unawaited(
          api.createRoom().then<void>(
            (_) => fail('must time out'),
            onError: (Object error) {
              failure = error;
            },
          ),
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(milliseconds: 14999));
        expect(failure, isNull);
        clock.elapse(const Duration(milliseconds: 1));
        expect(failure, isA<ApiException>());
        expect((failure! as ApiException).code, 'timeout');
        expect(exceptionMessage(failure!, 'fallback'), '서버 응답 없음');
        expect(errorMessage(failure!), '서버 응답 없음');
        expect(clients, hasLength(1)); // Room creation is never replayed.
        expect(clients.single.closed, isTrue);
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }

  test('앱 타임아웃 예외로 바꿔도 GET의 1회 재시도를 유지한다', () {
    fakeAsync((clock) {
      final clients = <_Client>[];
      final api = ApiClient(
        tokenStore: _Store(),
        retryDelay: Duration.zero,
        clientFactory: () {
          final client = _Client('headers');
          clients.add(client);
          return client;
        },
      );
      Object? failure;
      unawaited(
        api.me().then<void>(
          (_) => fail('must time out'),
          onError: (Object error) {
            failure = error;
          },
        ),
      );
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 15));
      expect(clients, hasLength(2));
      expect(failure, isNull);
      clock.elapse(const Duration(seconds: 15));
      expect(exceptionMessage(failure!, 'fallback'), '서버 응답 없음');
      expect(clients.every((client) => client.closed), isTrue);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  for (final stage in ['open', 'headers', 'body', 'error-body']) {
    test('SSE $stage 타임아웃도 기존 재접속 경로와 취소를 유지한다', () {
      fakeAsync((clock) {
        final clients = <_Client>[];
        final api = ApiClient(
          tokenStore: _Store(),
          clientFactory: () {
            final client = _Client(stage);
            clients.add(client);
            return client;
          },
        );
        final events = <RoomEvent>[];
        final subscription = api.subscribeEvents('ABC123').listen(events.add);
        clock.flushMicrotasks();
        final seconds = stage == 'headers'
            ? 35
            : stage == 'body'
            ? 20
            : 15;
        clock.elapse(Duration(seconds: seconds));
        expect(events.whereType<Disconnected>(), hasLength(1));
        expect(clients.single.closed, isTrue);
        clock.elapse(const Duration(seconds: 2));
        expect(clients, hasLength(2));
        unawaited(subscription.cancel());
        clock.flushMicrotasks();
        // In-flight request futures still have their own bounded deadlines.
        clock.elapse(const Duration(seconds: 35));
        expect(clients.every((client) => client.closed), isTrue);
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }
}

class _Store implements TokenStore {
  @override
  String get token => 'test';
  @override
  String get baseUrl => 'https://example.invalid';
}

class _Client implements HttpClient {
  _Client(this.stage);
  final String stage;
  _Response? response;
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (stage == 'open') return Completer<HttpClientRequest>().future;
    return _Request(this);
  }

  @override
  void close({bool force = false}) {
    if (closed) return;
    closed = true;
    response?.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.client);
  final _Client client;
  @override
  HttpHeaders get headers => _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() async {
    if (client.stage == 'headers')
      return Completer<HttpClientResponse>().future;
    return client.response = _Response(
      client.stage == 'error-body' ? 500 : 200,
    );
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

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode) {
    unawaited(_bytes.done);
  }
  final _bytes = StreamController<List<int>>(onCancel: () async {});
  void close() => unawaited(_bytes.close());
  @override
  final int statusCode;
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
