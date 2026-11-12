import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/models.dart';

import 'support/avatar_fakes.dart';

void main() {
  test('사진 404는 같은 오류를 30초 캐시하고 만료 후 한 번만 재요청한다', () async {
    // 페이크 응답 본문은 fakeAsync 가 돌리지 못하므로 실제 await 와 주입한 시각으로 검사한다.
    final http = AvatarTestHttp()..status = 404;
    var now = DateTime.utc(2026);
    final api = ApiClient(
      tokenStore: AvatarTestTokenStore(),
      clientFactory: http.createClient,
      avatarNow: () => now,
    );
    addTearDown(api.close);
    final errors = <Object>[];
    Future<void> read() async {
      try {
        await api.avatarPhoto('alice', 1);
        fail('404 응답이 성공하면 안 된다');
      } on ApiException catch (error) {
        errors.add(error);
      }
    }

    await read();
    expect(http.requests, hasLength(1));
    expect(
      errors.single,
      isA<ApiException>().having((error) => error.status, 'status', 404),
    );
    for (var i = 0; i < 5; i++) {
      await read();
    }
    now = now.add(const Duration(seconds: 29));
    await read();
    expect(http.requests, hasLength(1));
    expect(errors.every((error) => identical(error, errors.first)), isTrue);
    now = now.add(const Duration(seconds: 1));
    await read();
    expect(http.requests, hasLength(2));
    expect(errors.last, isNot(same(errors.first)));
  });

  test('사진 실패 캐시는 서버·토큰·버전 변경과 64개 상한을 지킨다', () {
    fakeAsync((clock) {
      final store = AvatarTestTokenStore();
      final http = AvatarTestHttp()..status = 404;
      final api = ApiClient(
        tokenStore: store,
        clientFactory: http.createClient,
        avatarNow: () => DateTime.utc(2026).add(clock.elapsed),
      );
      void read(String handle, int version) {
        unawaited(
          api
              .avatarPhoto(handle, version)
              .then<void>(
                (_) => fail('404 응답이 성공하면 안 된다'),
                onError: (Object _) {},
              ),
        );
        clock.flushMicrotasks();
      }

      read('alice', 1);
      read('alice', 2);
      store.token = 'new-token';
      read('alice', 2);
      store.baseUrl = 'https://new.example.invalid';
      read('alice', 2);
      expect(http.requests, hasLength(4));
      for (var i = 0; i < 64; i++) read('member$i', 1);
      final count = http.requests.length;
      read('member63', 1);
      expect(http.requests, hasLength(count));
      read('alice', 2);
      expect(
        http.requests,
        hasLength(count + 1),
        reason: '65번째 키는 가장 오래된 실패 항목을 밀어낸다',
      );
      api.close();
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('me는 사용자·방·동의를 읽고 consent가 없는 옛 서버와 호환된다', () async {
    const user = {'handle': 'alice', 'displayName': 'Alice'};
    for (final body in <JsonMap>[
      {'user': user, 'room': null},
      {'user': user}, // A server deployed before room restoration.
      {
        'user': user,
        'consent': {'privacy': null, 'location': null},
      },
      {
        'user': user,
        'consent': {
          'privacy': {'version': '3', 'at': '2026-11-12T00:00:00.000Z'},
          'location': {'version': '2', 'at': '2026-11-11T00:00:00.000Z'},
        },
      },
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
      final clients = <_Client>[];
      final api = ApiClient(
        tokenStore: _Store(),
        clientFactory: () {
          final client = _Client(body: body);
          clients.add(client);
          return client;
        },
      );
      addTearDown(api.close);
      final me = await api.me();
      expect(me.user.handle, 'alice');
      expect(me.user.displayName, 'Alice');
      expect(me.room?.code, body['room'] == null ? null : 'ABC123');
      expect(me.room?.name, body['room'] == null ? null : '이전 방');
      final consent = body['consent'] as JsonMap?;
      if (consent == null) {
        expect(me.consent, isNull);
      } else {
        expect(me.consent, isNotNull);
        expect(me.consent!.privacy?.version, consent['privacy']?['version']);
        expect(me.consent!.privacy?.at, consent['privacy']?['at']);
        expect(me.consent!.location?.version, consent['location']?['version']);
        expect(me.consent!.location?.at, consent['location']?['at']);
      }
      expect(clients.single.opens, 1);
      expect(clients.single.closed, isFalse);
      api.close();
      expect(clients.single.closed, isTrue);
    }
    final authClients = <_Client>[];
    final authApi = ApiClient(
      tokenStore: _Store(),
      clientFactory: () {
        final client = _Client(body: {'user': user, 'token': 'auth-token'});
        authClients.add(client);
        return client;
      },
    );
    addTearDown(authApi.close);
    for (final result in [
      await authApi.login('alice', 'password'),
      await authApi.signup('alice', 'password', 'Alice'),
    ]) {
      expect(result.user.handle, 'alice');
      expect(result.token, 'auth-token');
    }
    expect(authClients.single.opens, 2);
    expect(authClients.single.closed, isFalse);
    authApi.close();
    expect(authClients.single.closed, isTrue);
  });

  test('첫 GET 전송 실패는 같은 클라이언트로 1회 재시도한다', () async {
    final clients = <_Client>[];
    final api = ApiClient(
      tokenStore: _Store(),
      retryDelay: Duration.zero,
      clientFactory: () {
        final client = _Client(failFirstOpen: true);
        clients.add(client);
        return client;
      },
    );
    addTearDown(api.close);
    final room = await api.getRoom('ABC123');
    expect(room.room.code, 'ABC123');
    expect(clients.single.opens, 2);
    expect(clients.single.closed, isFalse);
    api.close();
    expect(clients.single.closed, isTrue);
  });

  test('방 참여만 재시도하고 방 생성·시그널·동의 PUT·401은 반복하지 않는다', () async {
    for (final action in [
      'join',
      'create',
      'signal',
      'consent',
      'unauthorized',
    ]) {
      final clients = <_Client>[];
      final api = ApiClient(
        tokenStore: _Store(),
        retryDelay: Duration.zero,
        clientFactory: () {
          final client = _Client(
            failFirstOpen: action != 'unauthorized',
            status: action == 'unauthorized' ? 401 : 200,
          );
          clients.add(client);
          return client;
        },
      );
      addTearDown(api.close);
      switch (action) {
        case 'join':
          await api.joinRoom('ABC123');
        case 'create':
          await expectLater(api.createRoom(), throwsA(isA<SocketException>()));
        case 'signal':
          await expectLater(
            api.sendSignal('ABC123', 'bob', 'offer', {}),
            throwsA(isA<SocketException>()),
          );
        case 'consent':
          await expectLater(
            api.recordConsent(privacyVersion: '3'),
            throwsA(isA<SocketException>()),
          );
        case 'unauthorized':
          await expectLater(
            api.getRoom('ABC123'),
            throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
          );
      }
      expect(clients.single.opens, action == 'join' ? 2 : 1);
      expect(clients.single.closed, isFalse);
      api.close();
      expect(clients.single.closed, isTrue);
    }
  });

  test('recordConsent는 두 버전이 모두 없으면 요청 없이 ArgumentError를 반환한다', () async {
    final clients = <_Client>[];
    final api = ApiClient(
      tokenStore: _Store(),
      clientFactory: () {
        final client = _Client();
        clients.add(client);
        return client;
      },
    );
    addTearDown(api.close);
    await expectLater(api.recordConsent(), throwsArgumentError);
    expect(clients, isEmpty);
  });

  test('위치 전송을 20회 보내도 HttpClient 는 1개를 재사용한다', () async {
    final clients = <_Client>[];
    final api = ApiClient(
      tokenStore: _Store(),
      clientFactory: () {
        final client = _Client(body: {'dropped': false});
        clients.add(client);
        return client;
      },
    );
    addTearDown(api.close);
    expect(clients, isEmpty);
    for (var seq = 0; seq < 20; seq++) {
      expect(
        await api.sendLocation(
          'ABC123',
          LocationFix(
            handle: 'alice',
            stream: '0123456789abcdef',
            lat: 37,
            lng: 127,
            at: 1000 + seq * 1000,
            seq: seq,
          ),
        ),
        isFalse,
      );
    }
    expect(clients.single.opens, 20);
    expect(clients.single.closed, isFalse);
    api.close();
    expect(clients.single.closed, isTrue);
  });

  test('close() 뒤 다음 요청은 새 클라이언트를 만든다', () async {
    final clients = <_Client>[];
    final api = ApiClient(
      tokenStore: _Store(),
      clientFactory: () {
        final client = _Client();
        clients.add(client);
        return client;
      },
    );
    addTearDown(api.close);
    api.close();
    expect(clients, isEmpty);
    await api.getRoom('ABC123');
    expect(clients.single.closed, isFalse);
    api.close();
    api.close();
    expect(clients.single.closed, isTrue);
    await api.getRoom('ABC123');
    expect(clients, hasLength(2));
    expect(clients.first.opens, 1);
    expect(clients.last.opens, 1);
    expect(clients.last.closed, isFalse);
    api.close();
    expect(clients.last.closed, isTrue);
  });
}

class _Store implements TokenStore {
  @override
  String get token => 'fake';
  @override
  String get baseUrl => 'https://example.invalid';
}

class _Client implements HttpClient {
  _Client({this.failFirstOpen = false, this.status = 200, this.body});
  final bool failFirstOpen;
  final int status;
  final JsonMap? body;
  bool closed = false;
  int opens = 0;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (closed) throw StateError('client is closed');
    opens++;
    if (failFirstOpen && opens == 1)
      throw const SocketException('cold connection');
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
