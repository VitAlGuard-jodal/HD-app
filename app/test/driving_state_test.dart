import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/core/driving_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('차량은 restricted를 따르고 activeRestrictions 비트로 잠금을 추정하지 않는다', () async {
    final events = StreamController<Object?>(sync: true);
    final driving = DrivingState(mode: DeviceMode.car, events: events.stream);
    addTearDown(() async {
      driving.dispose();
      await events.close();
    });
    expect(driving.restricted, isFalse);
    expect(driving.available, isFalse);

    events.add({'restricted': true, 'activeRestrictions': 0});
    expect(driving.restricted, isTrue);
    expect(driving.available, isTrue);

    events.add({'restricted': false, 'activeRestrictions': 80});
    expect(driving.restricted, isFalse);
    expect(driving.available, isTrue);
  });

  test('available=false와 잘못된 이벤트는 잠금을 해제한다', () async {
    final events = StreamController<Object?>(sync: true);
    final driving = DrivingState(mode: DeviceMode.car, events: events.stream);
    addTearDown(() async {
      driving.dispose();
      await events.close();
    });
    for (final event in <Object?>[
      {'restricted': true, 'available': false},
      {'available': false},
      {'restricted': 'true'},
      null,
      'invalid',
    ]) {
      events.add({'restricted': true, 'available': true});
      expect(driving.restricted, isTrue);
      events.add(event);
      expect(driving.restricted, isFalse);
      expect(driving.available, isFalse);
    }
  });

  test('채널 오류 전후에는 미잠금이며 새 유효 이벤트로 복구한다', () async {
    final events = StreamController<Object?>(sync: true);
    final driving = DrivingState(mode: DeviceMode.car, events: events.stream);
    addTearDown(() async {
      driving.dispose();
      await events.close();
    });
    events.addError(PlatformException(code: 'unavailable'));
    expect(driving.restricted, isFalse);
    expect(driving.available, isFalse);
    events.add({'restricted': true});
    expect(driving.restricted, isTrue);
    events.addError(PlatformException(code: 'disconnected'));
    expect(driving.restricted, isFalse);
    expect(driving.available, isFalse);
    events.add({'restricted': true});
    expect(driving.restricted, isTrue);
    expect(driving.available, isTrue);
  });

  test('폰은 restricted=true를 흘려도 구독하거나 잠그지 않는다', () async {
    final events = StreamController<Object?>.broadcast(sync: true);
    final driving = DrivingState(mode: DeviceMode.phone, events: events.stream);
    addTearDown(() async {
      driving.dispose();
      await events.close();
    });
    expect(events.hasListener, isFalse);
    events.add({'restricted': true, 'available': true});
    expect(driving.restricted, isFalse);
    expect(driving.available, isFalse);
  });

  test('중복 이벤트는 알리지 않고 스트림 종료 시 미잠금으로 돌아간다', () async {
    final events = StreamController<Object?>(sync: true);
    final driving = DrivingState(mode: DeviceMode.car, events: events.stream);
    addTearDown(driving.dispose);
    var notifications = 0;
    driving.addListener(() => notifications++);
    events.add({'restricted': true});
    events.add({'restricted': true});
    expect(notifications, 1);
    await events.close();
    expect(driving.restricted, isFalse);
    expect(driving.available, isFalse);
    expect(notifications, 2);
  });

  test('dispose는 주행 이벤트 구독을 해제한다', () async {
    var cancellations = 0;
    final events = StreamController<Object?>.broadcast(
      sync: true,
      onCancel: () => cancellations++,
    );
    final driving = DrivingState(mode: DeviceMode.car, events: events.stream);
    expect(events.hasListener, isTrue);
    driving.dispose();
    expect(events.hasListener, isFalse);
    expect(cancellations, 1);
    events.add({'restricted': true});
    await events.close();
  });

  test('기본 EventChannel은 차량에서만 listen·cancel을 호출한다', () async {
    const channel = MethodChannel('unavo/drive');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final phone = DrivingState(mode: DeviceMode.phone);
    phone.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(methods, isEmpty);

    final car = DrivingState(mode: DeviceMode.car);
    await Future<void>.delayed(Duration.zero);
    expect(methods, ['listen']);
    car.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(methods, ['listen', 'cancel']);
  });
}
