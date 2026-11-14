import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Match api_retry_test and sse_silence_timeout_test: no real sockets or waits.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/core/errors.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';

void main() {
  test(
    'R16.2 malformed location response completes once and cancels its body',
    () {
      fakeAsync((clock) {
        final client = _Client('body');
        final api = ApiClient(
          tokenStore: _Store(),
          clientFactory: () => client,
        );
        Object? failure;
        unawaited(
          api
              .sendLocation(
                'ABC123',
                const LocationFix(
                  handle: 'self',
                  stream: '1111111111111111',
                  seq: 0,
                  lat: 0,
                  lng: 0,
                  at: 1000,
                  acc: 2,
                ),
              )
              .then<void>(
                (_) => fail('invalid UTF-8 must fail'),
                onError: (Object error) => failure = error,
              ),
        );
        clock.flushMicrotasks();
        final response = client.requests.single.response!;
        response._bytes.add([0xff]);
        response.close();
        clock.flushMicrotasks();
        expect(failure, isA<FormatException>());
        expect(response.cancelled, isTrue);
        expect(clock.pendingTimers, isEmpty);
        api.close();
      });
    },
  );
  for (final stage in [
    'open',
    'headers',
    'body',
    'error-body',
    'delayed-body',
  ]) {
    test('R16.2 location POST $stage has a five-second deadline', () {
      fakeAsync((clock) {
        final client = _Client(stage);
        final api = ApiClient(
          tokenStore: _Store(),
          clientFactory: () => client,
        );
        Object? failure;
        unawaited(
          api
              .sendLocation(
                'ABC123',
                const LocationFix(
                  handle: 'self',
                  stream: '1111111111111111',
                  seq: 0,
                  lat: 0,
                  lng: 0,
                  at: 1000,
                  acc: 2,
                ),
              )
              .then<void>(
                (_) => fail('must time out'),
                onError: (Object error) => failure = error,
              ),
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(milliseconds: 4999));
        expect(failure, isNull);
        clock.elapse(const Duration(milliseconds: 1));
        expect(
          failure,
          isA<ApiException>().having((e) => e.code, 'code', 'timeout'),
        );
        expect(client.closed, isFalse, reason: 'keep the shared HTTP pool');
        expect(client.opens, 1, reason: 'POST is not automatically replayed');
        if (stage == 'body' ||
            stage == 'error-body' ||
            stage == 'delayed-body') {
          expect(client.requests.single.response!.cancelled, isTrue);
        }
        if (stage == 'open') {
          client.openGate!.complete(client.requests.single);
          clock.flushMicrotasks();
        }
        expect(client.requests.single.aborted, isTrue);
        api.close();
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }
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
        final client = clients.single;
        expect(client.opens, 1);
        expect(client.closed, isFalse);
        if (stage == 'headers') {
          expect(client.requests.single.aborted, isTrue);
          expect(client.requests.single.abortError, same(failure));
        } else if (stage == 'body' || stage == 'error-body') {
          expect(client.requests.single.response!.cancelled, isTrue);
          expect(client.requests.single.aborted, isFalse);
        }
        api.close();
        clock.flushMicrotasks();
        expect(client.closed, isTrue);
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
      expect(clients.single.opens, 2);
      expect(failure, isNull);
      clock.elapse(const Duration(seconds: 15));
      expect(exceptionMessage(failure!, 'fallback'), '서버 응답 없음');
      expect(clients.single.closed, isFalse);
      expect(
        clients.single.requests.every((request) => request.aborted),
        isTrue,
      );
      api.close();
      expect(clients.single.closed, isTrue);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  for (final lateError in [false, true]) {
    test('open 타임아웃 뒤 늦은 ${lateError ? '실패는 무시한다' : '요청은 그 요청만 abort한다'}', () {
      fakeAsync((clock) {
        final client = _Client('open');
        final api = ApiClient(
          tokenStore: _Store(),
          clientFactory: () => client,
        );
        Object? failure;
        unawaited(
          api.createRoom().then<void>(
            (_) => fail('must time out'),
            onError: (Object error) => failure = error,
          ),
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 15));
        expect(failure, isA<ApiException>());
        expect(client.closed, isFalse);
        final request = client.requests.single;
        expect(request.aborted, isFalse);
        if (lateError) {
          client.openGate!.completeError(const SocketException('late failure'));
        } else {
          client.openGate!.complete(request);
        }
        clock.flushMicrotasks();
        expect(request.aborted, !lateError);
        if (!lateError) expect(request.abortError, same(failure));
        expect(client.closed, isFalse);
        expect(clock.pendingTimers, isEmpty);
        api.close();
      });
    });
  }

  test('한 요청의 타임아웃은 같은 클라이언트의 다른 진행 중 요청을 끊지 않는다', () {
    fakeAsync((clock) {
      final clients = <_Client>[];
      final api = ApiClient(
        tokenStore: _Store(),
        clientFactory: () {
          final client = _Client('headers', nextStage: 'success');
          clients.add(client);
          return client;
        },
      );
      Object? failureA, failureB;
      Room? resultB;
      unawaited(
        api.createRoom().then<void>(
          (_) => fail('A must time out'),
          onError: (Object error) => failureA = error,
        ),
      );
      unawaited(
        api.createRoom().then<void>(
          (room) => resultB = room,
          onError: (Object error) => failureB = error,
        ),
      );
      clock.flushMicrotasks();
      final client = clients.single;
      expect(client.opens, 2);
      expect(resultB, isNull);
      clock.elapse(const Duration(seconds: 1));
      expect(resultB?.code, 'ABC123');
      expect(failureA, isNull);
      clock.elapse(const Duration(seconds: 14));
      expect(
        failureA,
        isA<ApiException>().having((e) => e.code, 'code', 'timeout'),
      );
      expect(failureB, isNull);
      expect(resultB?.code, 'ABC123');
      expect(client.closed, isFalse);
      expect(client.requests.first.aborted, isTrue);
      expect(client.requests.last.aborted, isFalse);
      expect(clock.pendingTimers, isEmpty);
      api.close();
    });
  });

  for (final stage in ['open', 'headers', 'body', 'error-body']) {
    test('아바타 $stage 타임아웃도 공유 클라이언트 대신 해당 요청만 정리한다', () {
      fakeAsync((clock) {
        final clients = <_Client>[];
        final api = ApiClient(
          tokenStore: _Store(),
          clientFactory: () {
            final client = _Client(stage, nextStage: 'success');
            clients.add(client);
            return client;
          },
        );
        Object? failure;
        unawaited(
          api
              .avatarPhoto('alice', 1)
              .then<void>(
                (_) => fail('must time out'),
                onError: (Object error) => failure = error,
              ),
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 15));
        expect(
          failure,
          isA<ApiException>().having((e) => e.code, 'code', 'timeout'),
        );
        final client = clients.single;
        expect(client.closed, isFalse);
        if (stage == 'headers') {
          expect(client.requests.single.aborted, isTrue);
          expect(client.requests.single.abortError, same(failure));
        } else if (stage == 'body' || stage == 'error-body') {
          expect(client.requests.single.response!.cancelled, isTrue);
        }
        Room? room;
        unawaited(api.createRoom().then((value) => room = value));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 1));
        expect(room?.code, 'ABC123');
        expect(clients.single.opens, 2);
        expect(client.closed, isFalse);
        api.close();
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    });
  }

  test('HTTP 타임아웃과 close는 별도 SSE 클라이언트를 닫지 않는다', () {
    fakeAsync((clock) {
      final clients = <_Client>[];
      final api = ApiClient(
        tokenStore: _Store(),
        clientFactory: () {
          final client = _Client(clients.isEmpty ? 'body' : 'headers');
          clients.add(client);
          return client;
        },
      );
      final events = <RoomEvent>[];
      final subscription = api.subscribeEvents('ABC123').listen(events.add);
      clock.flushMicrotasks();
      final sse = clients.single;
      Object? failure;
      unawaited(
        api.createRoom().then<void>(
          (_) => fail('must time out'),
          onError: (Object error) => failure = error,
        ),
      );
      clock.flushMicrotasks();
      expect(clients, hasLength(2));
      clock.elapse(const Duration(seconds: 15));
      expect(failure, isA<ApiException>());
      expect(clients.last.requests.single.aborted, isTrue);
      expect(clients.last.closed, isFalse);
      api.close();
      expect(clients.last.closed, isTrue);
      expect(sse.closed, isFalse);
      expect(sse.requests.single.response!.cancelled, isFalse);
      expect(events, isEmpty);
      unawaited(subscription.cancel());
      clock.flushMicrotasks();
      expect(sse.closed, isTrue);
      expect(sse.requests.single.response!.cancelled, isTrue);
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
  _Client(this.stage, {this.nextStage});
  final String stage;
  final String? nextStage;
  int opens = 0;
  final requests = <_Request>[];
  Completer<HttpClientRequest>? openGate;
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (closed) throw StateError('client is closed');
    final currentStage = opens++ == 0 ? stage : nextStage ?? stage;
    final request = _Request(this, currentStage);
    requests.add(request);
    if (currentStage == 'open') {
      openGate = Completer<HttpClientRequest>();
      return openGate!.future;
    }
    return request;
  }

  @override
  void close({bool force = false}) {
    if (closed) return;
    closed = true;
    for (final request in requests) {
      request.response?.close();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.client, this.stage);
  final _Client client;
  final String stage;
  _Response? response;
  bool aborted = false;
  Object? abortError;
  Completer<HttpClientResponse>? _headers;
  @override
  HttpHeaders get headers => _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() async {
    if (stage == 'delayed-body') {
      await Future<void>.delayed(const Duration(seconds: 4));
      return response = _Response(200);
    }
    if (stage == 'headers') {
      _headers = Completer<HttpClientResponse>();
      return _headers!.future;
    }
    if (stage == 'success') {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (client.closed) throw const SocketException('client was closed');
      return response = _Response(
        200,
        body: {
          'room': {'code': 'ABC123'},
        },
      );
    }
    return response = _Response(stage == 'error-body' ? 500 : 200);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
    abortError = exception;
    final headers = _headers;
    if (headers != null && !headers.isCompleted) {
      headers.completeError(
        exception ?? const HttpException('aborted'),
        stackTrace,
      );
    }
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
  _Response(this.statusCode, {JsonMap? body}) {
    _bytes = StreamController<List<int>>(
      onCancel: () async {
        cancelled = true;
      },
    );
    unawaited(_bytes.done);
    if (body != null) {
      _bytes.add(utf8.encode(jsonEncode(body)));
      close();
    }
  }
  late final StreamController<List<int>> _bytes;
  bool cancelled = false;
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
