import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/location/follow_voice_guidance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('공유 종료는 표시 이름으로 한 번 말하고 화면 알림을 소비하지 않는다', (tester) async {
    final f = _VoiceFixture();
    f.follow();
    f.end('stopped');
    f.end('stopped');
    f.follow(target: null);
    await tester.pump();
    expect(f.spoken, ['앨리스 님이 위치 공유를 끝냈습니다']);
    expect(
      f.calls.single.arguments['expiresAt'],
      f.time.add(const Duration(seconds: 10)).millisecondsSinceEpoch,
    );
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('지연은 받은 시간이 아닌 측정 시각 90초로 판단하고 stale 종료와 중복하지 않는다', (
    tester,
  ) async {
    final f = _VoiceFixture();
    f.follow(at: f.time.subtract(const Duration(seconds: 89)));
    await tester.pump();
    expect(f.spoken, isEmpty);
    await f.advance(tester, const Duration(seconds: 1));
    expect(f.spoken, ['앨리스 님 위치가 잠시 갱신되지 않고 있습니다']);
    f.follow(at: f.time.subtract(const Duration(seconds: 90)));
    f.end('stale');
    f.follow(target: null);
    await tester.pump();
    expect(f.spoken, hasLength(1));
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('첫 표본이 없어도 90초만 기다리고 복구 뒤 새 지연만 다시 말한다', (tester) async {
    final f = _VoiceFixture();
    f.follow(noFix: true);
    await f.advance(tester, const Duration(seconds: 90));
    expect(f.spoken, hasLength(1));
    f.follow(at: f.time);
    await tester.pump();
    expect(f.spoken, hasLength(1));
    await f.advance(tester, const Duration(seconds: 90));
    expect(f.spoken, hasLength(2));
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('지연 안내가 재생 중이면 종료 안내는 완료 뒤 순서대로 재생한다', (tester) async {
    final f = _VoiceFixture(hold: true);
    f.follow(at: f.time.subtract(const Duration(seconds: 90)));
    await tester.pump();
    f.end('stopped');
    await tester.pump();
    expect(f.spoken, hasLength(1));
    f.finish();
    await tester.pump();
    expect(f.spoken, ['앨리스 님 위치가 잠시 갱신되지 않고 있습니다', '앨리스 님이 위치 공유를 끝냈습니다']);
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('대기한 안내가 10초를 넘으면 버린다', (tester) async {
    final f = _VoiceFixture(hold: true);
    f.follow(at: f.time.subtract(const Duration(seconds: 90)));
    await tester.pump();
    f.end('stopped');
    await f.advance(tester, const Duration(seconds: 11));
    f.finish();
    await tester.pump();
    expect(f.spoken, hasLength(1));
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('새 측정값이 오면 SDK 초기화/재생 중인 지연 안내도 중지한다', (tester) async {
    final f = _VoiceFixture(hold: true);
    f.follow(at: f.time.subtract(const Duration(seconds: 90)));
    await tester.pump();
    f.follow(at: f.time);
    await tester.pump();
    expect(f.calls.map((call) => call.method), ['speak', 'stop']);
    expect(f.gates.single.isCompleted, isTrue);
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final action in ['leave', 'stop-follow', 'stop-share', 'room-change']) {
    testWidgets('$action는 재생·대기 안내와 지연 타이머를 비운다', (tester) async {
      final f = _VoiceFixture(hold: true);
      f.follow(at: f.time.subtract(const Duration(seconds: 90)));
      await tester.pump();
      f.end('stopped');
      switch (action) {
        case 'leave':
          f.follow(leaving: true);
        case 'stop-follow':
          f.voice.clear();
        case 'stop-share':
          f.follow(sharing: false);
        case 'room-change':
          f.follow(room: 'OTHER', target: null);
      }
      await tester.pump();
      expect(f.calls.where((call) => call.method == 'stop'), hasLength(1));
      await f.advance(tester, const Duration(minutes: 3));
      expect(f.spoken, hasLength(1));
      await f.close(tester);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('폰에서는 채널을 호출하지 않는다', (tester) async {
    final f = _VoiceFixture(car: false);
    f.follow();
    f.end('stopped');
    await f.advance(tester, const Duration(minutes: 3));
    expect(f.calls, isEmpty);
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('SDK 오류·미지원은 전파하거나 같은 사건을 재시도하지 않는다', (tester) async {
    final f = _VoiceFixture(fail: true);
    f.follow();
    f.end('stopped');
    await tester.pump();
    f.end('stopped');
    await tester.pump();
    expect(f.spoken, hasLength(1));
    expect(tester.takeException(), isNull);
    await f.close(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final reason in ['left', 'requester-stale', 'declined']) {
    testWidgets('$reason를 상대의 공유 중지로 잘못 말하지 않는다', (tester) async {
      final f = _VoiceFixture();
      f.follow();
      f.end(reason);
      await tester.pump();
      expect(f.spoken, isEmpty);
      await f.close(tester);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}

class _VoiceFixture {
  _VoiceFixture({bool car = true, this.hold = false, bool fail = false}) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'stop') {
        finish();
        return true;
      }
      if (fail) throw PlatformException(code: 'ON_DEVICE_ENGINE_ERROR');
      if (!hold) return true;
      final gate = Completer<bool>();
      gates.add(gate);
      return gate.future;
    });
    voice = FollowVoiceGuidance(enabled: () => car, now: () => time);
  }
  static const channel = MethodChannel('unavo/tts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bool hold;
  final calls = <MethodCall>[];
  final gates = <Completer<bool>>[];
  late final FollowVoiceGuidance voice;
  DateTime time = DateTime.utc(2026, 11, 13);
  List<String> get spoken => calls
      .where((call) => call.method == 'speak')
      .map((call) => call.arguments['text'] as String)
      .toList();

  void follow({
    String? room = 'ABC123',
    String? target = 'alice',
    DateTime? at,
    bool noFix = false,
    bool sharing = true,
    bool leaving = false,
  }) => voice.update(
    room: room,
    target: target,
    name: '앨리스',
    measuredAt: noFix ? null : (at ?? time).millisecondsSinceEpoch,
    sharing: sharing,
    leaving: leaving,
  );
  void end(String reason) =>
      voice.ended(target: 'alice', name: '앨리스', reason: reason);
  void finish() {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete(true);
    }
  }

  Future<void> advance(WidgetTester tester, Duration duration) async {
    time = time.add(duration);
    await tester.pump(duration);
  }

  Future<void> close(WidgetTester tester) async {
    final closing = voice.dispose();
    await tester.pump();
    await closing;
    finish();
    messenger.setMockMethodCallHandler(channel, null);
  }
}
