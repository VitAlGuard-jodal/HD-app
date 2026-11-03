import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS는 Android와 같은 오디오·통화 채널 계약을 사용한다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final store = SessionStore(await SharedPreferences.getInstance());
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final invoked = <MethodCall>[];
    final audio = <String, Object?>{
      'mode': 'phone',
      'devices': [
        <String, Object?>{'id': 17, 'type': 15, 'name': 'iPhone Microphone'},
      ],
      'selected': <String, Object?>{
        'id': 17,
        'type': 15,
        'name': 'iPhone Microphone',
      },
      'manualId': null,
      'level': 0.5,
      'rms': 1036,
      'dbfs': -30.0,
      'isRecording': false,
      'isPreviewing': false,
      'error': null,
    };
    messenger.setMockMethodCallHandler(MicRouter.channel, (call) async {
      invoked.add(call);
      switch (call.method) {
        case 'getState':
          return audio;
        case 'choose':
          audio['manualId'] = (call.arguments as Map)['id'];
          return audio;
        case 'permissions':
        case 'requestPermissions':
          return {'microphone': true, 'notifications': true};
        case 'setSpeakerphone':
          return (call.arguments as Map)['enabled'];
        case 'startPreview':
        case 'stopPreview':
        case 'openSettings':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    messenger.setMockMethodCallHandler(CallService.channel, (call) async {
      invoked.add(call);
      switch (call.method) {
        case 'getState':
          return {'isActive': false};
        case 'start':
          return {
            'roomCode': (call.arguments as Map)['roomCode'],
            'selfHandle': (call.arguments as Map)['handle'],
            'isActive': true,
          };
        case 'stop':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    const levelEvents = MethodChannel('unavo/audio/levels');
    const callEvents = MethodChannel('unavo/call/events');
    for (final channel in [levelEvents, callEvents]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    final mic = MicRouter(store);
    final calls = CallService();
    addTearDown(() async {
      mic.dispose();
      calls.dispose();
      store.dispose();
      await Future<void>.delayed(Duration.zero);
      for (final channel in [
        MicRouter.channel,
        CallService.channel,
        levelEvents,
        callEvents,
      ]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    expect(mic.supported, isTrue);
    expect(calls.supported, isTrue);
    await mic.initialize();
    await calls.initialize();
    expect(mic.state.selected?.name, 'iPhone Microphone');
    expect(mic.state.level, 0.5);
    expect(mic.permissions.microphone, isTrue);
    await mic.choose(17);
    expect(mic.state.manualId, 17);
    expect(store.manualMicId, 17);
    await mic.requestPermissions();
    await mic.startPreview();
    await mic.stopPreview();
    await calls.start('ABC123', 'R6C_Tester');
    expect(calls.state.isActive, isTrue);
    expect(calls.state.roomCode, 'ABC123');
    expect(await mic.setSpeakerphone(true), isTrue);
    expect(await mic.setSpeakerphone(false), isFalse);
    await mic.openSettings();
    await calls.stop();
    expect(calls.state.isActive, isFalse);
    expect(
      invoked.map((call) => call.method),
      containsAll([
        'getState',
        'choose',
        'permissions',
        'requestPermissions',
        'startPreview',
        'stopPreview',
        'start',
        'setSpeakerphone',
        'openSettings',
        'stop',
      ]),
    );
  });
}
