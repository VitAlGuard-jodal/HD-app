import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo_noise/unavo_noise.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('unavo/noise');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('setEnabled는 configure 요청과 네이티브 활성화 상태를 전달한다', () async {
    final calls = <MethodCall>[];
    var response = <String, Object?>{'enabled': true, 'dumpSeconds': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });

    expect(await UnavoNoise.setEnabled(true), isTrue);
    response = <String, Object?>{'enabled': false, 'dumpSeconds': 0};
    expect(await UnavoNoise.setEnabled(false), isFalse);

    expect(calls, hasLength(2));
    for (final call in calls) {
      expect(call.method, 'configure');
    }
    expect(calls[0].arguments, <String, Object?>{
      'enabled': true,
      'dumpSeconds': 0,
      'floor': true,
    });
    expect(calls[1].arguments, <String, Object?>{
      'enabled': false,
      'dumpSeconds': 0,
      'floor': true,
    });
  });

  test('configure는 설정 인자와 Map 응답을 전달한다', () async {
    final calls = <MethodCall>[];
    final response = <String, Object?>{
      'supported': true,
      'enabled': false,
      'dumpSeconds': 60,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });

    expect(
      await UnavoNoise.configure(enabled: false, dumpSeconds: 60),
      response,
    );
    expect(
      await UnavoNoise.configure(enabled: false, dumpSeconds: 60, floor: false),
      response,
    );

    expect(calls, hasLength(2));
    for (final call in calls) {
      expect(call.method, 'configure');
    }
    expect(calls[0].arguments, <String, Object?>{
      'enabled': false,
      'dumpSeconds': 60,
      'floor': true,
    });
    expect(calls[1].arguments, <String, Object?>{
      'enabled': false,
      'dumpSeconds': 60,
      'floor': false,
    });
  });

  test('exportDump는 포트 인자와 Map 응답을 전달한다', () async {
    final calls = <MethodCall>[];
    final response = <String, Object?>{
      'supported': true,
      'exportPort': 18085,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return response;
    });

    expect(await UnavoNoise.exportDump(port: 18085), response);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'exportDump');
    expect(calls.single.arguments, <String, Object?>{'port': 18085});
  });

  test('플러그인이 없으면 setEnabled는 false를 반환한다', () async {
    messenger.setMockMethodCallHandler(channel, null);

    expect(await UnavoNoise.setEnabled(true), isFalse);
    expect(await UnavoNoise.setEnabled(false), isFalse);
  });

  test('플러그인이 없으면 configure는 supported false를 반환한다', () async {
    messenger.setMockMethodCallHandler(channel, null);

    expect(
      await UnavoNoise.configure(enabled: false, dumpSeconds: 60),
      <String, Object?>{'supported': false},
    );
  });

  test('플러그인이 없으면 exportDump는 supported false를 반환한다', () async {
    messenger.setMockMethodCallHandler(channel, null);

    expect(
      await UnavoNoise.exportDump(port: 18085),
      <String, Object?>{'supported': false},
    );
  });

  test('플러그인이 없으면 status는 supported false를 반환한다', () async {
    messenger.setMockMethodCallHandler(channel, null);

    expect(await UnavoNoise.status(), <String, Object?>{'supported': false});
  });
}
