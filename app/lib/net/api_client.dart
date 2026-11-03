import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../auth/session_store.dart';
import '../core/server_address.dart';
import 'models.dart';
import 'sse_parser.dart';

class ApiClient {
  ApiClient({
    required this.tokenStore,
    this.allowPrivateCleartext = kDebugMode,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;
  final TokenStore tokenStore;
  final bool allowPrivateCleartext;
  final HttpClient Function() _clientFactory;
  static const _timeout = Duration(seconds: 15);

  Future<AuthResult> signup(
    String handle,
    String password,
    String displayName,
  ) => _auth('/v1/auth/signup', {
    'handle': handle,
    'password': password,
    'displayName': displayName,
  });
  Future<AuthResult> login(String handle, String password) =>
      _auth('/v1/auth/login', {'handle': handle, 'password': password});
  Future<void> logout() async {
    await _request('POST', '/v1/auth/logout');
  }

  Future<User> me() async =>
      User.fromJson((await _response('GET', '/v1/me'))['user'] as JsonMap);
  Future<IceServerCredentials> fetchIceServers() async =>
      IceServerCredentials.fromJson(await _response('GET', '/v1/turn'));
  Future<User> getUser(String handle) async => User.fromJson(
    (await _response('GET', '/v1/users/${_segment(handle)}'))['user']
        as JsonMap,
  );
  Future<User> updateDisplayName(String displayName) async => User.fromJson(
    (await _response('PATCH', '/v1/me', {'displayName': displayName}))['user']
        as JsonMap,
  );
  Future<List<User>> listContacts() async {
    final result = await _response('GET', '/v1/contacts');
    return (result['contacts'] as List<dynamic>)
        .map((v) => User.fromJson(v as JsonMap))
        .toList();
  }

  Future<User> addContact(String handle) async => User.fromJson(
    (await _response('POST', '/v1/contacts', {'handle': handle}))['contact']
        as JsonMap,
  );
  Future<void> removeContact(String handle) async {
    await _request('DELETE', '/v1/contacts/${_segment(handle)}');
  }

  Future<Room> createRoom({
    String? name,
    List<String> invitees = const [],
  }) async {
    final body = <String, Object?>{
      if (name != null && name.trim().isNotEmpty) 'name': name,
      if (invitees.isNotEmpty) 'invitees': invitees,
    };
    return Room.fromJson(
      (await _response('POST', '/v1/rooms', body))['room'] as JsonMap,
    );
  }

  Future<RoomDetails> getRoom(String code) async {
    final result = await _response('GET', '/v1/rooms/${_segment(code)}');
    return RoomDetails(
      Room.fromJson(result['room'] as JsonMap),
      (result['members'] as List<dynamic>)
          .map((v) => Member.fromJson(v as JsonMap))
          .toList(),
    );
  }

  Future<Room> joinRoom(String code) async => Room.fromJson(
    (await _response('POST', '/v1/rooms/${_segment(code)}/join'))['room']
        as JsonMap,
  );
  Future<void> leaveRoom(String code) async {
    await _request('POST', '/v1/rooms/${_segment(code)}/leave');
  }

  Future<void> sendSignal(
    String code,
    String to,
    String kind,
    Object? payload,
  ) async {
    if (!{'offer', 'answer', 'ice', 'custom'}.contains(kind)) {
      throw const FormatException('지원하지 않는 시그널 종류입니다.');
    }
    await _request('POST', '/v1/rooms/${_segment(code)}/signal', {
      'to': to,
      'kind': kind,
      'payload': payload,
    });
  }

  // 서버는 refresh-token API를 제공하지 않는다. 매 요청/재연결마다 현재
  // TokenStore 값을 읽고, 폐기된 토큰의 401은 재시도 없이 상위에 전달한다.
  Stream<RoomEvent> subscribeEvents(String code) {
    late StreamController<RoomEvent> controller;
    HttpClient? currentClient;
    Timer? retryTimer;
    Completer<void>? retryWait;
    var cancelled = false;

    Future<void> read() async {
      var wasConnected = false;
      var backoff = 2000;
      while (!cancelled) {
        final client = _clientFactory()..connectionTimeout = _timeout;
        currentClient = client;
        Stopwatch? connected;
        try {
          final request = await _open(
            client,
            'GET',
            '/v1/rooms/${_segment(code)}/events',
          );
          request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          final response = await request.close().timeout(
            const Duration(seconds: 35),
          );
          if (cancelled) break;
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw await _responseError(response);
          }
          connected = Stopwatch()..start();
          if (wasConnected) controller.add(const Reconnected());
          wasConnected = true;
          final parser = SseParser();
          // 타임아웃을 원시 바이트에 적용하여 : ping도 연결 생존으로 센다.
          final lines = response
              .timeout(const Duration(seconds: 35))
              .transform(utf8.decoder)
              .transform(const LineSplitter());
          await for (final line in lines) {
            if (cancelled) break;
            final event = parser.accept(line);
            if (event == null) continue;
            final decoded = _decode(event);
            if (decoded != null) controller.add(decoded);
          }
          if (!cancelled) throw const SocketException('서버 연결이 끊겼습니다.');
        } catch (error, stack) {
          if (cancelled) break;
          if (error is ApiException && {401, 403, 404}.contains(error.status)) {
            controller.addError(error, stack);
            break;
          }
          if (connected != null && connected.elapsedMilliseconds >= 15000)
            backoff = 2000;
          controller.add(Disconnected('연결을 다시 시도합니다.', backoff));
        } finally {
          client.close(force: true);
          if (identical(currentClient, client)) currentClient = null;
        }
        if (cancelled) break;
        final wait = Completer<void>();
        retryWait = wait;
        retryTimer = Timer(Duration(milliseconds: backoff), () {
          if (!wait.isCompleted) wait.complete();
        });
        await wait.future;
        retryWait = null;
        retryTimer = null;
        backoff = (backoff * 2).clamp(2000, 30000).toInt();
      }
      if (!controller.isClosed) unawaited(controller.close());
    }

    controller = StreamController<RoomEvent>(
      onListen: () {
        unawaited(read());
      },
      onCancel: () {
        cancelled = true;
        currentClient?.close(force: true);
        retryTimer?.cancel();
        final wait = retryWait;
        if (wait != null && !wait.isCompleted) wait.complete();
      },
    );
    return controller.stream;
  }

  Future<AuthResult> _auth(String path, JsonMap body) async {
    final result = await _response('POST', path, body);
    return AuthResult(
      User.fromJson(result['user'] as JsonMap),
      result['token'] as String,
    );
  }

  Future<JsonMap> _response(
    String method,
    String path, [
    JsonMap? body,
  ]) async =>
      await _request(method, path, body) ??
      (throw const ApiException(0, 'empty_response', '서버 응답이 비어 있습니다.'));

  Future<JsonMap?> _request(String method, String path, [JsonMap? body]) async {
    final client = _clientFactory()..connectionTimeout = _timeout;
    try {
      final request = await _open(client, method, path);
      if (body != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw await _responseError(response);
      final text = await response
          .timeout(_timeout)
          .transform(utf8.decoder)
          .join();
      if (response.statusCode == 204 || text.trim().isEmpty) return null;
      try {
        final value = jsonDecode(text);
        if (value is JsonMap) return value;
      } on FormatException {
        // 동일한 invalid_response 오류로 처리한다.
      }
      throw ApiException(
        response.statusCode,
        'invalid_response',
        '서버 응답 형식을 확인해 주세요.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientRequest> _open(
    HttpClient client,
    String method,
    String path,
  ) async {
    final base = ServerAddress.normalize(
      tokenStore.baseUrl,
      allowPrivateCleartext: allowPrivateCleartext,
    );
    final request = await client
        .openUrl(method, Uri.parse('$base$path'))
        .timeout(_timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final token = tokenStore.token;
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    return request;
  }

  Future<ApiException> _responseError(HttpClientResponse response) async {
    final text = await response
        .timeout(_timeout)
        .transform(utf8.decoder)
        .join();
    JsonMap? json;
    try {
      final value = jsonDecode(text);
      if (value is JsonMap) json = value;
    } on FormatException {
      /* 비 JSON 오류 응답은 HTTP 문구를 사용한다. */
    }
    final nested = json?['error'];
    final error = nested is JsonMap ? nested : json;
    String? nonblank(Object? value) =>
        value is String && value.trim().isNotEmpty ? value : null;
    return ApiException(
      response.statusCode,
      nonblank(error?['code']) ?? 'http_${response.statusCode}',
      nonblank(error?['message']) ??
          nonblank(nested) ??
          '서버 요청에 실패했습니다. (HTTP ${response.statusCode})',
    );
  }

  RoomEvent? _decode(SseEvent event) {
    if (!{
      'hello',
      'member-joined',
      'member-left',
      'signal',
    }.contains(event.name))
      return null;
    final data = jsonDecode(event.data) as JsonMap;
    switch (event.name) {
      case 'hello':
        final self = data['self'];
        return Hello(
          self is JsonMap
              ? self['handle'] as String? ?? ''
              : self as String? ?? '',
          (data['members'] as List<dynamic>? ?? [])
              .map((value) => Member.fromJson(value as JsonMap))
              .toList(),
        );
      case 'member-joined':
        return MemberJoined(data['handle'] as String);
      case 'member-left':
        return MemberLeft(data['handle'] as String);
      case 'signal':
        return Signal(
          data['from'] as String,
          data['kind'] as String,
          data['payload'],
        );
    }
    return null;
  }

  static String _segment(String value) => Uri.encodeComponent(value);
}
