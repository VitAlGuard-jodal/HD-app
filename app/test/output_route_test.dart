import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const routesChannel = MethodChannel('unavo/audio/routes');
  const levelsChannel = MethodChannel('unavo/audio/levels');

  test('네이티브 출력 조회·순환·외부 장치 이벤트는 enum 스트림으로 전달된다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(await SharedPreferences.getInstance());
    final mic = MicRouter(store);
    final observed = <OutputRoute>[];
    final subscription = mic.outputRoutes.listen(observed.add);
    var route = 'bluetooth';
    var available = ['bluetooth', 'headphones', 'speaker', 'receiver'];
    final choices = <String>[];
    Map<String, Object> snapshot() => {'route': route, 'available': available};
    messenger.setMockMethodCallHandler(MicRouter.channel, (call) async {
      switch (call.method) {
        case 'getState':
        case 'choose':
          return {'mode': 'phone'};
        case 'permissions':
          return {'microphone': true};
        case 'getOutputRoute':
          return snapshot();
        case 'setOutputRoute':
          route = (call.arguments as Map)['route'] as String;
          choices.add(route);
          return snapshot();
        case 'setSpeakerphone':
          route = available.first;
          return route == 'speaker';
        default:
          return null;
      }
    });
    for (final channel in [routesChannel, levelsChannel]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    await mic.initialize();
    expect(mic.outputRoute, OutputRoute.bluetooth);
    await mic.cycleOutputRoute();
    expect(mic.outputRoute, OutputRoute.headphones);
    await mic.cycleOutputRoute();
    await mic.cycleOutputRoute();
    await mic.cycleOutputRoute();
    expect(choices, ['headphones', 'speaker', 'receiver', 'bluetooth']);
    route = 'speaker';
    available = ['speaker', 'receiver'];
    await messenger.handlePlatformMessage(
      'unavo/audio/routes',
      const StandardMethodCodec().encodeSuccessEnvelope(snapshot()),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(mic.outputRoute, OutputRoute.speaker);
    expect(
      observed,
      containsAllInOrder([
        OutputRoute.bluetooth,
        OutputRoute.headphones,
        OutputRoute.speaker,
        OutputRoute.receiver,
      ]),
    );
    await mic.cycleOutputRoute();
    expect(mic.outputRoute, OutputRoute.receiver);
    await mic.cycleOutputRoute();
    expect(mic.outputRoute, OutputRoute.speaker);
    await subscription.cancel();
    mic.dispose();
    store.dispose();
    await Future<void>.delayed(Duration.zero);
    for (final channel in [MicRouter.channel, routesChannel, levelsChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('차량 시스템 음량·권한 거부·인터럽션 이벤트 계약', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(await SharedPreferences.getInstance());
    final mic = MicRouter(store);
    var volume = 60;
    var writable = true;
    var interrupted = false;
    Map<String, Object> snapshot() => {
      'route': 'carAudio',
      'available': ['carAudio'],
      'callVolume': volume,
      'volumeWritable': writable,
      'interrupted': interrupted,
    };
    messenger.setMockMethodCallHandler(MicRouter.channel, (call) async {
      switch (call.method) {
        case 'getState':
        case 'choose':
          return {'mode': 'car'};
        case 'permissions':
          return {'microphone': true};
        case 'getOutputRoute':
          return snapshot();
        case 'setCallVolume':
          if (writable) volume = (call.arguments as Map)['value'] as int;
          return snapshot();
        default:
          return null;
      }
    });
    for (final channel in [routesChannel, levelsChannel]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    await mic.initialize();
    expect(mic.isAutomotive, isTrue);
    expect(mic.systemCallVolume, 60);
    await mic.setSystemCallVolume(30);
    expect(mic.systemCallVolume, 30);
    writable = false;
    await mic.setSystemCallVolume(10);
    expect(mic.systemVolumeWritable, isFalse);
    expect(mic.systemCallVolume, 30);
    interrupted = true;
    await messenger.handlePlatformMessage(
      'unavo/audio/routes',
      const StandardMethodCodec().encodeSuccessEnvelope(snapshot()),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(mic.audioInterrupted, isTrue);
    mic.dispose();
    store.dispose();
    await Future<void>.delayed(Duration.zero);
    for (final channel in [MicRouter.channel, routesChannel, levelsChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('차량의 일시적·미확인 0은 알 수 없음이며 확인된 시스템 0만 전달한다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(await SharedPreferences.getInstance());
    final mic = MicRouter(store);
    var snapshot = <String, Object?>{
      'route': 'carAudio',
      'available': ['carAudio'],
      'callVolume': 100,
    };
    var queryFails = false, queryMissing = false;
    messenger.setMockMethodCallHandler(MicRouter.channel, (call) async {
      switch (call.method) {
        case 'getState':
        case 'choose':
          return {'mode': 'car'};
        case 'permissions':
          return {'microphone': true};
        case 'getOutputRoute':
          if (queryFails) throw PlatformException(code: 'unavailable');
          return queryMissing ? null : snapshot;
        default:
          return null;
      }
    });
    for (final channel in [routesChannel, levelsChannel]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    Future<void> publish(Map<String, Object?> values) async {
      snapshot = {
        'route': 'carAudio',
        'available': ['carAudio'],
        ...values,
      };
      await messenger.handlePlatformMessage(
        'unavo/audio/routes',
        const StandardMethodCodec().encodeSuccessEnvelope(snapshot),
        (_) {},
      );
      await pumpEventQueue();
    }

    try {
      await mic.initialize();
      expect(mic.systemCallVolume, 100);
      for (final value in [null, -1, 101, double.nan, double.infinity, 0]) {
        await publish({'callVolume': value});
        expect(
          mic.systemCallVolume,
          isNull,
          reason: '$value is not a verified zero',
        );
      }
      await publish({'callVolume': 0, 'callVolumeZeroConfirmed': true});
      expect(mic.systemCallVolume, 0);
      await publish({
        'callVolume': 0,
        'callVolumeZeroConfirmed': true,
        'interrupted': true,
      });
      expect(mic.systemCallVolume, isNull);
      expect(mic.audioInterrupted, isTrue);
      await publish({'callVolume': .1});
      expect(mic.systemCallVolume, 1);
      snapshot = {...snapshot, 'callVolume': 80};
      await mic.refreshOutputRoute();
      expect(mic.systemCallVolume, 80);
      await publish({'callVolume': 0, 'callVolumeZeroConfirmed': true});
      queryMissing = true;
      await mic.refreshOutputRoute();
      expect(mic.systemCallVolume, isNull);
      queryMissing = false;
      await publish({'callVolume': 0, 'callVolumeZeroConfirmed': true});
      queryFails = true;
      await expectLater(
        mic.refreshOutputRoute(),
        throwsA(isA<PlatformException>()),
      );
      expect(mic.systemCallVolume, isNull);
    } finally {
      mic.dispose();
      store.dispose();
      await pumpEventQueue();
      for (final channel in [MicRouter.channel, routesChannel, levelsChannel]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
