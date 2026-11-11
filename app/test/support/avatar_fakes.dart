import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unavo/auth/session_store.dart';
import 'package:unavo/net/api_client.dart';

class AvatarTestTokenStore implements TokenStore {
  @override
  String token = 'avatar-token';
  @override
  String baseUrl = 'https://avatar.invalid';
}

class AvatarTestHttp {
  final requests = <AvatarTestRequest>[];
  int status = 200, version = 0;
  Object? openError;
  Uint8List? photo;
  Stream<List<int>>? eventStream;

  ApiClient api(TokenStore store) =>
      ApiClient(tokenStore: store, clientFactory: () => _Client(this));

  HttpClientResponse respond(AvatarTestRequest request) {
    if (request.uri.path.endsWith('/events') && eventStream != null) {
      return _Response(200, eventStream!);
    }
    if (status != 200) {
      return _Response(
        status,
        Stream.value(
          utf8.encode(
            jsonEncode({
              'error': {'code': 'AVATAR_ERROR', 'message': '프로필 저장 오류'},
            }),
          ),
        ),
      );
    }
    if (request.method == 'GET') {
      return _Response(200, Stream.value(photo ?? Uint8List(0)));
    }
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
    return _Response(
      200,
      Stream.value(
        utf8.encode(
          jsonEncode({
            'user': {
              'handle': 'alice',
              'displayName': '앨리스',
              'avatar': {'kind': body['kind'], 'version': ++version},
            },
          }),
        ),
      ),
    );
  }
}

class _Client implements HttpClient {
  _Client(this.owner);
  final AvatarTestHttp owner;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (owner.openError case final error?) throw error;
    final request = AvatarTestRequest(owner, method, url);
    owner.requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class AvatarTestRequest implements HttpClientRequest {
  AvatarTestRequest(this.owner, this.method, this.uri);
  final AvatarTestHttp owner;
  @override
  final String method;
  @override
  final Uri uri;
  final body = <int>[];
  final sentHeaders = <String, Object>{};
  @override
  late final HttpHeaders headers = _Headers(sentHeaders);
  @override
  set followRedirects(bool value) {}
  @override
  void add(List<int> data) => body.addAll(data);
  @override
  Future<HttpClientResponse> close() async => owner.respond(this);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  _Headers(this.values);
  final Map<String, Object> values;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.stream);
  @override
  final int statusCode;
  final Stream<List<int>> stream;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
