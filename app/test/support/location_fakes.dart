import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:unavo/auth/session_store.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/net/models.dart';

class LocationTestTokenStore implements TokenStore {
  @override
  String get token => 'test';
  @override
  String get baseUrl => 'https://example.invalid';
}

class FakeLocationSource extends LocationSource {
  LocationPermissionState permission = LocationPermissionState.granted;
  Completer<LocationPermissionState>? pendingPermission;
  LocationSample? initialSample;
  int requests = 0, watches = 0, cancellations = 0;
  final controllers = <StreamController<LocationSample>>[];

  @override
  Future<LocationPermissionState> requestPermission() async {
    requests++;
    return pendingPermission == null
        ? permission
        : await pendingPermission!.future;
  }

  @override
  Stream<LocationSample> watch() {
    watches++;
    final controller = StreamController<LocationSample>(
      onCancel: () async {
        cancellations++;
      },
    );
    unawaited(controller.done);
    controllers.add(controller);
    if (initialSample != null) controller.add(initialSample!);
    return controller.stream;
  }

  void add(LocationSample sample) => controllers.last.add(sample);
  Future<void> close() async {
    for (final controller in controllers) {
      await controller.close();
    }
  }
}

class LocationHttpCall {
  LocationHttpCall(this.method, this.uri);
  final String method;
  final Uri uri;
  final bytes = <int>[];
  JsonMap get body => jsonDecode(utf8.decode(bytes)) as JsonMap;
}

class FakeLocationHttp {
  FakeLocationHttp() {
    unawaited(events.done);
  }
  final calls = <LocationHttpCall>[];
  final events = StreamController<List<int>>(onCancel: () async {});
  int failures = 0;
  bool dropped = false, deleteFails = false, hang = false;
  Future<void>? sendGate, deleteGate;
  JsonMap snapshot = {'positions': <JsonMap>[], 'trails': <String, dynamic>{}};
  List<LocationHttpCall> get posts =>
      calls.where((call) => call.method == 'POST').toList();
  List<LocationHttpCall> get deletes =>
      calls.where((call) => call.method == 'DELETE').toList();

  HttpClient client() => _Client(this);
  void event(String name, JsonMap data) =>
      events.add(utf8.encode('event: $name\ndata: ${jsonEncode(data)}\n\n'));

  Future<HttpClientResponse> respond(LocationHttpCall call) async {
    if (hang) return Completer<HttpClientResponse>().future;
    if (call.uri.path.endsWith('/events')) return _Response(200, events.stream);
    if (call.method == 'POST') {
      if (sendGate != null) await sendGate;
      if (failures > 0) {
        failures--;
        return _json(503, {
          'error': {'code': 'unavailable', 'message': '위치 전송 실패'},
        });
      }
      return _json(202, {
        'accepted': true,
        'dropped': dropped,
        'requestId': 'request-1',
        'revision': 1,
      });
    }
    if (call.method == 'DELETE') {
      if (deleteGate != null) await deleteGate;
      return deleteFails
          ? _json(503, {
              'error': {'message': '중지 실패'},
            })
          : _json(202, {'accepted': true, 'revision': 2});
    }
    return _json(200, snapshot);
  }

  HttpClientResponse _json(int status, JsonMap body) {
    // Stream.value의 취소 Future는 루트 존에 있어 timeout().join() 완료가
    // fakeAsync 밖으로 빠진다. 취소 Future도 현재 테스트 존에서 생성한다.
    final bytes = StreamController<List<int>>(onCancel: () async {});
    bytes.add(utf8.encode(jsonEncode(body)));
    unawaited(bytes.close());
    return _Response(status, bytes.stream);
  }

  Future<void> close() => events.close();
}

class _Client implements HttpClient {
  _Client(this.http);
  final FakeLocationHttp http;
  bool _events = false;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    _events = url.path.endsWith('/events');
    final call = LocationHttpCall(method, url);
    http.calls.add(call);
    return _Request(http, call);
  }

  @override
  void close({bool force = false}) {
    if (_events) unawaited(http.events.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.http, this.call);
  final FakeLocationHttp http;
  final LocationHttpCall call;
  @override
  HttpHeaders get headers => _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  void add(List<int> data) => call.bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() => http.respond(call);
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
  _Response(this.statusCode, this.bytes);
  final Stream<List<int>> bytes;
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => bytes.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
