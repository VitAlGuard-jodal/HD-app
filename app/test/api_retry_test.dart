import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';

void main() {
  test('me는 사용자와 선택적인 방을 읽고 기존 가입·로그인 모델은 유지한다', () async {
    const user = {'handle': 'alice', 'displayName': 'Alice'};
    for (final body in <JsonMap>[
      {'user': user, 'room': null},
      {'user': user}, // A server deployed before room restoration.
      {
        'user': user,
        'room': {
          'code': 'ABC123',
          'name': '이전 방',
          'createdBy': 'alice',
          'createdAt': '2026-11-04T00:00:00.000Z',
          'members': [
            {...user, 'joinedAt': '2026-11-04T00:00:00.000Z'},
          ],
        },
      },
    ]) {
      final api = ApiClient(
        tokenStore: _Store(),
        clientFactory: () => _Client(body: body),
      );
      final me = await api.me();
      expect(me.user.handle, 'alice');
      expect(me.user.displayName, 'Alice');
      expect(me.room?.code, body['room'] == null ? null : 'ABC123');
      expect(me.room?.name, body['room'] == null ? null : '이전 방');
    }
    final authApi = ApiClient(
      tokenStore: _Store(),
      clientFactory: () => _Client(body: {'user': user, 'token': 'auth-token'}),
    );
    for (final result in [
      await authApi.login('alice', 'password'),
      await authApi.signup('alice', 'password', 'Alice'),
    ]) {
      expect(result.user.handle, 'alice');
      expect(result.token, 'auth-token');
    }
  });

  test('첫 GET 전송 실패는 새 클라이언트로 1회 재시도한다', () async {
    var attempts = 0;
    final clients = <_Client>[];
    final api = ApiClient(
      tokenStore: _Store(),
      retryDelay: Duration.zero,
      clientFactory: () {
        final client = _Client(failOpen: attempts++ == 0);
        clients.add(client);
        return client;
      },
    );
    final room = await api.getRoom('ABC123');
    expect(room.room.code, 'ABC123');
    expect(attempts, 2);
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('방 참여만 재시도하고 방 생성·시그널·401은 반복하지 않는다', () async {
    var attempts = 0;
    ApiClient api() => ApiClient(
      tokenStore: _Store(),
      retryDelay: Duration.zero,
      clientFactory: () => _Client(failOpen: attempts++ == 0),
    );
    await api().joinRoom('ABC123');
    expect(attempts, 2);
    attempts = 0;
    await expectLater(api().createRoom(), throwsA(isA<SocketException>()));
    expect(attempts, 1);
    attempts = 0;
    await expectLater(
      api().sendSignal('ABC123', 'bob', 'offer', {}),
      throwsA(isA<SocketException>()),
    );
    expect(attempts, 1);
    attempts = 0;
    final unauthorized = ApiClient(
      tokenStore: _Store(),
      retryDelay: Duration.zero,
      clientFactory: () {
        attempts++;
        return _Client(status: 401);
      },
    );
    await expectLater(
      unauthorized.getRoom('ABC123'),
      throwsA(isA<ApiException>()),
    );
    expect(attempts, 1);
  });
}

class _Store implements TokenStore {
  @override
  String get token => 'fake';
  @override
  String get baseUrl => 'https://example.invalid';
}

class _Client implements HttpClient {
  _Client({this.failOpen = false, this.status = 200, this.body});
  final bool failOpen;
  final int status;
  final JsonMap? body;
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (failOpen) throw const SocketException('cold connection');
    return _Request(status, body);
  }

  @override
  void close({bool force = false}) {
    closed = true;
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
  _Request(this.status, this.body);
  final int status;
  final JsonMap? body;
  @override
  HttpHeaders get headers => _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() async => _Response(status, body);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.body);
  final JsonMap? body;
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream.value(
        utf8.encode(
          jsonEncode(
            body ??
                (statusCode == 200
                    ? {
                        'room': {'code': 'ABC123'},
                        'members': <Object>[],
                      }
                    : {
                        'error': {
                          'code': 'unauthorized',
                          'message': 'Unauthorized',
                        },
                      }),
          ),
        ),
      ).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
