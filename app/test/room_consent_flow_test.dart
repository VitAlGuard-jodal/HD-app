import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:unavo/auth/legal_consent_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/device_mode.dart';
import 'package:unavo/call/call_state.dart';
import 'package:unavo/map/vworld_room_map.dart';
import 'package:unavo/location/location_share.dart';
import 'package:unavo/location/location_source.dart';
import 'package:unavo/map/room_map.dart';
import 'package:unavo/map/room_map_widgets.dart';
import 'package:unavo/net/models.dart';
import 'package:unavo/room/room_session.dart';
import 'package:unavo/screens/phone/room.dart';
import 'package:unavo/ui/appearance.dart';
import 'package:unavo/ui/theme.dart';
import 'package:unavo/ui/widgets/floating_bar.dart';
import 'package:unavo/ui/widgets/member_avatar.dart';
import 'package:unavo/ui/widgets/unavo_watermark.dart';

import 'support/consent_fakes.dart';
import 'support/icon_bundle.dart';

const _timeout = Timeout(Duration(seconds: 30));

void main() {
  for (final car in [false, true]) {
    testWidgets('상대 퇴장 뒤 종료 모달은 아이디 대신 마지막 표시 이름을 쓴다 (차량 $car)', (
      tester,
    ) async {
      final f = await _Fixture.create(tester, car: car);
      try {
        await _member(tester, 'alice');
        await _tap(tester, '동의');
        f.services.api.members = const [Member('bob', '보비', '2')];
        f.services.api.events.add(const MemberLeft('alice', revision: 2));
        await pumpConsentUi(tester);
        expect(
          f.services.rooms.state.members.any(
            (member) => member.handle == 'alice',
          ),
          isFalse,
          reason: '종료 모달을 표시할 때 대상은 이미 멤버 목록에서 빠져 있어야 한다',
        );
        expect(
          find.text('앨리스 님이 연결을 종료하여 따라가기가 끝났습니다'),
          findsOneWidget,
          reason: '폰·차량의 퇴장 안내에는 캐시된 표시 이름을 사용한다',
        );
        expect(
          find.text('alice 님이 연결을 종료하여 따라가기가 끝났습니다'),
          findsNothing,
          reason: '알고 있던 표시 이름을 아이디로 대체하지 않는다',
        );
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  testWidgets('C3/C8 중지는 과거 위치 오류를 지우고 삭제 대기와 현재 음성 오류를 따로 표시한다', (
    tester,
  ) async {
    final f = await _Fixture.create(tester);
    try {
      await completeConsentFuture(
        tester,
        f.services.locationShare.start(token: Object(), stillValid: () => true),
      );
      f.services.locationSource.controllers.last.addError(
        StateError('이전 위치 오류'),
      );
      await pumpConsentUi(tester);
      expect(f.services.locationShare.error, isNotNull);
      f.services.rooms.mediaError = '현재 음성 오류';
      f.services.api.stopFails = true;
      await _member(tester, 'bob');
      await _tap(tester, '동의');
      expect(f.services.locationShare.error, isNull);
      expect(find.text('위치 삭제 대기 중'), findsOneWidget);
      expect(find.text('현재 음성 오류'), findsOneWidget);
      expect(f.services.locationShare.sharing, isFalse);
      f.services.api.stopFails = false;
      await tester.pump(const Duration(seconds: 1));
      await pumpConsentUi(tester);
      expect(find.text('위치 삭제 대기 중'), findsNothing);
      expect(find.text('현재 음성 오류'), findsOneWidget);
    } finally {
      f.services.api.stopFails = false;
      await f.dispose(tester);
    }
  }, timeout: _timeout);
  for (final inMap in [false, true]) {
    testWidgets('내 카드·지도 공유 중지 모달은 같은 회색 안내와 동의 동작을 쓴다 (지도 $inMap)', (
      tester,
    ) async {
      final f = await _Fixture.create(tester);
      try {
        await completeConsentFuture(
          tester,
          f.services.locationShare.start(
            token: Object(),
            stillValid: () => true,
          ),
        );
        if (inMap)
          await completeConsentFuture(
            tester,
            f.services.rooms.startFollowing('alice'),
          );
        await pumpConsentUi(tester);
        if (inMap)
          await _tap(tester, '위치 공유 중지');
        else
          await _member(tester, 'bob');
        expect(find.text('위치 공유 중지'), findsOneWidget);
        expect(find.text('내 위치 공유를 중지합니다'), findsOneWidget);
        final note = find.text(
          '위치 공유를 중단하면 그룹 안 파트너와의 따라가기 연결이 끊깁니다. 통화는 계속됩니다. 그래도 하시겠습니까?',
        );
        expect(note, findsOneWidget);
        expect(tester.widget<Text>(note).style?.color, UnavoColors.muted);
        await _tap(tester, '미동의');
        expect(f.services.locationShare.sharing, isTrue);
        if (inMap)
          await _tap(tester, '위치 공유 중지');
        else
          await _member(tester, 'bob');
        await _tap(tester, '동의');
        expect(f.services.locationShare.sharing, isFalse);
        expect(f.services.rooms.followTarget, isNull);
        expect(find.byType(RoomMap), findsNothing);
        expect(f.services.api.stops, 1);
        await _member(tester, 'bob');
        expect(find.byType(Dialog), findsNothing);
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  for (final incoming in [false, true]) {
    testWidgets('C2 OS 권한 대기 중 ${incoming ? "요청 취소" : "대상 퇴장"}는 GPS를 켜지 않는다', (
      tester,
    ) async {
      final f = await _Fixture.create(
        tester,
        handle: incoming ? 'alice' : 'bob',
      );
      final permission = Completer<LocationPermissionState>();
      f.services.locationSource.pendingPermission = permission;
      try {
        if (incoming) {
          f.services.api.events.add(
            const FollowRequest(
              'bob',
              requestId: 'pending',
              displayName: '보비',
              revision: 1,
            ),
          );
          await pumpConsentUi(tester);
        } else {
          await _member(tester, 'alice');
        }
        await _tap(tester, '동의');
        expect(f.services.locationSource.requests, 1);
        f.services.api.events.add(
          incoming
              ? const FollowCancelled('bob', requestId: 'pending', revision: 2)
              : const MemberLeft('alice'),
        );
        await pumpConsentUi(tester);
        permission.complete(LocationPermissionState.granted);
        await pumpConsentUi(tester);
        expect(f.services.locationSource.watches, 0);
        expect(f.services.locationShare.sharing, isFalse);
        expect(f.services.api.follows, isEmpty);
        expect(f.services.api.followResponses, isEmpty);
      } finally {
        if (!permission.isCompleted)
          permission.complete(LocationPermissionState.denied);
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  testWidgets('C6 멤버 조회 실패에도 요청 이름으로 모달을 보존하고 refresh 중 취소는 표시하지 않는다', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, handle: 'alice');
    try {
      final gate = Completer<void>();
      f.services.api.roomGate = gate.future;
      f.services.api.roomFails = true;
      f.services.api.events.add(
        const FollowRequest(
          'charlie',
          requestId: 'r1',
          displayName: '이벤트 이름',
          revision: 1,
        ),
      );
      await pumpConsentUi(tester);
      expect(find.byType(Dialog), findsNothing);
      f.services.api.events.add(
        const FollowCancelled('charlie', requestId: 'r1', revision: 2),
      );
      await pumpConsentUi(tester);
      gate.complete();
      await pumpConsentUi(tester);
      expect(find.byType(Dialog), findsNothing);
      f.services.api.events.add(
        const FollowRequest(
          'charlie',
          requestId: 'r2',
          displayName: '이벤트 이름',
          revision: 3,
        ),
      );
      await pumpConsentUi(tester);
      expect(find.text('이벤트 이름 님이 내 위치를 따라가려 합니다'), findsOneWidget);
      await _tap(tester, '미동의');
      expect(f.services.api.followResponses, [('r2', false)]);
      expect(f.services.rooms.followRequests, isEmpty);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('C5 pending 응답은 지도를 열지 않고 요청 ID가 맞는 수락만 적용한다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      f.services.api.followAccepted = false;
      await _member(tester, 'alice');
      await _tap(tester, '동의');
      expect(f.services.rooms.pendingFollow, 'alice');
      expect(find.byType(RoomMap), findsNothing);
      expect(find.text('따라가기 응답 대기 중'), findsOneWidget);
      f.services.api.events.add(
        const FollowResponse('alice', true, requestId: 'old', revision: 2),
      );
      await pumpConsentUi(tester);
      expect(find.byType(RoomMap), findsNothing);
      f.services.api.events.add(
        const FollowResponse(
          'alice',
          true,
          requestId: 'alice-request',
          revision: 3,
        ),
      );
      await pumpConsentUi(tester);
      expect(f.services.rooms.followTarget, 'alice');
      expect(find.byType(RoomMap), findsOneWidget);
      expect(f.services.locationShare.sharing, isTrue);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);
  testWidgets('입장은 지도 없는 통화 방, 내 카드는 무동작, 바는 음성·방 관리만 하단 8dp', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      expect(find.byType(RoomMap), findsNothing);
      expect(find.text('우나보'), findsNothing);
      expect(find.byType(UnavoWatermark), findsOneWidget);
      expect(find.byType(MemberAvatar), findsNWidgets(2));
      final bar = find.byKey(const ValueKey('room-controls'));
      final icons = tester
          .widgetList<FloatingBarButton>(
            find.descendant(of: bar, matching: find.byType(FloatingBarButton)),
          )
          .map((button) => button.icon);
      expect(icons, containsAll(['mic', 'exit', 'volume2']));
      expect(
        icons,
        isNot(
          contains(anyOf('focus', 'navigation', 'locationoff', 'location')),
        ),
      );
      expect(tester.getRect(bar).bottom, 907);
      await _member(tester, 'bob');
      expect(find.byType(Dialog), findsNothing);
      expect(f.services.locationSource.requests, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('다른 카드 동의는 start 후 follow POST, 중지 모달은 지도만 닫고 공유 유지', (
    tester,
  ) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      expect(find.text('앨리스 님의 위치를 따라갑니다'), findsOneWidget);
      expect(find.text('내 위치도 같은 방 참여자에게 보입니다'), findsOneWidget);
      expect(find.text('화면이 꺼져 있어도 공유 중에는 위치를 보냅니다'), findsOneWidget);
      expect(find.text('동의하지 않아도 통화는 계속됩니다'), findsOneWidget);
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
      await _tap(tester, '동의');
      expect(f.services.locationShare.sharing, isTrue);
      expect(f.services.locationSource.watches, 1);
      expect(f.services.api.follows, ['alice']);
      expect(hasLocationConsent(f.services.store.preferences), isTrue);
      final consentRequests = f.services.api.http.requests;
      expect(consentRequests, hasLength(1));
      expect(consentRequests.single.method, 'PUT');
      expect(consentRequests.single.uri.path, '/v1/me/consent');
      expect(jsonDecode(utf8.decode(consentRequests.single.body)), {
        'location': {'version': '3'},
      });
      expect(f.services.rooms.followTarget, 'alice');
      expect(find.byType(RoomMap), findsOneWidget);
      await _member(tester, 'alice');
      expect(find.text('따라가기 중지'), findsOneWidget);
      expect(find.text('동의하지 않아도 통화는 계속됩니다'), findsNothing);
      await _tap(tester, '미동의');
      expect(f.services.rooms.followTarget, 'alice');
      await _member(tester, 'alice');
      await _tap(tester, '동의');
      expect(f.services.rooms.followTarget, isNull);
      expect(f.services.locationShare.sharing, isTrue);
      expect(f.services.api.unfollows, 1);
      expect(find.byType(RoomMap), findsNothing);
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      await _tap(tester, '동의');
      expect(f.services.locationSource.watches, 1);
      await _tap(tester, '위치 공유 중지');
      expect(find.text('내 위치 공유를 중지합니다'), findsOneWidget);
      await _tap(tester, '동의');
      expect(f.services.rooms.followTarget, isNull);
      expect(f.services.locationShare.sharing, isFalse);
      expect(f.services.api.stops, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('미동의 안내 후에는 GPS 요청·follow·지도가 없다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      await _tap(tester, '미동의');
      expect(find.text('동의하지 않아 따라가기 기능을 사용할 수 없습니다'), findsOneWidget);
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
      expect(find.byType(RoomMap), findsNothing);
      await _tap(tester, '닫기');
      expect(find.byType(Dialog), findsNothing);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  for (final permission in [
    LocationPermissionState.denied,
    LocationPermissionState.serviceOff,
  ]) {
    testWidgets('위치 시작 실패 $permission이면 follow를 보내지 않는다', (tester) async {
      final f = await _Fixture.create(tester);
      try {
        f.services.locationSource.permission = permission;
        await _member(tester, 'alice');
        await _tap(tester, '동의');
        expect(f.services.locationShare.sharing, isFalse);
        expect(f.services.api.follows, isEmpty);
        expect(find.byType(RoomMap), findsNothing);
        expect(
          find.text(
            permission == LocationPermissionState.denied
                ? '위치 권한이 없습니다'
                : '위치 서비스가 꺼져 있습니다',
          ),
          findsOneWidget,
        );
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  for (final accepted in [true, false]) {
    testWidgets('follow-request 수신 → ${accepted ? "수락" : "거절"} 응답', (
      tester,
    ) async {
      final f = await _Fixture.create(tester, handle: 'alice');
      try {
        f.services.api.events.add(
          const FollowRequest(
            'bob',
            requestId: 'bob-request',
            displayName: '보비',
            revision: 2,
          ),
        );
        await pumpConsentUi(tester);
        expect(find.text('따라가기 요청'), findsOneWidget);
        expect(find.text('보비 님이 내 위치를 따라가려 합니다'), findsOneWidget);
        expect(find.text('화면이 꺼져 있어도 공유 중에는 위치를 보냅니다'), findsOneWidget);
        expect(find.text('동의하지 않아도 통화는 계속됩니다'), findsOneWidget);
        await _tap(tester, accepted ? '동의' : '미동의');
        expect(f.services.api.followResponses, [('bob-request', accepted)]);
        expect(f.services.locationSource.watches, accepted ? 1 : 0);
        if (accepted) {
          final consentRequests = f.services.api.http.requests;
          expect(consentRequests, hasLength(1));
          expect(consentRequests.single.method, 'PUT');
          expect(consentRequests.single.uri.path, '/v1/me/consent');
          expect(jsonDecode(utf8.decode(consentRequests.single.body)), {
            'location': {'version': '3'},
          });
        } else {
          expect(f.services.api.http.requests, isEmpty);
        }
        expect(find.byType(RoomMap), findsNothing);
        if (accepted) {
          f.services.api.events.add(
            const FollowRequest(
              'bob',
              requestId: 'bob-request',
              displayName: '보비',
              revision: 2,
            ),
          );
          await pumpConsentUi(tester);
          expect(find.byType(Dialog), findsNothing);
          expect(f.services.api.followResponses, [
            ('bob-request', true),
            ('bob-request', true),
          ]);
          expect(f.services.locationSource.watches, 1);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  testWidgets('상대 거절은 안내하고 따라가기·지도를 닫는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      await _tap(tester, '동의');
      f.services.api.events.add(
        const FollowResponse('alice', false, requestId: 'alice-request'),
      );
      await pumpConsentUi(tester);
      expect(find.text('앨리스 님이 위치 공유에 동의하지 않았습니다'), findsOneWidget);
      expect(f.services.rooms.followTarget, isNull);
      expect(find.byType(RoomMap), findsNothing);
      expect(f.services.locationShare.sharing, isTrue);
      await _tap(tester, '닫기');
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('동의 중 방 변경·요청 취소는 이전 동의로 위치를 켜지 않는다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await _member(tester, 'alice');
      f.services.rooms.state = const RoomState(code: 'OTHER1');
      await _tap(tester, '동의');
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
    } finally {
      await f.dispose(tester);
    }
    final target = await _Fixture.create(tester, handle: 'alice');
    try {
      target.services.api.events.add(
        const FollowRequest(
          'bob',
          requestId: 'bob-request',
          displayName: '보비',
          revision: 2,
        ),
      );
      await pumpConsentUi(tester);
      target.services.api.events.add(
        const FollowCancelled('bob', requestId: 'bob-request'),
      );
      await pumpConsentUi(tester);
      await _tap(tester, '동의');
      expect(target.services.locationSource.requests, 0);
      expect(target.services.api.followResponses, isEmpty);
    } finally {
      await target.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('차량은 표본 없는 unknown에서 모달을 열고 동의 후 start·follow POST·지도를 표시한다', (
    tester,
  ) async {
    final f = await _Fixture.create(tester, car: true);
    try {
      expect(f.services.locationShare.motionState, LocationMotionState.unknown);
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      expect(find.text('정차 후 설정할 수 있습니다'), findsNothing);
      expect(f.services.locationSource.requests, 0);
      expect(f.services.api.follows, isEmpty);
      await _tap(tester, '동의');
      expect(f.services.locationShare.sharing, isTrue);
      expect(f.services.locationSource.requests, 1);
      expect(f.services.locationSource.watches, 1);
      expect(f.services.api.follows, ['alice']);
      expect(f.services.rooms.followTarget, 'alice');
      expect(find.byType(RoomMap), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('차량의 moving 표본은 동의 팝업 전에 정차 오류로 차단한다', (tester) async {
    final f = await _Fixture.create(tester, car: true);
    try {
      await completeConsentFuture(
        tester,
        f.services.locationShare.start(token: Object(), stillValid: () => true),
      );
      await _sample(tester, f, speed: .5);
      expect(f.services.locationShare.motionState, LocationMotionState.moving);
      await _member(tester, 'alice');
      expect(find.text('정차 후 설정할 수 있습니다'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(f.services.locationSource.requests, 1);
      expect(f.services.api.follows, isEmpty);
      expect(f.services.rooms.followTarget, isNull);
      expect(find.byType(RoomMap), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('차량은 stationary에서 모달·따라가기를 허용하고 이후 이동에도 유지한다', (tester) async {
    final f = await _Fixture.create(tester, car: true);
    try {
      await completeConsentFuture(
        tester,
        f.services.locationShare.start(token: Object(), stillValid: () => true),
      );
      for (var second = 0; second <= 3; second++) {
        if (second > 0) await tester.pump(const Duration(seconds: 1));
        await _sample(tester, f, speed: 0);
      }
      expect(
        f.services.locationShare.motionState,
        LocationMotionState.stationary,
      );
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      await _tap(tester, '동의');
      expect(f.services.api.follows, ['alice']);
      expect(f.services.rooms.followTarget, 'alice');
      expect(f.services.locationSource.watches, 1);
      await _sample(tester, f, speed: 3);
      expect(f.services.rooms.followTarget, 'alice');
      expect(find.byType(RoomMap), findsOneWidget);
      expect(find.text('정차 후 설정할 수 있습니다'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  for (final immediate in [true, false]) {
    testWidgets(
      '차량 동의 후 ${immediate ? "start 중" : "POST 뒤"} 첫 moving 판정은 따라가기만 거부한다',
      (tester) async {
        final f = await _Fixture.create(tester, car: true);
        try {
          if (immediate) {
            f.services.locationSource.initialSample = LocationSample(
              lat: 37,
              lng: 127,
              speed: .5,
              at: tester.binding.clock.now(),
            );
          }
          await _member(tester, 'alice');
          expect(find.text('따라가기'), findsOneWidget);
          expect(f.services.locationSource.requests, 0);
          await _tap(tester, '동의');
          if (!immediate) {
            expect(f.services.rooms.followTarget, 'alice');
            await _sample(tester, f, speed: .5);
          }
          expect(f.services.rooms.followTarget, isNull);
          expect(f.services.rooms.followError, '정차 후 설정할 수 있습니다');
          expect(find.text('정차 후 설정할 수 있습니다'), findsOneWidget);
          expect(find.byType(RoomMap), findsNothing);
          expect(f.services.api.follows, immediate ? isEmpty : ['alice']);
          expect(f.services.api.unfollows, immediate ? 0 : 1);
          expect(f.services.locationShare.sharing, isTrue);
          expect(f.services.locationSource.watches, 1);
          expect(f.services.locationSource.cancellations, 0);
          expect(f.services.api.stops, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await f.dispose(tester);
        }
      },
      timeout: _timeout,
    );
  }

  testWidgets('폰은 이동 중에도 모달·동의·따라가기를 허용한다', (tester) async {
    final f = await _Fixture.create(tester);
    try {
      await completeConsentFuture(
        tester,
        f.services.locationShare.start(token: Object(), stillValid: () => true),
      );
      await _sample(tester, f, speed: 3);
      await _member(tester, 'alice');
      expect(find.text('따라가기'), findsOneWidget);
      await _tap(tester, '동의');
      expect(f.services.rooms.followTarget, 'alice');
      expect(f.services.api.follows, ['alice']);
      expect(find.byType(RoomMap), findsOneWidget);
      expect(find.text('정차 후 설정할 수 있습니다'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  for (final (car, size) in [
    (false, const Size(412, 915)),
    (false, const Size(915, 412)),
    (true, const Size(1320, 940)),
    (true, const Size(1706, 1206)),
  ]) {
    testWidgets('$car $size 지도:통화 7:3·워터마크 경계·원형 버튼·전체 화면·speaking', (
      tester,
    ) async {
      final f = await _Fixture.create(tester, car: car, size: size);
      try {
        _expectWatermarkBounds(tester);
        await completeConsentFuture(
          tester,
          f.services.locationShare.start(
            token: Object(),
            stillValid: () => true,
          ),
        );
        f.services.api.events.add(
          Hello(
            'bob',
            f.services.api.members,
            'alice',
            const [],
            const {},
            'alice',
          ),
        );
        await pumpConsentUi(tester);
        final map = find.byType(RoomMap);
        final panel = find.byKey(const ValueKey('room-call-panel'));
        final mapSize = tester.getSize(map), panelSize = tester.getSize(panel);
        if (car || size.width > size.height) {
          expect(mapSize.width / panelSize.width, closeTo(7 / 3, .001));
          expect(mapSize.height, panelSize.height);
        } else {
          expect(mapSize.height / panelSize.height, closeTo(7 / 3, .001));
          expect(mapSize.width, panelSize.width);
        }
        if (car) {
          final controls = find.byKey(const ValueKey('room-controls'));
          final buttons = find.descendant(
            of: controls,
            matching: find.byType(FloatingBarButton),
          );
          expect(buttons, findsNWidgets(4));
          expect(
            find.descendant(of: controls, matching: find.byType(Scrollable)),
            findsNothing,
          );
          final panelRect = tester.getRect(panel);
          final controlsRect = tester.getRect(controls);
          final tops = <double>[];
          for (var i = 0; i < 4; i++) {
            final rect = tester.getRect(buttons.at(i));
            expect(rect.size, const Size(80, 80));
            expect(panelRect.contains(rect.topLeft), isTrue);
            expect(panelRect.contains(rect.bottomRight), isTrue);
            expect(controlsRect.contains(rect.topLeft), isTrue);
            expect(controlsRect.contains(rect.bottomRight), isTrue);
            tops.add(rect.top);
          }
          if (size.width == 1706) expect(tops.toSet(), hasLength(1));
          expect(find.byTooltip('방 나가기').hitTestable(), findsOneWidget);
        }
        _expectWatermarkBounds(tester);
        expect(
          find.descendant(of: map, matching: find.byType(UnavoWatermark)),
          findsNothing,
        );
        expect(find.byType(RoomMapButton), findsNWidgets(4));
        expect(
          tester.getSize(find.byTooltip('방향 정렬')),
          Size.square(car ? 64 : 44),
        );
        expect(
          tester
              .widget<RoomMapButton>(
                find.byWidgetPredicate(
                  (w) => w is RoomMapButton && w.icon == 'expand',
                ),
              )
              .translucent,
          isTrue,
        );
        final mapState = tester.state(find.byType(VworldRoomMap));
        await _tap(tester, '지도 전체 화면');
        expect(tester.state(find.byType(VworldRoomMap)), same(mapState));
        expect(panel, findsNothing);
        expect(find.byType(UnavoWatermark), findsNothing);
        expect(find.byType(RoomMapButton), findsNWidgets(4));
        expect(find.byTooltip('지도 축소'), findsOneWidget);
        expect(find.byKey(const ValueKey('room-controls')), findsOneWidget);
        final expanded = tester.getSize(map);
        expect(
          expanded.width,
          closeTo(
            mapSize.width +
                (car || size.width > size.height ? panelSize.width : 0),
            .001,
          ),
        );
        expect(
          expanded.height,
          closeTo(
            mapSize.height +
                (!car && size.width < size.height ? panelSize.height : 0),
            .001,
          ),
        );
        final speaker = find.byKey(const ValueKey('speaker-alice'));
        expect(tester.getSize(speaker), Size.square(car ? 56 : 40));
        f.services.media.remoteSpeaking?.call('alice', true);
        await pumpConsentUi(tester);
        expect(tester.widget<MemberAvatar>(speaker).speaking, isTrue);
        final glow =
            tester
                    .widget<Container>(
                      find
                          .descendant(
                            of: speaker,
                            matching: find.byType(Container),
                          )
                          .first,
                    )
                    .decoration!
                as BoxDecoration;
        expect((glow.border! as Border).top.width, 3);
        expect((glow.border! as Border).top.color, const Color(0xFFFF4D4D));
        expect(
          glow.boxShadow!.single.color,
          UnavoColors.speaking.withValues(alpha: .65),
        );
        expect(glow.boxShadow, isNotEmpty);
        await _tap(tester, '지도 축소');
        expect(panel, findsOneWidget);
        _expectWatermarkBounds(tester);
        expect(f.services.rooms.followTarget, 'alice');
        expect(tester.takeException(), isNull);
      } finally {
        await f.dispose(tester);
      }
    }, timeout: _timeout);
  }

  testWidgets('전체 화면도 SafeArea·통화를 유지하고 인디케이터는 최대 6명·내 발화를 따른다', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.resetPadding);
    final f = await _Fixture.create(tester);
    try {
      await completeConsentFuture(
        tester,
        f.services.locationShare.start(token: Object(), stillValid: () => true),
      );
      f.services.calls.state = const CallState(
        roomCode: 'ABC123',
        selfHandle: 'bob',
        isActive: true,
      );
      final members = [
        const Member('bob', '보비', '1'),
        const Member('alice', '앨리스', '2'),
        for (var index = 0; index < 6; index++)
          Member('user$index', '참여자$index', '$index'),
      ];
      f.services.api.events.add(
        Hello(
          'bob',
          members,
          'alice',
          const [],
          const {},
          'alice',
          const [],
          2,
          null,
          'alice-request',
        ),
      );
      await pumpConsentUi(tester);
      await _tap(tester, '지도 전체 화면');
      expect(
        tester.getRect(find.byType(RoomMap)),
        const Rect.fromLTRB(0, 24, 412, 881),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('room-controls'))).bottom,
        873,
      );
      expect(find.byType(MemberAvatar), findsNWidgets(6));
      expect(f.services.rooms.call.isActive, isTrue);
      f.services.media.localSpeaking?.call(true);
      await pumpConsentUi(tester);
      expect(
        tester
            .widget<MemberAvatar>(find.byKey(const ValueKey('speaker-bob')))
            .speaking,
        isTrue,
      );
      f.services.media.localSpeaking?.call(false);
      await pumpConsentUi(tester);
      expect(
        tester
            .widget<MemberAvatar>(find.byKey(const ValueKey('speaker-bob')))
            .speaking,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);

  testWidgets('테마·지도·워터마크는 플랫폼 밝기를 따르고 패널 대비를 유지한다', (tester) async {
    final f = await _Fixture.create(tester);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    try {
      await _member(tester, 'alice');
      await _tap(tester, '동의');
      expect(f.appearance.themeMode, ThemeMode.system);
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await pumpConsentUi(tester);
        expect(
          tester.widget<RoomMap>(find.byType(RoomMap)).brightness,
          brightness,
        );
        expect(
          Theme.of(tester.element(find.byType(RoomMap))).brightness,
          brightness,
        );
        final panel = find.byKey(const ValueKey('room-call-panel'));
        final background = tester.widget<Container>(panel).color!;
        // 통화 패널은 라이트 테마에서도 불투명한 ink를 사용한다.
        expect(background, UnavoColors.ink);
        final watermark = find.descendant(
          of: panel,
          matching: find.byType(UnavoWatermark),
        );
        expect(watermark, findsOneWidget);
        final opacity = tester
            .widget<Opacity>(
              find.descendant(of: watermark, matching: find.byType(Opacity)),
            )
            .opacity;
        final dark = brightness == Brightness.dark;
        expect(opacity, dark ? .16 : .18);
        _expectWatermarkBounds(tester);
        expect(
          tester
              .widget<IgnorePointer>(
                find.descendant(
                  of: watermark,
                  matching: find.byType(IgnorePointer),
                ),
              )
              .ignoring,
          isTrue,
        );
        final unavoStyle = tester
            .widget<Text>(
              find.descendant(of: watermark, matching: find.text('UNAVO')),
            )
            .style!;
        for (final label in ['Una Vox', 'UNAVO']) {
          final style = tester
              .widget<Text>(
                find.descendant(of: watermark, matching: find.text(label)),
              )
              .style!;
          expect(style.color, dark ? UnavoColors.text : UnavoColors.gold);
          expect(style.fontFamily, 'Rye');
          expect(
            style.fontSize,
            label == 'Una Vox' ? unavoStyle.fontSize! / 2 : unavoStyle.fontSize,
          );
          expect(style.height, 1);
          final rendered = Color.alphaBlend(
            style.color!.withValues(alpha: opacity),
            background,
          );
          final backgroundLuminance = background.computeLuminance();
          // 합성 후 휘도의 패널 대비 상대 차이가 25% 이상이어야 한다.
          expect(
            (rendered.computeLuminance() - backgroundLuminance) /
                backgroundLuminance,
            greaterThanOrEqualTo(.25),
          );
        }
        expect(find.byTooltip('낮 테마 보기'), findsNothing);
        expect(find.byTooltip('밤 테마 보기'), findsNothing);
      }
    } finally {
      await f.dispose(tester);
    }
  }, timeout: _timeout);
}

void _expectWatermarkBounds(WidgetTester tester) {
  const epsilon = .01;
  final panel = find.byKey(const ValueKey('room-call-panel'));
  final watermark = find.descendant(
    of: panel,
    matching: find.byType(UnavoWatermark),
  );
  expect(watermark, findsOneWidget);
  final fitted = find.descendant(
    of: watermark,
    matching: find.byType(FittedBox),
  );
  expect(tester.widget<FittedBox>(fitted).fit, BoxFit.scaleDown);
  final panelRect = tester.getRect(panel);
  final maxWidth = panelRect.width * .8;
  final maxHeight = panelRect.height * .4;
  // getRect는 FittedBox의 배율까지 적용한 전역 좌표로 두 줄을 측정한다.
  final topLine = tester.getRect(
    find.descendant(of: watermark, matching: find.text('Una Vox')),
  );
  final bottomLine = tester.getRect(
    find.descendant(of: watermark, matching: find.text('UNAVO')),
  );
  final wordmark = topLine.expandToInclude(bottomLine);
  expect(wordmark.width, greaterThan(0));
  expect(wordmark.height, greaterThan(0));
  expect(wordmark.width, lessThanOrEqualTo(maxWidth + epsilon));
  expect(wordmark.height, lessThanOrEqualTo(maxHeight + epsilon));
  // 고정 40/80 크기에 머무르지 않고 폭 또는 높이 한계까지 채워야 한다.
  expect(
    (wordmark.width - maxWidth).abs() < epsilon ||
        (wordmark.height - maxHeight).abs() < epsilon,
    isTrue,
  );
  expect(wordmark.center.dx, closeTo(panelRect.center.dx, epsilon));
  expect(wordmark.center.dy, closeTo(panelRect.center.dy, epsilon));
  expect(topLine.bottom, closeTo(bottomLine.top, epsilon));
}

Future<void> _tap(WidgetTester tester, String label) async {
  final target = find.byTooltip(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await pumpConsentUi(tester);
}

Future<void> _member(WidgetTester tester, String handle) async {
  final card = find.byKey(ValueKey('member-$handle'));
  await tester.ensureVisible(card);
  await tester.tap(card);
  await pumpConsentUi(tester);
}

Future<void> _sample(
  WidgetTester tester,
  _Fixture fixture, {
  required double speed,
}) async {
  fixture.services.locationSource.add(
    LocationSample(
      lat: 37,
      lng: 127,
      speed: speed,
      at: tester.binding.clock.now(),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class _Fixture {
  _Fixture(this.services);
  final ConsentTestServices services;
  final appearance = AppearanceController();
  static Future<_Fixture> create(
    WidgetTester tester, {
    bool car = false,
    String handle = 'bob',
    Size? size,
  }) async {
    tester.view.physicalSize =
        size ?? (car ? const Size(1320, 940) : const Size(412, 915));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final mode = car ? DeviceMode.car : DeviceMode.phone;
    final services = await ConsentTestServices.create(
      tester,
      mode: mode,
      handle: handle,
    );
    await services.openRoom(tester);
    final f = _Fixture(services);
    await tester.pumpWidget(
      UnavoAppearance(
        controller: f.appearance,
        child: MaterialApp(
          builder: testIconBuilder,
          theme: unavoTheme(Brightness.light),
          darkTheme: unavoTheme(Brightness.dark),
          themeMode: f.appearance.themeMode,
          home: RoomScreen(services: services, mode: mode),
        ),
      ),
    );
    await pumpConsentUi(tester);
    return f;
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await services.finish(tester);
    appearance.dispose();
  }
}
