import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';

void main() {
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
  _Client({this.failOpen = false, this.status = 200});
  final bool failOpen;
  final int status;
  bool closed = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (failOpen) throw const SocketException('cold connection');
    return _Request(status);
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
  _Request(this.status);
  final int status;
  @override
  HttpHeaders get headers => _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  void add(List<int> data) {}
  @override
  Future<HttpClientResponse> close() async => _Response(status);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode);
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
            statusCode == 200
                ? {
                    'room': {'code': 'ABC123'},
                    'members': <Object>[],
                  }
                : {
                    'error': {
                      'code': 'unauthorized',
                      'message': 'Unauthorized',
                    },
                  },
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
