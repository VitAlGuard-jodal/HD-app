import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../auth/session_store.dart';
import '../core/server_address.dart';
import 'models.dart';
import 'follow_route.dart';
import 'sse_parser.dart';

class _AvatarPhotoEntry {
  late final Future<Uint8List> pending;
  ({DateTime at, Object error, StackTrace stack})? failure;
}

class ApiClient {
  ApiClient({
    required this.tokenStore,
    this.allowPrivateCleartext = kDebugMode,
    this.retryDelay = const Duration(milliseconds: 400),
    Duration? sseSilenceTimeout,
    HttpClient Function()? clientFactory,
    DateTime Function()? avatarNow,
  }) : _sseSilenceTimeout = sseSilenceTimeout ?? ApiClient.sseSilenceTimeout,
       _avatarNow = avatarNow ?? DateTime.now,
       _clientFactory = clientFactory ?? HttpClient.new;
  final TokenStore tokenStore;
  // One identity per app process, shared by HTTP and every SSE retry. The
  // authentication token additionally scopes it on the server.
  final String deviceId = List.generate(
    16,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final bool allowPrivateCleartext;
  final Duration retryDelay;
  final Duration _sseSilenceTimeout;
  final HttpClient Function() _clientFactory;
  final DateTime Function() _avatarNow;
  HttpClient? _shared;
  HttpClient get _client =>
      _shared ??= (_clientFactory()..connectionTimeout = _timeout);

  void close() {
    _shared?.close(force: true);
    _shared = null;
  }

  static const _timeout = Duration(seconds: 15);
  static const _timeoutError = ApiException(0, 'timeout', '서버 응답 없음');
  static Never _onTimeout() => throw _timeoutError;
  static void _onStreamTimeout(EventSink<List<int>> sink) {
    sink.addError(_timeoutError);
    sink.close();
  }

  // 서버 ping 15초 + 여유 5초
  static const sseSilenceTimeout = Duration(seconds: 20);

  Future<FollowRouteResult> followRoute(
    String code,
    FollowRouteRequest body,
    RouteCancellation cancellation,
  ) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 8);
    var finished = false;
    final cancelled = cancellation.whenCancelled.then<FollowRouteResult>((_) {
      if (!finished) client.close(force: true);
      throw const FollowRouteException('CANCELLED');
    });
    Future<FollowRouteResult> read() async {
      if (cancellation.isCancelled)
        throw const FollowRouteException('CANCELLED');
      final base = ServerAddress.normalize(
        tokenStore.baseUrl,
        allowPrivateCleartext: allowPrivateCleartext,
      );
      final request = await client.openUrl(
        'POST',
        Uri.parse('$base/v1/rooms/${_segment(code)}/follow-route'),
      );
      if (finished || cancellation.isCancelled) {
        request.abort();
        throw const FollowRouteException('CANCELLED');
      }
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('x-unavo-device', deviceId);
      final token = tokenStore.token;
      if (token != null)
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.add(utf8.encode(jsonEncode(body.toJson())));
      final response = await request.close();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (finished || cancellation.isCancelled)
          throw const FollowRouteException('CANCELLED');
        bytes.add(chunk);
        if (bytes.length > 2 * 1024 * 1024)
          throw const FollowRouteException('ROUTE_TOO_LARGE');
      }
      final json = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (json is! JsonMap) throw const FormatException();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FollowRouteException.fromJson(json);
      }
      return FollowRouteResult.fromJson(json, body);
    }

    try {
      return await Future.any([read(), cancelled]).timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          client.close(force: true);
          throw const FollowRouteException('ROUTE_TIMEOUT', retryable: true);
        },
      );
    } on FollowRouteException {
      rethrow;
    } on FormatException {
      throw const FollowRouteException('INVALID_PROVIDER_RESPONSE');
    } catch (_) {
      // Never expose an HTTP exception's URL, coordinates or provider body.
      if (cancellation.isCancelled)
        throw const FollowRouteException('CANCELLED');
      throw const FollowRouteException('PROVIDER_UNAVAILABLE', retryable: true);
    } finally {
      finished = true;
      client.close(force: true);
    }
  }

  final _avatarPhotos = <(String, String?, String, int), _AvatarPhotoEntry>{};

  Future<User> updateAvatar(String kind, {Uint8List? png}) async =>
      User.fromJson(
        (await _response('PUT', '/v1/me/avatar', {
              'kind': kind,
              if (png != null) 'png': base64Encode(png),
            }))['user']
            as JsonMap,
      );

  Future<User> deleteAvatar() async => User.fromJson(
    (await _response('DELETE', '/v1/me/avatar'))['user'] as JsonMap,
  );

  // 인증 세션·서버·버전까지 분리한다. 실패도 같은 키에서는 30초간 재사용한다.
  Future<Uint8List> avatarPhoto(String handle, int version) {
    final key = (tokenStore.baseUrl, tokenStore.token, handle, version);
    final cached = _avatarPhotos[key];
    if (cached != null) {
      final failure = cached.failure;
      if (failure == null) return cached.pending;
      if (_avatarNow().difference(failure.at) < const Duration(seconds: 30)) {
        return Future<Uint8List>.error(failure.error, failure.stack);
      }
    }
    _avatarPhotos.removeWhere(
      (old, _) => old.$1 != key.$1 || old.$2 != key.$2 || old.$3 == handle,
    );
    if (_avatarPhotos.length >= 64)
      _avatarPhotos.remove(_avatarPhotos.keys.first);
    final entry = _AvatarPhotoEntry();
    entry.pending = _readAvatar(handle, version).catchError((
      Object error,
      StackTrace stack,
    ) {
      entry.failure = (at: _avatarNow(), error: error, stack: stack);
      Error.throwWithStackTrace(error, stack);
    });
    _avatarPhotos[key] = entry;
    return entry.pending;
  }

  Future<Uint8List> _readAvatar(String handle, int version) async {
    final request = await _openShared(
      'GET',
      '/v1/users/${_segment(handle)}/avatar?v=$version',
    );
    request.headers.set(HttpHeaders.acceptHeader, 'image/png');
    final response = await _closeRequest(request);
    if (response.statusCode != 200) throw await _responseError(response);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(
      _timeout,
      onTimeout: _onStreamTimeout,
    )) {
      bytes.add(chunk);
      if (bytes.length > 300 * 1024) {
        throw const FormatException('프로필 사진은 300KB 이하여야 합니다.');
      }
    }
    return bytes.takeBytes();
  }

  Future<AuthResult> signup(
    String handle,
    String password,
    String displayName,
  ) => _auth('/v1/auth/signup', {
    'handle': handle,
    'password': password,
    'displayName': displayName,
    'over14': true,
  });
  Future<AuthResult> login(String handle, String password) =>
      _auth('/v1/auth/login', {'handle': handle, 'password': password});
  Future<void> logout() async {
    await _request('POST', '/v1/auth/logout');
  }

  Future<MeResult> me() async =>
      MeResult.fromJson(await _response('GET', '/v1/me'));
  Future<ConsentRecord> recordConsent({
    String? privacyVersion,
    String? locationVersion,
  }) async {
    if (privacyVersion == null && locationVersion == null) {
      throw ArgumentError('동의할 문서 버전이 필요합니다.');
    }
    final result = await _response('PUT', '/v1/me/consent', {
      if (privacyVersion != null) 'privacy': {'version': privacyVersion},
      if (locationVersion != null) 'location': {'version': locationVersion},
    });
    return ConsentRecord.fromJson(result['consent'] as JsonMap);
  }

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

  Future<ReadyChanged> setReady(String code, bool ready) async =>
      ReadyChanged.fromJson(
        await _response('PUT', '/v1/rooms/${_segment(code)}/ready', {
          'ready': ready,
        }),
      );

  Future<bool> sendLocation(String code, LocationFix fix) async =>
      (await _response(
            'POST',
            '/v1/rooms/${_segment(code)}/location',
            fix.toJson(),
          ))['dropped']
          as bool;

  Future<LocationSnapshot> positions(String code) async =>
      LocationSnapshot.fromJson(
        await _response('GET', '/v1/rooms/${_segment(code)}/positions'),
      );

  Future<void> stopLocation(String code) async {
    await _request('DELETE', '/v1/rooms/${_segment(code)}/location');
  }

  Future<FollowResult> follow(String code, String target) async =>
      FollowResult.fromJson(
        await _response('POST', '/v1/rooms/${_segment(code)}/follow', {
          'target': target,
        }),
      );

  Future<int> respondFollow(
    String code,
    String requestId, {
    required bool accepted,
  }) async {
    final result = await _response(
      'POST',
      '/v1/rooms/${_segment(code)}/follow/respond',
      {'requestId': requestId, 'accepted': accepted},
    );
    return (result['revision'] as num).toInt();
  }

  Future<int> stopFollowing(String code) async {
    final result = await _response(
      'DELETE',
      '/v1/rooms/${_segment(code)}/follow',
    );
    return (result['revision'] as num).toInt();
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
    var attempted = false;

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
            '/v1/rooms/${_segment(code)}/events${attempted ? '?resume=1' : ''}',
          );
          attempted = true;
          request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
          final response = await request.close().timeout(
            const Duration(seconds: 35),
            onTimeout: _onTimeout,
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
              .timeout(_sseSilenceTimeout, onTimeout: _onStreamTimeout)
              .transform(utf8.decoder)
              .transform(const LineSplitter());
          await for (final line in lines) {
            if (cancelled) break;
            final event = parser.accept(line);
            if (event == null) continue;
            final decoded = _decode(event);
            if (decoded != null) controller.add(decoded);
            if (decoded is DeviceReplaced) {
              cancelled = true;
              break;
            }
          }
          if (!cancelled) throw const SocketException('서버 연결이 끊겼습니다.');
        } catch (error, stack) {
          if (cancelled) break;
          if (error is ApiException && error.code == 'DEVICE_REPLACED') {
            controller.add(const DeviceReplaced());
            break;
          }
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
    // Join now claims device ownership. A lost response must not cause an
    // automatic retry to take ownership back from a later explicit entrant.
    final retryable = method == 'GET';
    for (var attempt = 0; ; attempt++) {
      try {
        return await _requestOnce(method, path, body);
      } catch (error) {
        final transient =
            error is SocketException ||
            error is TimeoutException ||
            error is ApiException &&
                error.status == 0 &&
                error.code == 'timeout' ||
            error is HttpException;
        if (!retryable || attempt >= 1 || !transient) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  Future<JsonMap?> _requestOnce(
    String method,
    String path,
    JsonMap? body,
  ) async {
    final request = await _openShared(method, path);
    try {
      if (body != null) {
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/json; charset=utf-8',
        );
        request.add(utf8.encode(jsonEncode(body)));
      }
    } catch (error, stack) {
      request.abort(error, stack);
      rethrow;
    }
    final response = await _closeRequest(request);
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw await _responseError(response);
    final text = await response
        .timeout(_timeout, onTimeout: _onStreamTimeout)
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
  }

  Future<HttpClientResponse> _closeRequest(HttpClientRequest request) =>
      request.close().timeout(
        _timeout,
        onTimeout: () {
          request.abort(_timeoutError);
          throw _timeoutError;
        },
      );

  // SSE의 _open/클라이언트 수명은 유지하고 공유 풀의 요청만 개별 취소한다.
  Future<HttpClientRequest> _openShared(String method, String path) async {
    final base = ServerAddress.normalize(
      tokenStore.baseUrl,
      allowPrivateCleartext: allowPrivateCleartext,
    );
    final pending = _client.openUrl(method, Uri.parse('$base$path'));
    final request = await pending.timeout(
      _timeout,
      onTimeout: () {
        unawaited(
          pending.then<void>(
            (request) => request.abort(_timeoutError),
            onError: (Object _) {},
          ),
        );
        throw _timeoutError;
      },
    );
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set('x-unavo-device', deviceId);
    final token = tokenStore.token;
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    return request;
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
        .timeout(_timeout, onTimeout: _onTimeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set('x-unavo-device', deviceId);
    final token = tokenStore.token;
    if (token != null)
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    return request;
  }

  Future<ApiException> _responseError(HttpClientResponse response) async {
    final text = await response
        .timeout(_timeout, onTimeout: _onStreamTimeout)
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
      'member-updated',
      'member-left',
      'signal',
      'location',
      'location-stopped',
      'follow-request',
      'follow-response',
      'follow-cancelled',
      'trail',
      'ready-changed',
      'device-replaced',
      'member-device-changed',
    }.contains(event.name))
      return null;
    JsonMap data;
    try {
      data = jsonDecode(event.data) as JsonMap;
    } catch (_) {
      if (event.name != 'location') {
        debugPrint(
          'SSE 파싱 실패: event=${event.name}, length=${event.data.length}',
        );
        rethrow;
      }
      logInvalidLocation();
      return null;
    }
    switch (event.name) {
      case 'ready-changed':
        return ReadyChanged.fromJson(data);
      case 'device-replaced':
        return const DeviceReplaced();
      case 'member-device-changed':
        return MemberDeviceChanged(data['handle'] as String);
      case 'member-updated':
        return MemberUpdated(
          data['handle'] as String,
          Avatar.fromJson(data['avatar']),
        );
      case 'follow-request':
        return FollowRequest.fromJson(data);
      case 'follow-cancelled':
        return FollowCancelled(
          data['requester'] as String,
          requestId: data['requestId'] as String,
          revision: (data['revision'] as num).toInt(),
          reason: data['reason'] as String?,
        );
      case 'follow-response':
        return FollowResponse(
          data['target'] as String,
          data['accepted'] as bool,
          requestId: data['requestId'] as String,
          requester: data['requester'] as String,
          revision: (data['revision'] as num).toInt(),
          reason: data['reason'] as String?,
        );
      case 'trail':
        return TrailUpdated(
          data['handle'] as String,
          locationPointsFromJson(data['points']),
          revision: (data['revision'] as num).toInt(),
        );
      case 'hello':
        return Hello.fromJson(data);
      case 'location':
        final fix = tryLocationFix(data);
        return fix == null
            ? null
            : LocationUpdated(
                fix,
                revision: (data['revision'] as num?)?.toInt() ?? 0,
                serverNowMs: data['serverNowMs'] as num?,
              );
      case 'location-stopped':
        return LocationStopped(
          data['handle'] as String,
          reason: data['reason'] as String? ?? 'stopped',
          revision: (data['revision'] as num?)?.toInt() ?? 0,
        );
      case 'member-joined':
        return MemberJoined(
          data['handle'] as String,
          revision: (data['revision'] as num?)?.toInt() ?? 0,
        );
      case 'member-left':
        return MemberLeft(
          data['handle'] as String,
          revision: (data['revision'] as num?)?.toInt() ?? 0,
        );
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
