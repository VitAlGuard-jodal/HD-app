import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/ui/member_colors.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/member_avatar.dart';
import 'package:unavo/ui/widgets/member_tile.dart';
import 'package:unavo/ui/icons.dart';

import 'support/avatar_fakes.dart';
import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

void main() {
  testWidgets('방 SSE 프로필 갱신은 내 저장값과 순번을 유지하고 오래된 hello를 무시한다', (tester) async {
    final services = await ConsentTestServices.create(tester);
    services.api.members = const [
      Member('alice', '앨리스', '1', order: 0),
      Member('bob', '보비', '2', order: 3),
    ];
    try {
      await services.openRoom(tester);
      services.api.events.add(
        const MemberUpdated('bob', Avatar(kind: 'mascot-04', version: 4)),
      );
      await pumpConsentUi(tester);
      expect(
        services.store.avatar,
        const Avatar(kind: 'mascot-04', version: 4),
      );
      expect(services.rooms.state.members.last.avatar, services.store.avatar);
      expect(services.rooms.state.members.last.order, 3);
      services.api.events.add(Hello('bob', services.api.members, 'alice'));
      await pumpConsentUi(tester);
      expect(services.rooms.state.members.last.avatar.version, 4);
      services.api.events.add(const MemberUpdated('bob', Avatar(version: 3)));
      await pumpConsentUi(tester);
      expect(services.rooms.state.members.last.avatar.version, 4);
    } finally {
      await services.finish(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: testIconBuilder,
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pump();
  }

  testWidgets('null은 첫 글자, 마스코트 5종은 자산과 공통 0.82 축소 규칙을 쓴다', (tester) async {
    await mount(
      tester,
      const MemberAvatar(member: Member('alice', '앨리스', ''), diameter: 80),
    );
    expect(find.text('앨'), findsOneWidget);
    for (final kind in Avatar.mascotKinds) {
      await mount(
        tester,
        MemberAvatar(
          member: Member('alice', '앨리스', '', avatar: Avatar(kind: kind)),
          diameter: 80,
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, 'assets/avatars/$kind.png');
      final transform = tester.widget<Transform>(
        find.descendant(
          of: find.byType(MemberAvatar),
          matching: find.byType(Transform),
        ),
      );
      expect(
        transform.transform.entry(0, 0),
        kind == 'mascot-02' || kind == 'mascot-05' ? .82 : 1,
      );
      expect(find.byType(ClipOval), findsOneWidget);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('서버 순번 색을 유지하며 발화는 바깥 형광 글로우로 표시한다', (tester) async {
    for (final order in <int?>[4, null]) {
      await mount(
        tester,
        MemberAvatar(
          member: Member('alice', '앨리스', '', order: order),
          diameter: 80,
          fallbackOrder: 2,
          speaking: true,
        ),
      );
      final decorated = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(MemberAvatar),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = decorated.decoration! as BoxDecoration;
      expect(
        (decoration.border! as Border).top.color,
        rainbowColor(order ?? 2),
      );
      expect((decoration.border! as Border).top.width, 3);
      expect(
        decoration.boxShadow!.single.color,
        UnavoColors.speaking.withValues(alpha: .65),
      );
    }
    await mount(
      tester,
      const MemberAvatar(
        member: Member('alice', '앨리스', ''),
        diameter: 120,
        showBorder: false,
      ),
    );
    final decoration =
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byType(MemberAvatar),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(decoration.border, isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('사진은 인증·버전 URL로 불러오며 같은 버전은 캐시하고 실패하면 첫 글자다', (tester) async {
    final http = AvatarTestHttp();
    http.photo = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 256, 256),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(256, 256);
      try {
        return (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
      }
    });
    final api = http.api(AvatarTestTokenStore());
    Member member(int version) => Member(
      'alice',
      '앨리스',
      '',
      avatar: Avatar(kind: 'photo', version: version),
    );
    await mount(
      tester,
      MemberAvatar(member: member(1), diameter: 80, api: api),
    );
    // HTTP 응답 스트림과 FutureBuilder가 완료된 프레임까지 유한하게 진행한다.
    await pumpConsentUi(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(http.requests.single.uri.path, '/v1/users/alice/avatar');
    expect(http.requests.single.uri.queryParameters, {'v': '1'});
    expect(
      http.requests.single.sentHeaders['authorization'],
      'Bearer avatar-token',
    );
    await mount(
      tester,
      MemberAvatar(member: member(1), diameter: 80, api: api),
    );
    expect(http.requests, hasLength(1));
    http.status = 404;
    await mount(
      tester,
      MemberAvatar(member: member(2), diameter: 80, api: api),
    );
    await pumpConsentUi(tester);
    expect(http.requests, hasLength(2));
    expect(http.requests.last.uri.queryParameters['v'], '2');
    expect(find.text('앨'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('C-1 내 카드와 상대 카드는 기본 마스코트이고 사람 상태 아이콘은 없다', (tester) async {
    for (final self in [true, false]) {
      for (final compact in [true, false]) {
        await mount(
          tester,
          SizedBox(
            width: 260,
            child: MemberTile(
              member: const Member('alice', '긴 이름 두 줄을 그대로 보존', '', order: 3),
              self: self,
              compact: compact,
            ),
          ),
        );
        expect(
          (tester.widget<Image>(find.byType(Image)).image as AssetImage)
              .assetName,
          'assets/avatars/mascot-01.png',
        );
        expect(
          find.byWidgetPredicate((w) => w is UnavoIcon && w.name == 'user'),
          findsNothing,
        );
        expect(tester.widget<Text>(find.text('긴 이름 두 줄을 그대로 보존')).maxLines, 2);
        expect(
          tester.getCenter(find.byType(MemberAvatar)).dy,
          closeTo(tester.getCenter(find.byType(MemberTile)).dy, .01),
        );
        expect(
          tester.getRect(find.byType(MemberAvatar)).right,
          lessThan(tester.getRect(find.text('긴 이름 두 줄을 그대로 보존')).left),
        );
        expect(tester.takeException(), isNull);
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('member-updated SSE는 프로필 버전을 읽는다', () async {
    final stream = StreamController<List<int>>();
    final http = AvatarTestHttp()..eventStream = stream.stream;
    final api = http.api(AvatarTestTokenStore());
    final event = api.subscribeEvents('ABC123').first;
    stream.add(
      utf8.encode(
        'event: member-updated\ndata: {"handle":"alice","avatar":{"kind":"mascot-04","version":8}}\n\n',
      ),
    );
    final updated = await event as MemberUpdated;
    expect(updated.handle, 'alice');
    expect(updated.avatar, const Avatar(kind: 'mascot-04', version: 8));
    await stream.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
