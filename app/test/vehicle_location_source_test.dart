import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/location/vehicle_location_source.dart';
import 'package:unavo/net/api_client.dart';

import 'support/location_fakes.dart';

void main() {
  // 플랫폼 채널 가짜만 쓰는 단위 검사라 FakeAsync(testWidgets) 대신 실제 이벤트 큐로 돌린다 —
  // testWidgets 에서는 EventChannel 구독 취소 뒤 pump 가 끝나지 않았다.
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in DeviceMode.values) {
    test('$mode는 지정 출처만 구독하고 취소한다', () async {
      final f = _LocationFixture(mode: mode);
      expect(
        await f.source.requestPermission(),
        LocationPermissionState.granted,
      );
      final samples = <LocationSample>[];
      final subscription = f.source.watch().listen(samples.add);
      await pumpEventQueue();
      expect(f.prepares, mode == DeviceMode.car ? 1 : 0);
      expect(f.fallback.requests, 1);
      expect(f.fallback.watches, mode == DeviceMode.phone ? 1 : 0);
      if (mode == DeviceMode.car) {
        expect(f.eventMethods, ['listen']);
        await f.emit(_fix());
        expect(samples.single.at.millisecondsSinceEpoch, 1000);
      } else {
        expect(f.eventMethods, isEmpty);
      }
      await subscription.cancel();
      await pumpEventQueue();
      if (mode == DeviceMode.car) expect(f.eventMethods, ['listen', 'cancel']);
      if (mode == DeviceMode.phone) expect(f.fallback.cancellations, 1);
      await f.close();
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final failure in [
    'unsupported',
    'permission',
    'initialize',
    'missing',
  ]) {
    test('$failure이면 차량에서도 geolocator로 대체한다', () async {
      final f = _LocationFixture(failure: failure);
      expect(
        await f.source.requestPermission(),
        LocationPermissionState.granted,
      );
      final subscription = f.source.watch().listen((_) {});
      await pumpEventQueue();
      expect(f.fallback.watches, 1);
      expect(f.eventMethods, isEmpty);
      await subscription.cancel();
      await f.close();
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  test('SDK stream 오류는 unregister 뒤 대체하고 새 권한창을 열지 않는다', () async {
    final f = _LocationFixture();
    await f.source.requestPermission();
    final samples = <LocationSample>[];
    final subscription = f.source.watch().listen(samples.add);
    await pumpEventQueue();
    await f.error();
    expect(f.eventMethods, ['listen', 'cancel']);
    expect(f.fallback.requests, 1);
    expect(f.fallback.watches, 1);
    final sample = LocationSample(lat: 38, lng: 128, at: DateTime.utc(2026));
    f.fallback.add(sample);
    await pumpEventQueue();
    expect(samples.single, same(sample));
    await subscription.cancel();
    expect(f.fallback.cancellations, 1);
    await f.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('대체 권한이 거부되었어도 FusedLocation은 사용하며 오류 후 몰래 구독하지 않는다', () async {
    final f = _LocationFixture();
    f.fallback.permission = LocationPermissionState.denied;
    expect(await f.source.requestPermission(), LocationPermissionState.granted);
    final errors = <Object>[];
    final subscription = f.source.watch().listen((_) {}, onError: errors.add);
    await pumpEventQueue();
    await f.error();
    expect(errors, hasLength(1));
    expect(f.fallback.watches, 0);
    expect(f.fallback.requests, 1);
    await subscription.cancel();
    await f.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('오류 직후 공유 취소는 대체 구독을 남기지 않는다', () async {
    final f = _LocationFixture();
    await f.source.requestPermission();
    final subscription = f.source.watch().listen((_) {});
    await pumpEventQueue();
    final cancelGate = Completer<void>();
    f.cancelGate = cancelGate.future;
    await f.error();
    final cancellation = subscription.cancel();
    cancelGate.complete();
    await pumpEventQueue();
    await cancellation;
    // EventChannel(브로드캐스트) 구독 취소는 네이티브 cancel 응답을 기다리지 않아 대체 구독이
    // 먼저 생길 수 있다. 남는 구독이 없어야 한다는 것만 고정한다.
    expect(f.fallback.cancellations, f.fallback.watches);
    await f.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('측정 시각은 LocationShare POST까지 보존되고 공유 중지는 채널을 해제한다', () async {
    final f = _LocationFixture();
    final http = FakeLocationHttp();
    final api = ApiClient(
      tokenStore: LocationTestTokenStore(),
      clientFactory: http.client,
    );
    final share = LocationShare(
      api: api,
      source: f.source,
      roomCode: () => 'ABC123',
      selfHandle: () => 'bob',
      now: () => DateTime.utc(2026),
    );
    await share.start(token: Object(), stillValid: () => true);
    await pumpEventQueue();
    await f.emit(_fix(at: 123456));
    expect(http.posts.single.body['at'], 123456);
    expect(share.lastSent?.at, 123456);
    await share.stop();
    await pumpEventQueue();
    expect(f.eventMethods, ['listen', 'cancel']);
    expect(http.deletes, hasLength(1));
    await share.shutdown();
    api.close();
    unawaited(http.events.stream.drain<void>());
    await http.close();
    await f.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('측정 간 거리/시간으로 속도를 구하고 altitude/confidence를 accuracy로 오인하지 않는다', () {
    final decoder = FusedLocationSamples();
    final first = decoder.decode(_fix())!;
    expect(first.speed, isNull);
    expect(first.at.millisecondsSinceEpoch, 1000);
    expect(first.altitude, 32);
    expect(first.confidence, 0.8);
    expect(first.accuracy, isNull);
    final second = decoder.decode(_fix(lat: 37.00003, at: 3000))!;
    expect(second.speed, closeTo(1.668, 0.01));
    expect(second.heading, 5);
    expect(decoder.decode(_fix(at: 3000)), isNull);
    expect(decoder.decode(_fix(at: 2000)), isNull);
    final gap = decoder.decode(_fix(at: 14000))!;
    expect(gap.speed, isNull);
    expect(FusedLocationSamples().decode(_fix(at: 15000))!.speed, isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('null·범위 밖·잘못된 timestamp는 표본으로 보내지 않는다', () {
    final decoder = FusedLocationSamples();
    for (final value in <Object?>[
      null,
      {},
      _fix(lat: 91),
      _fix(at: -1),
      {..._fix(), 'timestampMillis': double.nan},
      {..._fix(), 'timestampMillis': 1.5},
      {..._fix(), 'longitude': double.infinity},
    ]) {
      expect(decoder.decode(value), isNull);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Map<String, Object> _fix({double lat = 37, int at = 1000}) => {
  'latitude': lat,
  'longitude': 127.0,
  'altitude': 32.0,
  'heading': 5.0,
  'confidence': 0.8,
  'timestampMillis': at,
};

class _LocationFixture {
  _LocationFixture({DeviceMode mode = DeviceMode.car, String? failure}) {
    messenger.setMockMethodCallHandler(methods, (call) async {
      prepares++;
      if (failure == 'initialize')
        throw PlatformException(code: 'initialize_failed');
      if (failure == 'missing') throw MissingPluginException();
      return failure == null;
    });
    messenger.setMockMethodCallHandler(eventControl, (call) async {
      eventMethods.add(call.method);
      if (call.method == 'cancel') await cancelGate;
      return null;
    });
    source = VehicleLocationSource(mode: mode, fallback: fallback);
  }
  static const methods = MethodChannel('unavo/location');
  static const eventControl = MethodChannel('unavo/location/events');
  static const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final fallback = FakeLocationSource();
  late final VehicleLocationSource source;
  int prepares = 0;
  final eventMethods = <String>[];
  Future<void>? cancelGate;

  Future<void> emit(Object? data) async {
    await messenger.handlePlatformMessage(
      eventControl.name,
      codec.encodeSuccessEnvelope(data),
      (_) {},
    );
    await pumpEventQueue();
  }

  Future<void> error() async {
    await messenger.handlePlatformMessage(
      eventControl.name,
      codec.encodeErrorEnvelope(code: 'fused_unavailable', message: 'test'),
      (_) {},
    );
    await pumpEventQueue();
  }

  Future<void> close() async {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(eventControl, null);
    await fallback.close();
  }
}
