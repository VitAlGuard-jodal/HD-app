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
}
