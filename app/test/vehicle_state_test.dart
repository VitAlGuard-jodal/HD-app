import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/core/vehicle_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('폰은 차량 스트림을 구독하지 않고 수동 준비만 한다', () async {
    var listened = false;
    final events = StreamController<Object?>(onListen: () => listened = true);
    final state = VehicleState(mode: DeviceMode.phone, events: events.stream);
    expect(listened, isFalse);
    expect(state.available, isFalse);
    expect(state.readyBlockedReason, isNull);
    expect(state.exiting, isFalse);
    state.dispose();
    unawaited(events.close());
  });

  // Only a stream/notifier is involved. Real event-queue draining also lets
  // close() complete after dispose() cancels the last subscription.
  test('지원 문 전체·P 조합과 알 수 없는 신호의 수동 대체', () async {
    final events = StreamController<Object?>();
    final state = VehicleState(mode: DeviceMode.car, events: events.stream);
    Future<void> update(
      Map<String, int?> doors,
      bool? parked, {
      String? front = 'ROW_1_LEFT',
    }) async {
      events.add({
        'available': true,
        'doors': doors,
        'parked': parked,
        'exitDoor': front,
      });
      await pumpEventQueue();
    }

    try {
      await update({'ROW_1_LEFT': 0, 'ROW_2_RIGHT': 0}, true);
      expect(state.available, isTrue);
      expect(state.readyBlockedReason, isNull);
      await update({'ROW_1_LEFT': 0, 'ROW_2_RIGHT': 1}, true);
      expect(state.readyBlockedReason, '문이 열려 있습니다');
      expect(state.exiting, isFalse);
      await update({'ROW_1_LEFT': 0}, false);
      expect(state.readyBlockedReason, 'P단에서 준비할 수 있습니다');
      await update({'ROW_1_LEFT': 1}, false);
      expect(state.exiting, isFalse);
      await update({'ROW_1_LEFT': 1}, true);
      expect(state.exiting, isTrue);
      await update({'ROW_1_RIGHT': 1}, true, front: 'ROW_1_RIGHT');
      expect(state.exiting, isTrue);
      await update({'REAR': 1}, true, front: null);
      expect(state.exiting, isFalse);
      await update({'ROW_1_LEFT': null}, true);
      expect(state.available, isFalse);
      expect(state.readyBlockedReason, isNull);
      await update({'ROW_1_LEFT': 0}, null);
      expect(state.available, isFalse);
      expect(state.readyBlockedReason, isNull);
      events.addError(StateError('unsupported'));
      await pumpEventQueue();
      expect(state.available, isFalse);
      expect(state.exiting, isFalse);
    } finally {
      state.dispose();
      await pumpEventQueue();
      expect(events.hasListener, isFalse);
      await events.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
