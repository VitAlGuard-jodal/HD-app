import 'dart:async';
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
import 'package:unavo/ui/icons.dart';
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

  Future<void> closeSource(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('profile-source-dialog')),
        matching: find.byTooltip('닫기'),
      ),
    );
    await pumpConsentUi(tester);
  }

  void expectCenteredPlus(WidgetTester tester, {double diameter = 120}) {
    final plus = find.byKey(const ValueKey('profile-edit-plus'));
    expect(plus, findsOneWidget);
    final disk = tester.widget<Container>(plus);
    final decoration = disk.decoration! as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.color, UnavoColors.ink.withValues(alpha: .45));
    expect(decoration.color!.a, closeTo(.45, .001));
    expect(tester.getSize(plus), Size.square(diameter * .4));
    expect(
      tester.getCenter(plus),
      tester.getCenter(find.byKey(const ValueKey('profile-preview'))),
    );
    final icon = tester.widget<UnavoIcon>(
      find.descendant(of: plus, matching: find.byType(UnavoIcon)),
    );
    expect(icon.name, 'plus');
    expect(icon.color, Colors.white.withValues(alpha: .9));
    expect(icon.color.a, closeTo(.9, .001));
    expect(icon.size, closeTo(diameter * .4 * .55, .001));
  }

  testWidgets('초기 본문은 선택 버튼 없이 미리보기와 가운데 반투명 plus만 표시한다', (tester) async {
    await setup(tester);
    expect(find.byKey(const ValueKey('profile-gallery')), findsNothing);
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
    for (final kind in ['01', '02', '03', '04', '05']) {
      expect(find.byKey(ValueKey('profile-mascot-$kind')), findsNothing);
    }
    final preview = tester.widget<MemberAvatar>(
      find.byKey(const ValueKey('profile-preview')),
    );
    expect(preview.diameter, 120);
    expect(preview.showBorder, isFalse);
    expectCenteredPlus(tester);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == '프로필 사진 바꾸기' &&
            widget.properties.button == true &&
            widget.properties.enabled == true,
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('profile-edit')))
          .onPressed,
      isNotNull,
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('프로필 원은 사진첩과 마스코트 5종의 아이콘 모달을 열고 바깥 탭·시스템 back으로 닫힌다', (
    tester,
  ) async {
    await setup(tester);
    await tap(tester, 'profile-edit');
    final dialog = find.byKey(const ValueKey('profile-source-dialog'));
    expect(dialog, findsOneWidget);
    final gallery = find.descendant(
      of: dialog,
      matching: find.byKey(const ValueKey('profile-gallery')),
    );
    expect(gallery, findsOneWidget);
    final button = tester.widget<PanelButton>(gallery);
    expect(button.icon, 'plus');
    expect(button.label, '사진첩에서 선택');
    expect(button.iconOnly, isTrue);
    expect(find.text('사진첩에서 선택'), findsNothing);
    expect(find.text('닫기'), findsNothing);
    for (final kind in ['01', '02', '03', '04', '05']) {
      final mascot = find.descendant(
        of: dialog,
        matching: find.byKey(ValueKey('profile-mascot-$kind')),
      );
      expect(mascot, findsOneWidget);
      expect(
        tester
            .widget<MemberAvatar>(
              find.descendant(of: mascot, matching: find.byType(MemberAvatar)),
            )
            .diameter,
        72,
      );
      expect(
        tester.getTopLeft(mascot).dy,
        greaterThan(tester.getBottomLeft(gallery).dy),
      );
    }
    await tester.tapAt(const Offset(5, 5));
    await pumpConsentUi(tester);
    expect(dialog, findsNothing);
    await tap(tester, 'profile-edit');
    expect(dialog, findsOneWidget);
    await tester.binding.handlePopRoute();
    await pumpConsentUi(tester);
    expect(dialog, findsNothing);
    await tap(tester, 'profile-edit');
    expect(dialog, findsOneWidget);
    await closeSource(tester);
    expect(dialog, findsNothing);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('모달의 마스코트 선택은 즉시 닫혀 미리보기·금색 테두리를 바꾸고 check만 PUT한다', (
    tester,
  ) async {
    final (store, http, _) = await setup(tester);
    await tap(tester, 'profile-edit');
    await tap(tester, 'profile-mascot-03');
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
    expect(http.requests, isEmpty);
    expect(
      tester
          .widget<MemberAvatar>(find.byKey(const ValueKey('profile-preview')))
          .member
          .avatar
          .kind,
      'mascot-03',
    );
    expectCenteredPlus(tester);
    await tap(tester, 'profile-edit');
    for (final kind in ['01', '02', '03', '04', '05']) {
      final mascot = tester.widget<MemberAvatar>(
        find.descendant(
          of: find.byKey(ValueKey('profile-mascot-$kind')),
          matching: find.byType(MemberAvatar),
        ),
      );
      expect(
        mascot.borderColor,
        kind == '03' ? UnavoColors.gold : Colors.transparent,
      );
    }
    await closeSource(tester);
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

  testWidgets('차량은 미리보기 160·마스코트 96·모달 버튼 80dp이고 back은 변경을 버린다', (
    tester,
  ) async {
    final (store, http, _) = await setup(tester, car: true);
    expect(
      tester
          .widget<MemberAvatar>(find.byKey(const ValueKey('profile-preview')))
          .diameter,
      160,
    );
    expectCenteredPlus(tester, diameter: 160);
    await tap(tester, 'profile-edit');
    for (final kind in ['01', '02', '03', '04', '05']) {
      final mascot = find.byKey(ValueKey('profile-mascot-$kind'));
      expect(
        tester
            .widget<MemberAvatar>(
              find.descendant(of: mascot, matching: find.byType(MemberAvatar)),
            )
            .diameter,
        96,
      );
      expect(tester.getSize(mascot).height, greaterThanOrEqualTo(80));
    }
    expect(tester.getSize(find.byTooltip('닫기')).height, 80);
    expect(
      tester.getSize(find.byKey(const ValueKey('profile-gallery'))).height,
      greaterThanOrEqualTo(80),
    );
    await tap(tester, 'profile-mascot-05');
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
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

  testWidgets('모달 닫기는 선택과 저장 활성화 상태를 그대로 유지한다', (tester) async {
    final (store, http, _) = await setup(tester);
    final preview = find.byKey(const ValueKey('profile-preview'));
    final save = find.byKey(const ValueKey('profile-save'));
    await tap(tester, 'profile-edit');
    await closeSource(tester);
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
    expect(tester.widget<MemberAvatar>(preview).member.avatar.kind, isNull);
    expect(tester.widget<MemberAvatar>(preview).preview, isNull);
    expect(tester.widget<PanelButton>(save).onPressed, isNull);
    await tap(tester, 'profile-edit');
    await tap(tester, 'profile-mascot-02');
    await tap(tester, 'profile-edit');
    await closeSource(tester);
    expect(
      tester.widget<MemberAvatar>(preview).member.avatar.kind,
      'mascot-02',
    );
    expect(tester.widget<PanelButton>(save).onPressed, isNotNull);
    expect(store.avatar.kind, isNull);
    expect(http.requests, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('사진첩은 모달 제거 후 한 번만 열리고 처리 중 편집·저장을 비활성화한다', (tester) async {
    final (_, http, _) = await setup(tester);
    final originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = MethodChannelImagePicker();
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    final result = Completer<String?>();
    final calls = <MethodCall>[];
    final dialogsAtPick = <int>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      dialogsAtPick.add(
        find
            .byKey(const ValueKey('profile-source-dialog'), skipOffstage: false)
            .evaluate()
            .length,
      );
      return result.future;
    });
    addTearDown(() {
      ImagePickerPlatform.instance = originalPlatform;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    await tap(tester, 'profile-edit');
    await tap(tester, 'profile-gallery');
    expect(calls.single.method, 'pickImage');
    expect(dialogsAtPick, [0]);
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
    final edit = find.byKey(const ValueKey('profile-edit'));
    expect(tester.widget<IconButton>(edit).onPressed, isNull);
    for (final key in ['profile-back', 'profile-save']) {
      expect(
        tester.widget<PanelButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
      );
    }
    final plus = tester.widget<UnavoIcon>(
      find.descendant(
        of: find.byKey(const ValueKey('profile-edit-plus')),
        matching: find.byType(UnavoIcon),
      ),
    );
    expect(plus.color, UnavoColors.text.withValues(alpha: .4));
    await tester.tap(edit);
    await pumpConsentUi(tester);
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
    expect(calls, hasLength(1));
    result.complete(null);
    await pumpConsentUi(tester);
    expect(tester.widget<IconButton>(edit).onPressed, isNotNull);
    expect(
      tester
          .widget<PanelButton>(find.byKey(const ValueKey('profile-save')))
          .onPressed,
      isNull,
    );
    expectCenteredPlus(tester);
    expect(http.requests, isEmpty);
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
    await tap(tester, 'profile-edit');
    // 모달 퇴장은 유한 pump로, 파일 읽기·엔진 PNG 변환은 실제 zone에서 기다린다.
    final gallery = tester.widget<PanelButton>(
      find.byKey(const ValueKey('profile-gallery')),
    );
    late Future<void> picking;
    await tester.runAsync(() async {
      picking = (gallery.onPressed! as Future<void> Function())();
    });
    await pumpConsentUi(tester);
    await tester.runAsync(() async => picking);
    await tester.pump();
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
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
    expectCenteredPlus(tester);
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
    await tap(tester, 'profile-edit');
    await tap(tester, 'profile-mascot-04');
    http.openError = const SocketException('offline');
    await tap(tester, 'profile-save');
    expect(find.text('서버에 연결하지 못했습니다. 서버 주소와 네트워크를 확인해 주세요.'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.getSize(find.byTooltip('닫기')).height, 80);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('profile-edit')))
          .onPressed,
      isNull,
    );
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
    await tap(tester, 'profile-edit');
    await tap(tester, 'profile-gallery');
    expect(find.byKey(const ValueKey('profile-source-dialog')), findsNothing);
    expect(
      tester
          .widget<PanelButton>(find.byKey(const ValueKey('profile-save')))
          .onPressed,
      isNull,
    );
    expect(http.requests, isEmpty);
    await tap(tester, 'profile-edit');
    await tap(tester, 'profile-mascot-02');
    // 기존 초안이 있는 상태에서 사진첩을 취소해도 선택과 변경 상태를 유지한다.
    await tap(tester, 'profile-edit');
    await tap(tester, 'profile-gallery');
    expect(
      tester
          .widget<MemberAvatar>(find.byKey(const ValueKey('profile-preview')))
          .member
          .avatar
          .kind,
      'mascot-02',
    );
    expect(
      tester
          .widget<PanelButton>(find.byKey(const ValueKey('profile-save')))
          .onPressed,
      isNotNull,
    );
    http.status = 413;
    await tap(tester, 'profile-save');
    expect(find.text('프로필 저장 오류'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
