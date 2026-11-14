import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_voice_guidance.dart';

import 'support/follow_route_fakes.dart';

void main() {
  test(
    'merge round speaks once; rebuild, reconnect and onTrace mode change do not repeat',
    () async {
      final output = _Output();
      final voice = FollowVoiceGuidance(enabled: () => true, output: output);
      final f = RouteFixture();
      await f.join();
      void deliver() {
        for (final event in f.joins) {
          voice.announceOnce(
            room: 'ROOM',
            key: '${event.$1}:${event.$2}',
            text: '앞차가 지나간 경로를 따라갑니다',
          );
        }
      }

      deliver();
      deliver();
      f.controller.changeMode(FollowMode.b);
      f.update();
      deliver();
      await flush();
      expect(output.spoken, ['앞차가 지나간 경로를 따라갑니다']);
      voice.announceOnce(
        room: 'ROOM',
        key: 'follow-1:2',
        text: '앞차가 지나간 경로를 따라갑니다',
      );
      await flush();
      expect(output.spoken, hasLength(2));
      f.dispose();
      await voice.dispose();
    },
  );
  test(
    'invalidating route cancels queued merge speech without stopping call/readiness speech',
    () async {
      final output = _Output(hold: true);
      final coordinator = SpeechOutputCoordinator(output: output);
      final readiness = FollowVoiceGuidance(
        enabled: () => true,
        output: coordinator.scope(),
      );
      final route = FollowVoiceGuidance(
        enabled: () => true,
        output: coordinator.scope(),
      );
      readiness.announceOnce(room: 'ROOM', key: 'ready', text: '모두 준비되었습니다');
      await flush();
      route.announceOnce(
        room: 'ROOM',
        key: 'follow-1:1',
        text: '앞차가 지나간 경로를 따라갑니다',
      );
      await flush();
      route.clear();
      await flush();
      expect(output.stops, 0);
      output.pending!.complete();
      await flush();
      expect(output.spoken, ['모두 준비되었습니다']);
      await route.dispose();
      await readiness.dispose();
    },
  );
}

class _Output implements FollowSpeechOutput {
  _Output({this.hold = false});
  final bool hold;
  final spoken = <String>[];
  int stops = 0;
  Completer<void>? pending;
  @override
  Future<void> speak(String text, DateTime expiresAt) {
    spoken.add(text);
    return hold ? (pending = Completer<void>()).future : Future<void>.value();
  }

  @override
  Future<void> stop() async {
    stops++;
    if (pending != null && !pending!.isCompleted) pending!.complete();
  }
}
