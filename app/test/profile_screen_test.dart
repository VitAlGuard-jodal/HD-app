import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:image_picker_platform_interface/src/method_channel/method_channel_image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unavo/auth/session_store.dart';
import 'package:unavo/net/api_client.dart';
import 'package:unavo/screens/phone/profile.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/member_avatar.dart';
import 'package:unavo/ui/widgets/panel_button.dart';

import 'support/avatar_fakes.dart';
import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

Future<Uint8List> _widePhoto() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 512, 256),
    Paint()..color = Colors.red,
  );
  canvas.drawRect(
    const Rect.fromLTWH(128, 0, 256, 256),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(512, 256);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  Future<(SessionStore, AvatarTestHttp, ApiClient)> setup(
    WidgetTester tester, {
    bool car = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'token': 'avatar-token',
      'handle': 'alice',
      'displayName': '앨리스',
    });
    final prefs = await completeConsentFuture(
      tester,
      SharedPreferences.getInstance(),
    );
    final store = SessionStore(prefs, defaultBaseUrl: 'https://avatar.invalid');
    addTearDown(store.dispose);
    final http = AvatarTestHttp();
    final api = http.api(store);
    await tester.pumpWidget(
      MaterialApp(
        builder: testIconBuilder,
        home: Builder(
          builder: (context) => Scaffold(
            body: IconButton(
              key: const ValueKey('launch'),
              icon: const SizedBox(width: 48, height: 48),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      ProfileScreen(api: api, store: store, car: car),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('launch')));
    await pumpConsentUi(tester);
    await tester.pump(const Duration(milliseconds: 350));
    return (store, http, api);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await pumpConsentUi(tester);
  }

  testWidgets('격자 5종 선택은 금색 테두리·미리보기를 바꾸고 check만 PUT한다', (tester) async {
    final (store, http, _) = await setup(tester);
    for (final kind in ['01', '02', '03', '04', '05']) {
      expect(find.byKey(ValueKey('profile-mascot-$kind')), findsOneWidget);
    }
    final preview = tester.widget<MemberAvatar>(
      find.byKey(const ValueKey('profile-preview')),
    );
    expect(preview.diameter, 120);
    expect(preview.showBorder, isFalse);
    await tap(tester, 'profile-mascot-03');
    expect(http.requests, isEmpty);
    expect(
      tester
          .widget<MemberAvatar>(find.byKey(const ValueKey('profile-preview')))
          .member
          .avatar
          .kind,
      'mascot-03',
    );
    final selected = tester.widget<MemberAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('profile-mascot-03')),
        matching: find.byType(MemberAvatar),
      ),
    );
    expect(selected.borderColor, UnavoColors.gold);
    await tap(tester, 'profile-save');
    expect(http.requests.single.method, 'PUT');
    expect(http.requests.single.uri.path, '/v1/me/avatar');
    expect(jsonDecode(utf8.decode(http.requests.single.body)), {
      'kind': 'mascot-03',
    });
    expect(store.avatar.kind, 'mascot-03');
    expect(store.avatar.version, 1);
    await tester.pump(const Duration(milliseconds: 900));
    // 퇴장 애니메이션 뒤 라우트가 트리에서 제거되는 프레임까지 진행한다.
    await tester.pump();
    expect(find.byType(ProfileScreen), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('차량 160px 미리보기와 80dp 아이콘, back은 변경을 버린다', (tester) async {
    final (store, http, _) = await setup(tester, car: true);
    expect(
      tester
          .widget<MemberAvatar>(find.byKey(const ValueKey('profile-preview')))
          .diameter,
      160,
    );
    await tap(tester, 'profile-mascot-05');
    final save = find.descendant(
      of: find.byKey(const ValueKey('profile-save')),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.getSize(save).height, greaterThanOrEqualTo(80));
    await tap(tester, 'profile-back');
    await tester.pump(const Duration(milliseconds: 350));
    expect(http.requests, isEmpty);
    expect(store.avatar.kind, isNull);
    expect(find.byType(ProfileScreen), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('가짜 ImagePicker 채널은 갤러리 옵션을 받고 중앙 256 PNG를 PUT한다', (
    tester,
  ) async {
    final (_, http, _) = await setup(tester);
    final originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = MethodChannelImagePicker();
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    final calls = <MethodCall>[];
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('unavo-avatar-'),
    );
    final file = File('${directory!.path}/wide.png');
    await tester.runAsync(() async => file.writeAsBytes(await _widePhoto()));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return file.path;
    });
    addTearDown(() async {
      ImagePickerPlatform.instance = originalPlatform;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      await directory.delete(recursive: true);
    });
    // 파일 읽기·엔진 PNG 변환은 실제 비동기 zone에서 완료를 기다린다.
    final gallery = tester.widget<PanelButton>(
      find.byKey(const ValueKey('profile-gallery')),
    );
    await tester.runAsync(() async {
      await (gallery.onPressed! as Future<void> Function())();
    });
    await tester.pump();
    expect(calls.single.method, 'pickImage');
    expect(
      calls.single.arguments,
      containsPair('source', ImageSource.gallery.index),
    );
    expect(calls.single.arguments, containsPair('maxWidth', 1024.0));
    expect(calls.single.arguments, containsPair('maxHeight', 1024.0));
    expect(calls.single.arguments, containsPair('imageQuality', 90));
    final preview = tester.widget<MemberAvatar>(
      find.byKey(const ValueKey('profile-preview')),
    );
    expect(preview.member.avatar.kind, 'photo');
    expect(preview.preview, isNotNull);
    expect(http.requests, isEmpty);
    await tap(tester, 'profile-save');
    final body =
        jsonDecode(utf8.decode(http.requests.single.body))
            as Map<String, dynamic>;
    expect(body['kind'], 'photo');
    final png = base64Decode(body['png'] as String);
    expect(png.length, lessThanOrEqualTo(300 * 1024));
    expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(ByteData.sublistView(png).getUint32(16), 256);
    expect(ByteData.sublistView(png).getUint32(20), 256);
    final pixels = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      try {
        return (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
      } finally {
        image.dispose();
        codec.dispose();
      }
    });
    // 원본 좌우 빨간 영역이 잘려 중앙 파란 정사각만 남는다.
    for (final index in [0, 4 * 128, 4 * (256 * 256 - 1)]) {
      expect(pixels!.sublist(index, index + 4), [33, 150, 243, 255]);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('네트워크 실패는 M4 안내를 표시하고 저장 초안을 유지한다', (tester) async {
    final (store, http, _) = await setup(tester, car: true);
    await tap(tester, 'profile-mascot-04');
    http.openError = const SocketException('offline');
    await tap(tester, 'profile-save');
    expect(find.text('서버에 연결하지 못했습니다. 서버 주소와 네트워크를 확인해 주세요.'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.getSize(find.byTooltip('닫기')).height, 80);
    expect(store.avatar.kind, isNull);
    expect(
      tester
          .widget<MemberAvatar>(find.byKey(const ValueKey('profile-preview')))
          .member
          .avatar
          .kind,
      'mascot-04',
    );
    final close = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(PanelButton),
    );
    await tester.tap(close);
    await pumpConsentUi(tester);
    http.openError = null;
    await tap(tester, 'profile-save');
    expect(store.avatar.kind, 'mascot-04');
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('갤러리 취소는 저장을 활성화하지 않으며 크기 초과 오류는 M4 안내 모달이다', (tester) async {
    final (_, http, _) = await setup(tester);
    final originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = MethodChannelImagePicker();
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    addTearDown(() {
      ImagePickerPlatform.instance = originalPlatform;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await tap(tester, 'profile-gallery');
    expect(
      tester
          .widget<PanelButton>(find.byKey(const ValueKey('profile-save')))
          .onPressed,
      isNull,
    );
    expect(http.requests, isEmpty);
    await tap(tester, 'profile-mascot-02');
    http.status = 413;
    await tap(tester, 'profile-save');
    expect(find.text('프로필 저장 오류'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
