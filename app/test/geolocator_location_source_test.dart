import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:unavo/location/geolocator_location_source.dart';
import 'package:unavo/location/location_source.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('flutter.baseflow.com/geolocator');
  const updates = MethodChannel('flutter.baseflow.com/geolocator_updates');
  final calls = <String>[];
  final streamCalls = <MethodCall>[];
  var permission = LocationPermission.denied;
  var requested = LocationPermission.whileInUse;
  var enabled = true;
  var disableOnRequest = false;

  setUp(() {
    permission = LocationPermission.denied;
    requested = LocationPermission.whileInUse;
    enabled = true;
    disableOnRequest = false;
    calls.clear();
    streamCalls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, (call) {
      calls.add(call.method);
      if (call.method == 'requestPermission' && disableOnRequest)
        enabled = false;
      return SynchronousFuture<Object?>(switch (call.method) {
        'isLocationServiceEnabled' => enabled,
        'checkPermission' => permission.index,
        'requestPermission' => requested.index,
        _ => throw PlatformException(code: 'unexpected', message: call.method),
      });
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(updates, (call) {
      streamCalls.add(call);
      return SynchronousFuture<Object?>(null);
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(method, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(updates, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('권한 다섯 상태를 앱 상태로 변환한다', () {
    expect(LocationPermission.values.map(locationPermissionState), [
      LocationPermissionState.denied,
      LocationPermissionState.deniedForever,
      LocationPermissionState.granted,
      LocationPermissionState.granted,
      LocationPermissionState.denied,
    ]);
  });

  test('거부된 권한만 요청하고 요청 결과를 채널에서 변환한다', () async {
    final source = GeolocatorLocationSource();
    for (final result in [
      LocationPermission.whileInUse,
      LocationPermission.always,
      LocationPermission.denied,
      LocationPermission.deniedForever,
    ]) {
      calls.clear();
      requested = result;
      expect(await source.requestPermission(), locationPermissionState(result));
      expect(calls, [
        'isLocationServiceEnabled',
        'checkPermission',
        'requestPermission',
        'isLocationServiceEnabled',
      ]);
    }
    // 네이티브 채널은 0..3만 허용한다. 웹 전용 unableToDetermine은
    // 위의 enum 변환 테스트에서 확인한다.
    for (final result in [
      LocationPermission.always,
      LocationPermission.whileInUse,
      LocationPermission.deniedForever,
    ]) {
      calls.clear();
      permission = result;
      expect(await source.requestPermission(), locationPermissionState(result));
      expect(calls, [
        'isLocationServiceEnabled',
        'checkPermission',
        'isLocationServiceEnabled',
      ]);
    }
  });

  test('서비스 꺼짐은 요청 전후 모두 serviceOff다', () async {
    enabled = false;
    final source = GeolocatorLocationSource();
    expect(
      await source.requestPermission(),
      LocationPermissionState.serviceOff,
    );
    expect(calls, ['isLocationServiceEnabled']);
    enabled = true;
    disableOnRequest = true;
    expect(
      await source.requestPermission(),
      LocationPermissionState.serviceOff,
    );
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform 설정·표본 변환·하드웨어 구독 해제', () async {
      debugDefaultTargetPlatformOverride = platform;
      final source = GeolocatorLocationSource();
      final samples = <LocationSample>[];
      final subscription = source.watch().listen(samples.add);
      await Future<void>.delayed(Duration.zero);
      expect(streamCalls.map((call) => call.method), ['listen']);
      final settings = streamCalls.single.arguments as Map;
      expect(settings['distanceFilter'], 0);
      if (platform == TargetPlatform.android) {
        expect(settings['forceLocationManager'], isTrue);
        expect(settings['accuracy'], LocationAccuracy.high.index);
        expect(settings['timeInterval'], 1000);
        expect(settings['foregroundNotificationConfig'], {
          'notificationTitle': '우나보 위치 공유 중',
          'notificationText': '같은 방 참여자에게 내 위치를 보내고 있습니다',
          'notificationChannelName': '위치 공유',
          'notificationIcon': {
            'name': 'ic_notification_small',
            'defType': 'drawable',
          },
          'setOngoing': true,
          'enableWakeLock': true,
          'enableWifiLock': false,
          'color': null,
        });
      } else {
        expect(settings['accuracy'], LocationAccuracy.best.index);
        expect(
          settings['activityType'],
          ActivityType.automotiveNavigation.index,
        );
        expect(settings['allowBackgroundLocationUpdates'], isTrue);
        expect(settings['showBackgroundLocationIndicator'], isTrue);
        expect(settings['pauseLocationUpdatesAutomatically'], isFalse);
      }
      Future<void> emit(Map<String, Object> value) =>
          binding.defaultBinaryMessenger.handlePlatformMessage(
            updates.name,
            const StandardMethodCodec().encodeSuccessEnvelope(value),
            (_) {},
          );
      await emit({
        'latitude': 37.5,
        'longitude': 127.0,
        'timestamp': 1000,
        'accuracy': 3.0,
        'speed': 2.0,
        'heading': 90.0,
      });
      await emit({
        'latitude': 37.6,
        'longitude': 127.1,
        'timestamp': 2000,
        'accuracy': -1.0,
        'speed': -1.0,
        'heading': -1.0,
      });
      await emit({'latitude': 37.7, 'longitude': 127.2, 'timestamp': 3000});
      await Future<void>.delayed(Duration.zero);
      expect(samples, hasLength(3));
      expect(samples.first.lat, 37.5);
      expect(samples.first.lng, 127);
      expect(samples.first.accuracy, 3);
      expect(samples.first.speed, 2);
      expect(samples.first.heading, 90);
      expect(samples.first.at.millisecondsSinceEpoch, 1000);
      for (final sample in samples.skip(1)) {
        expect(sample.accuracy, isNull);
        expect(sample.speed, isNull);
        expect(sample.heading, isNull);
      }
      await subscription.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(streamCalls.map((call) => call.method), ['listen', 'cancel']);
    });
  }
}
