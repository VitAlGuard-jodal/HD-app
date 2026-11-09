import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/audio/mic_router.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/call/call_service.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/core/app_services.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/ui/control_scale.dart';
import 'package:unavo/ui/icons.dart';
import 'package:unavo/ui/widgets/member_tile.dart';

void main() {
  testWidgets('폰·차량 내 카드는 미디어 발화 콜백을 따르고 음소거·통화 종료 시 꺼진다', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final semantics = tester.ensureSemantics();
    SharedPreferences.setMockInitialValues({
      'token': 'test',
      'handle': 'alice',
    });
    final media = NoopMediaEngine();
    final services = AppServices(
      SessionStore(await SharedPreferences.getInstance()),
      mediaEngine: media,
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    const levels = MethodChannel('unavo/audio/levels');
    const routes = MethodChannel('unavo/audio/routes');
    messenger.setMockMethodCallHandler(MicRouter.channel, (call) async {
      return switch (call.method) {
        'getState' || 'choose' => {'level': 0.0},
        'permissions' => {'microphone': true},
        'getOutputRoute' => {'route': 'speaker'},
        _ => null,
      };
    });
    for (final channel in [levels, routes, CallService.channel]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    addTearDown(() async {
      services.dispose();
      await Future<void>.delayed(Duration.zero);
      for (final channel in [
        MicRouter.channel,
        levels,
        routes,
        CallService.channel,
      ]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    await services.mic.initialize();
    services.rooms.state = const RoomState(
      code: 'ABC123',
      isConnected: true,
      members: [Member('alice', 'Alice', ''), Member('bob', 'Bob', '')],
    );
    final self = find.byWidgetPredicate((w) => w is MemberTile && w.self);
    final remote = find.byWidgetPredicate((w) => w is MemberTile && !w.self);
    try {
      for (final car in [false, true]) {
        services.calls.state = const CallState(
          roomCode: 'ABC123',
          selfHandle: 'alice',
          isActive: true,
        );
        media.remoteSpeaking?.call('bob', true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ControlScale(
                car: car,
                child: RoomScreen(
                  services: services,
                  mode: car ? DeviceMode.car : DeviceMode.phone,
                  embedded: true,
                ),
              ),
            ),
          ),
        );
        expect(services.mic.state.level, 0);
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        media.localSpeaking?.call(true);
        await tester.pump();
        expect(services.rooms.localSpeaking, isTrue);
        expect(tester.widget<MemberTile>(self).speaking, isTrue);
        expect(
          find.bySemanticsLabel('Alice, @alice, 나, 말하는 중'),
          findsOneWidget,
        );

        await messenger.handlePlatformMessage(
          'unavo/audio/routes',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'route': 'speaker',
            'interrupted': true,
          }),
          (_) {},
        );
        await tester.pump();
        expect(services.rooms.interrupted, isTrue);
        expect(tester.widget<MemberTile>(self).interrupted, isTrue);
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        expect(tester.widget<MemberTile>(remote).interrupted, isFalse);
        expect(
          find.descendant(of: self, matching: find.text('다른 오디오 때문에 잠시 중단')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: self,
            matching: find.byWidgetPredicate(
              (widget) => widget is UnavoIcon && widget.name == 'micoff',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('Alice, @alice, 나, 다른 오디오 때문에 잠시 중단'),
          findsOneWidget,
        );
        media.localSpeaking?.call(true);
        await tester.pump();
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        await messenger.handlePlatformMessage(
          'unavo/audio/routes',
          const StandardMethodCodec().encodeSuccessEnvelope({
            'route': 'speaker',
            'interrupted': false,
          }),
          (_) {},
        );
        await tester.pump();
        expect(find.text('다른 오디오 때문에 잠시 중단'), findsNothing);
        expect(tester.widget<MemberTile>(self).interrupted, isFalse);
        media.localSpeaking?.call(true);
        await tester.pump();

        services.rooms.setMuted(true);
        await tester.pump();
        expect(services.rooms.localSpeaking, isFalse);
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        expect(tester.widget<MemberTile>(remote).speaking, isTrue);
        media.localSpeaking?.call(true);
        await tester.pump();
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        services.rooms.setMuted(false);
        await tester.pump();
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        media.localSpeaking?.call(true);
        await tester.pump();
        expect(tester.widget<MemberTile>(self).speaking, isTrue);
        media.localSpeaking?.call(false);
        await tester.pump();
        expect(tester.widget<MemberTile>(self).speaking, isFalse);

        media.localSpeaking?.call(true);
        await tester.pump();
        expect(tester.widget<MemberTile>(self).speaking, isTrue);
        final stopping = services.rooms.leaveCall();
        expect(services.rooms.localSpeaking, isFalse);
        await tester.pumpAndSettle();
        await stopping;
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        media.localSpeaking?.call(true);
        await tester.pump();
        expect(tester.widget<MemberTile>(self).speaking, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
