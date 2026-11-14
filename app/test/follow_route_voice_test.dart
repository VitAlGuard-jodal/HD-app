import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_route_controller.dart';
import 'package:unavo/location/follow_voice_guidance.dart';

import 'support/follow_route_fakes.dart';

void main() {
  test(
    'departure and actual return speak once per excursion despite recalculation and reconnect',
    () async {
      final output = _Output();
      final voice = FollowVoiceGuidance(enabled: () => true, output: output);
      final f = RouteFixture(
        onJoined: (id, round, rejoined) => voice.announceOnce(
          room: 'ROOM',
          key: '$id:joined:$round',
          text: rejoined ? '앞차가 지나간 경로를 다시 따라갑니다' : '앞차가 지나간 경로를 따라갑니다',
        ),
        onDeparted: (id, round) => voice.announceOnce(
          room: 'ROOM',
          key: '$id:departed:$round',
          text: '경로를 벗어났습니다. 다시 합류할 길을 안내합니다',
        ),
        onInvalidated: voice.clear,
      );
      await f.join();
      await flush();
      f.depart();
      await flush();
      f.driveUntil(30000);
      f.calls.last.succeed();
      await flush();
      f.update();
      f.connected = false;
      f.update();
      f.connected = true;
      f.update();
      for (final x in [100.0, 106.0, 112.0, 118.0]) f.drive(x);
      await flush();
      f.update();
      expect(f.controller.changeMode(FollowMode.meetingPoint), isFalse);
      await flush();
      expect(output.spoken, [
        '앞차가 지나간 경로를 따라갑니다',
        '경로를 벗어났습니다. 다시 합류할 길을 안내합니다',
        '앞차가 지나간 경로를 다시 따라갑니다',
      ]);
      f.dispose();
      await voice.dispose();
    },
  );
  test(
    'starting a recovery preserves queued departure, ending the relation cancels it',
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
      final f = RouteFixture(
        onDeparted: (id, round) => route.announceOnce(
          room: 'ROOM',
          key: '$id:departed:$round',
          text: '경로를 벗어났습니다. 다시 합류할 길을 안내합니다',
        ),
        onInvalidated: route.clear,
      );
      await f.join();
      readiness.announceOnce(room: 'ROOM', key: 'ready', text: '모두 준비되었습니다');
      await flush();
      f.depart();
      f.driveUntil(30000);
      await flush();
      expect(f.calls, hasLength(2));
      expect(output.stops, 0);
      output.pending!.complete();
      await flush();
      expect(output.spoken.last, '경로를 벗어났습니다. 다시 합류할 길을 안내합니다');
      f.controller.update(null);
      await flush();
      expect(output.stops, 1);
      f.dispose();
      await route.dispose();
      await readiness.dispose();
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
