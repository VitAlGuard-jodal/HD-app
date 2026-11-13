import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_voice_guidance.dart';

void main() {
  // These queues have no widgets. Drain real futures so the output callback
  // never runs its assertion inside WidgetTester's guarded pump.
  test('준비 취소와 따라가기 음성은 직렬화하고 서로의 중지를 격리한다', () async {
    final output = _Output();
    final now = DateTime.utc(2026);
    final coordinator = SpeechOutputCoordinator(output: output, now: () => now);
    final follow = coordinator.scope(), ready = coordinator.scope();
    addTearDown(() async {
      await follow.stop();
      await ready.stop();
      await pumpEventQueue();
    });
    final expiry = now.add(const Duration(seconds: 10));
    final first = follow.speak('위치 지연', expiry);
    await pumpEventQueue();
    final second = ready.speak('준비가 취소됐습니다', expiry);
    await pumpEventQueue();
    expect(output.texts, ['위치 지연']);
    await follow.stop();
    await pumpEventQueue();
    expect(output.texts, ['위치 지연', '준비가 취소됐습니다']);
    await follow.stop(); // a late follow clear cannot silence readiness
    expect(output.stops, 1);
    output.finish();
    await first;
    await second;
    expect(output.pending, isNull);
  });

  test('준비 안내의 중복 억제·만료·새 준비 주기 초기화는 D2 큐를 쓴다', () async {
    final output = _Output();
    var now = DateTime.utc(2026);
    final coordinator = SpeechOutputCoordinator(output: output, now: () => now);
    final follow = coordinator.scope();
    final ready = FollowVoiceGuidance(
      enabled: () => true,
      output: coordinator.scope(),
      now: () => now,
    );
    addTearDown(() async {
      await ready.dispose();
      await follow.stop();
      await pumpEventQueue();
    });
    void cancelReady() => ready.announceOnce(
      room: 'ABC123',
      key: 'ready-cancelled',
      text: '준비가 취소됐습니다',
    );
    final busy = follow.speak('먼저 재생 중', now.add(const Duration(seconds: 30)));
    await pumpEventQueue();
    cancelReady();
    cancelReady();
    await pumpEventQueue(); // queue readiness behind the active follow utterance
    now = now.add(const Duration(seconds: 11));
    output.finish();
    await busy;
    await pumpEventQueue();
    expect(output.texts, ['먼저 재생 중']); // expired while the other scope spoke
    ready.clear();
    cancelReady();
    await pumpEventQueue();
    expect(output.texts, ['먼저 재생 중', '준비가 취소됐습니다']);
    cancelReady();
    await pumpEventQueue();
    expect(output.texts, hasLength(2));
    await ready.dispose();
    await pumpEventQueue();
    expect(output.pending, isNull);
    expect(output.stops, 1);
  });
}

class _Output implements FollowSpeechOutput {
  final texts = <String>[];
  Completer<void>? pending;
  int stops = 0;
  @override
  Future<void> speak(String text, DateTime expiresAt) {
    expect(pending, isNull, reason: 'one native utterance at a time');
    texts.add(text);
    return (pending = Completer<void>()).future;
  }

  void finish() {
    final done = pending;
    pending = null;
    done?.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    finish();
  }
}
