// Fake HTTP request lifetimes are owned and closed by ApiClient in these tests.
// ignore_for_file: close_sinks
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/net/follow_route.dart';
import 'package:unavo/net/models.dart';

import 'support/avatar_fakes.dart';
import 'support/follow_route_fakes.dart';

const request = FollowRouteRequest(
  followRequestId: 'follow-1',
  guidanceGeneration: 3,
  calculationId: 'calc-1',
  requestId: 'request-1',
  mode: FollowRouteKind.initial,
  originRef: SampleRef('0123456789abcdef', 1),
  anchor: RouteAnchor.sample(SampleRef('fedcba9876543210', 8)),
);

void main() {
  test(
    'feature metadata permits only the consented Naver recommended-route provider',
    () {
      expect(
        FollowRouteFeature.fromJson({
          'enabled': true,
          'provider': 'naver',
          'routeOption': 'traoptimal',
        }).enabled,
        isTrue,
      );
      for (final json in [
        null,
        {'enabled': false},
        {'enabled': true, 'provider': 'other', 'routeOption': 'traoptimal'},
        {'enabled': true, 'provider': 'naver', 'routeOption': 'DISTANCE'},
      ]) {
        expect(FollowRouteFeature.fromJson(json).enabled, isFalse);
      }
    },
  );
  test(
    'schema 1 request sends only sample references with ordinary device authentication',
    () async {
      final http = AvatarTestHttp()
        ..jsonResponse = (_) =>
            routeJson(request, testPoint(0), testPoint(100));
      final api = http.api(AvatarTestTokenStore());
      addTearDown(api.close);
      final response = await api.followRoute(
        'ROOM',
        request,
        RouteCancellation(),
      );
      final sent = http.requests.single;
      expect(sent.method, 'POST');
      expect(sent.uri.path, '/v1/rooms/ROOM/follow-route');
      expect(sent.sentHeaders['x-unavo-device'], api.deviceId);
      expect(
        sent.sentHeaders[HttpHeaders.authorizationHeader],
        'Bearer avatar-token',
      );
      expect(jsonDecode(utf8.decode(sent.body)), request.toJson());
      expect(response.seconds, 12.345);
      expect(response.points, [testPoint(0), testPoint(100)]);
      expect(response.atAnchor, isFalse);
    },
  );
  test(
    'automatic rejoin preserves schema 1 B segment contract and response identity',
    () async {
      const rejoin = FollowRouteRequest(
        followRequestId: 'follow-1',
        guidanceGeneration: 4,
        calculationId: 'rejoin-1',
        requestId: 'request-2',
        mode: FollowRouteKind.rejoin,
        originRef: SampleRef('0123456789abcdef', 2),
        anchor: RouteAnchor.segment(
          SampleRef('fedcba9876543210', 8),
          SampleRef('fedcba9876543210', 9),
          .6,
        ),
      );
      final http = AvatarTestHttp()
        ..jsonResponse = (_) => routeJson(rejoin, testPoint(0), testPoint(100));
      final api = http.api(AvatarTestTokenStore());
      addTearDown(api.close);
      await api.followRoute('ROOM', rejoin, RouteCancellation());
      final json =
          jsonDecode(utf8.decode(http.requests.single.body)) as JsonMap;
      expect(json['mode'], 'B');
      expect(json['schemaVersion'], 1);
      expect(json['anchor'], rejoin.anchor.toJson());
      expect(json.containsKey('origin'), isFalse);
      final wrongMode = routeJson(rejoin, testPoint(0), testPoint(100))
        ..['mode'] = 'A';
      expect(
        () => FollowRouteResult.fromJson(wrongMode, rejoin),
        throwsFormatException,
      );
    },
  );
  test('atAnchor is an empty route, not a fabricated line or merge', () {
    final response = FollowRouteResult.fromJson(
      routeJson(request, testPoint(0), testPoint(0), atAnchor: true),
      request,
    );
    expect(response.atAnchor, isTrue);
    expect(response.points, isEmpty);
    expect(response.actualStart, isNull);
    expect(response.actualEnd, isNull);
  });
  for (final change in <String, Object?>{
    'provider': 'other',
    'routeOption': 'DISTANCE',
    'guidanceGeneration': 4,
    'requestId': 'old',
    'calculationId': 'old',
    'mode': 'B',
    'schemaVersion': 2,
    'seconds': -1,
    'meters': double.nan,
    'points': [],
    'actualEnd': {'lat': 91, 'lng': 0},
    'endGapMeters': 26,
    'originRef': {'stream': 'other', 'seq': 1},
  }.entries) {
    test(
      'DTO rejects ${change.key} mismatch without displaying provider details',
      () {
        final json = routeJson(request, testPoint(0), testPoint(100))
          ..[change.key] = change.value;
        expect(
          () => FollowRouteResult.fromJson(json, request),
          throwsFormatException,
        );
      },
    );
  }
  test(
    'normalized failure retains retry/input metadata and no provider message',
    () {
      final error = FollowRouteException.fromJson({
        ...request.toJson(),
        'error': {
          'code': 'RATE_LIMITED',
          'retryable': true,
          'retryAfterMs': 30123,
          'message': 'SECRET coordinates external-url',
        },
        'inputAccepted': true,
        'inputExpiresAtMs': routeEpoch + 120000,
      });
      expect(error.retryAfterMs, 30123);
      expect(error.inputAccepted, isTrue);
      expect(error.inputExpiresAtMs, routeEpoch + 120000);
      expect(request.matches(error.identity!), isTrue);
      expect(error.toString(), isNot(contains('SECRET')));
    },
  );
  for (final stage in ['open', 'headers', 'body']) {
    for (final cancel in [false, true]) {
      test(
        '$stage ${cancel ? 'explicit cancellation' : 'eight-second timeout'} closes only route client',
        () {
          fakeAsync((clock) {
            final clients = <_Client>[];
            final api = ApiClient(
              tokenStore: AvatarTestTokenStore(),
              clientFactory: () {
                final client = _Client(clients.isEmpty ? 'normal' : stage);
                clients.add(client);
                return client;
              },
            );
            unawaited(api.me());
            clock.flushMicrotasks();
            final token = RouteCancellation();
            Object? failure;
            unawaited(
              api
                  .followRoute('ROOM', request, token)
                  .then<void>(
                    (_) => fail('must stop'),
                    onError: (Object error) => failure = error,
                  ),
            );
            clock.flushMicrotasks();
            if (cancel) {
              token.cancel();
              clock.flushMicrotasks();
            } else {
              clock.elapse(const Duration(milliseconds: 7999));
              expect(failure, isNull);
              clock.elapse(const Duration(milliseconds: 1));
            }
            expect(
              (failure! as FollowRouteException).code,
              cancel ? 'CANCELLED' : 'ROUTE_TIMEOUT',
            );
            expect(clients[0].closed, isFalse);
            expect(clients[1].closed, isTrue);
            if (stage == 'open') {
              clients[1].openGate.complete(clients[1].request);
              clock.flushMicrotasks();
              expect(clients[1].request.aborted, isTrue);
            }
            api.close();
            clock.flushMicrotasks();
            expect(clock.pendingTimers, isEmpty);
          });
        },
      );
    }
  }
}

class _Client implements HttpClient {
  _Client(this.stage);
  final String stage;
  bool closed = false;
  final openGate = Completer<HttpClientRequest>();
  late final request = _Request(this);
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      stage == 'open' ? openGate.future : Future.value(request);
  @override
  void close({bool force = false}) {
    if (closed) return;
    closed = true;
    if (stage == 'body') {
      request.body.addError(const SocketException('closed'));
      unawaited(request.body.close());
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.client);
  final _Client client;
  final body = StreamController<List<int>>();
  final headerGate = Completer<HttpClientResponse>();
  bool aborted = false;
  @override
  final headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  void add(List<int> bytes) {}
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  Future<HttpClientResponse> close() async {
    if (client.stage == 'headers') return headerGate.future;
    if (client.stage == 'body') return _Response(body.stream);
    return _Response(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'user': {'handle': 'self', 'displayName': '시험'},
          }),
        ),
      ),
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
  _Response(this.stream);
  final Stream<List<int>> stream;
  @override
  int get statusCode => 200;
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
