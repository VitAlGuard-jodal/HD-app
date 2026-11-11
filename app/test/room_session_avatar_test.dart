import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/net/models.dart';

import 'support/consent_fakes.dart';

void main() {
  testWidgets('member-updated와 늦은 hello에서도 최신 avatar·입장 순서를 보존한다', (
    tester,
  ) async {
    final services = await ConsentTestServices.create(tester);
    services.api.members = const [
      Member('alice', '앨리스', '1', order: 3),
      Member('bob', '보비', '2', order: 5),
    ];
    try {
      await services.openRoom(tester);
      services.api.events.add(
        const MemberUpdated('alice', Avatar(kind: 'photo', version: 2)),
      );
      await pumpConsentUi(tester);
      final member = services.rooms.state.members.first;
      expect(member.avatar, const Avatar(kind: 'photo', version: 2));
      expect(member.order, 3);
      expect(member.joinedAt, '1');
      services.api.events.add(
        const MemberUpdated('alice', Avatar(kind: 'mascot-01', version: 1)),
      );
      services.api.events.add(Hello('bob', services.api.members));
      await pumpConsentUi(tester);
      expect(
        services.rooms.state.members.first.avatar,
        const Avatar(kind: 'photo', version: 2),
      );
      expect(services.rooms.state.members.first.order, 3);
    } finally {
      await services.finish(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('내 저장 결과는 SSE 없이도 방에 반영되고 이전 스냅샷으로 돌아가지 않는다', (tester) async {
    final services = await ConsentTestServices.create(tester);
    try {
      await services.openRoom(tester);
      await completeConsentFuture(
        tester,
        services.store.updateAvatar(
          const Avatar(kind: 'mascot-05', version: 4),
        ),
      );
      expect(
        services.rooms.state.members.last.avatar,
        const Avatar(kind: 'mascot-05', version: 4),
      );
      services.api.events.add(Hello('bob', services.api.members));
      await pumpConsentUi(tester);
      expect(
        services.rooms.state.members.last.avatar,
        const Avatar(kind: 'mascot-05', version: 4),
      );
      services.api.events.add(const MemberUpdated('bob', Avatar(version: 5)));
      await pumpConsentUi(tester);
      expect(
        services.rooms.state.members.last.avatar,
        const Avatar(version: 5),
      );
      expect(services.store.avatar, const Avatar(version: 5));
    } finally {
      await services.finish(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
