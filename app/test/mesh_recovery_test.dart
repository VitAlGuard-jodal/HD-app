import 'dart:async';

// fake_async is already supplied by flutter_test.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/call/mesh_coordinator.dart';

void main() {
  test('실패한 피어만 2s·4s·8s ICE restart 후 실패, 정상 피어는 유지', () {
    fakeAsync((clock) {
      final f = _Fixture();
      _settle(clock, f.mesh.join(['alice', 'bob', 'charlie']));
      final bob = f.peers['bob']!;
      final charlie = f.peers['charlie']!;
      bob.state(MeshPeerState.connected);
      charlie.state(MeshPeerState.connected);
      for (var i = 0; i < 5; i++) {
        bob.state(MeshPeerState.failed);
      }
      expect(f.mesh.peerStates['bob'], MeshPeerState.connecting);
      expect(clock.nonPeriodicTimerCount, 1);
      clock.elapse(const Duration(milliseconds: 1999));
      expect(bob.restarts, 0);
      clock.elapse(const Duration(milliseconds: 1));
      expect(bob.restarts, 1);
      clock.elapse(const Duration(seconds: 4));
      expect(bob.restarts, 2);
      clock.elapse(const Duration(seconds: 8));
      expect(bob.restarts, 3);
      // No further native failed event: the final response deadline still ends.
      clock.elapse(meshRecoveryTimeout);
      expect(f.mesh.peerStates['bob'], MeshPeerState.failed);
      expect(f.mesh.peerStates['charlie'], MeshPeerState.connected);
      expect(charlie.restarts, 0);
      expect(charlie.offers, 1);
      expect(charlie.closes, 0);
      expect(identical(f.peers['bob'], bob), isTrue);
      expect(bob.closes, 0);
      expect(f.offerIds['bob']!.toSet(), hasLength(4));
      bob.state(MeshPeerState.failed);
      bob.state(MeshPeerState.connecting);
      clock.elapse(const Duration(minutes: 1));
      expect(bob.restarts, 3);
      expect(f.mesh.peerStates['bob'], MeshPeerState.failed);
      expect(clock.pendingTimers, isEmpty);
      _settle(clock, f.mesh.close());
    });
  });

  test('피어 복구 성공은 남은 재시도를 취소하고 다음 실패의 예산을 초기화한다', () {
    fakeAsync((clock) {
      final f = _Fixture();
      _settle(clock, f.mesh.join(['alice', 'bob']));
      final bob = f.peers['bob']!;
      bob.state(MeshPeerState.failed);
      clock.elapse(const Duration(seconds: 2));
      bob.state(MeshPeerState.connected);
      clock.elapse(const Duration(seconds: 30));
      expect(bob.restarts, 1);
      expect(clock.pendingTimers, isEmpty);
      bob.state(MeshPeerState.failed);
      clock.elapse(const Duration(seconds: 2));
      expect(bob.restarts, 2);
      _settle(clock, f.mesh.close());
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('멤버 이탈·전체 종료는 피어 타이머를 취소하고 늦은 상태를 무시한다', () {
    fakeAsync((clock) {
      final f = _Fixture();
      _settle(clock, f.mesh.join(['alice', 'bob', 'charlie']));
      final bob = f.peers['bob']!;
      final charlie = f.peers['charlie']!;
      bob.state(MeshPeerState.failed);
      charlie.state(MeshPeerState.failed);
      _settle(clock, f.mesh.updateMembers(['alice', 'charlie']));
      bob.state(MeshPeerState.failed);
      expect(f.mesh.peerStates.containsKey('bob'), isFalse);
      expect(clock.nonPeriodicTimerCount, 1);
      _settle(clock, f.mesh.close());
      charlie.state(MeshPeerState.failed);
      clock.elapse(const Duration(seconds: 30));
      expect(bob.restarts, 0);
      expect(charlie.restarts, 0);
      expect(bob.closes, 1);
      expect(charlie.closes, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('한 피어의 SDP 전송 오류도 다른 피어의 join·미디어를 실패시키지 않는다', () {
    fakeAsync((clock) {
      final f = _Fixture()..failSignalsTo = 'bob';
      _settle(clock, f.mesh.join(['alice', 'bob', 'charlie']));
      f.peers['charlie']!.state(MeshPeerState.connected);
      clock.elapse(const Duration(seconds: 14));
      expect(f.peers['bob']!.restarts, 3);
      expect(f.mesh.peerStates['bob'], MeshPeerState.failed);
      expect(f.mesh.peerStates['charlie'], MeshPeerState.connected);
      expect(f.peers['charlie']!.offers, 1);
      expect(f.errors, isEmpty);
      expect(clock.pendingTimers, isEmpty);
      _settle(clock, f.mesh.close());
    });
  });

  test('ICE 복구 중 glare로 피어가 교체돼도 3회 예산과 마지막 응답 기한을 보존한다', () {
    fakeAsync((clock) {
      final f = _Fixture(self: 'zebra');
      _settle(clock, f.mesh.join(['zebra', 'bob']));
      final first = f.peers['bob']!;
      first.state(MeshPeerState.failed);
      clock.elapse(const Duration(seconds: 2));
      expect(first.restarts, 1);
      _settle(
        clock,
        f.mesh.onSignal('bob', 'offer', {
          'type': 'offer',
          'sdp': 'remote-restart',
          'negotiationId': 'bob:recovery:1',
        }),
      );
      final replacement = f.peers['bob']!;
      expect(identical(first, replacement), isFalse);
      expect(first.closes, 1);
      clock.elapse(const Duration(seconds: 4));
      expect(replacement.restarts, 1);
      clock.elapse(const Duration(seconds: 8));
      expect(replacement.restarts, 2);
      clock.elapse(meshRecoveryTimeout);
      expect(f.mesh.peerStates['bob'], MeshPeerState.failed);
      expect(clock.pendingTimers, isEmpty);
      _settle(clock, f.mesh.close());
    });
  });
}

void _settle(FakeAsync clock, Future<void> operation) {
  var done = false;
  unawaited(operation.then((_) => done = true));
  clock.flushMicrotasks();
  expect(
    done,
    isTrue,
    reason: 'operation must complete without advancing time',
  );
}

class _Fixture {
  _Fixture({String self = 'alice'}) {
    mesh = MeshCoordinator(
      selfHandle: self,
      sessionId: 'recovery',
      createPeer: (handle, candidate, state) async =>
          peers[handle] = _Peer(state),
      sendSignal: (to, kind, data) async {
        if (kind != 'offer') return;
        offerIds
            .putIfAbsent(to, () => [])
            .add(data['negotiationId']! as String);
        if (to == failSignalsTo) throw StateError('peer signaling unavailable');
      },
      onError: errors.add,
    );
  }
  late final MeshCoordinator mesh;
  final peers = <String, _Peer>{};
  final offerIds = <String, List<String>>{};
  final errors = <Object>[];
  String? failSignalsTo;
}

class _Peer implements MeshPeer {
  _Peer(this.state);
  final void Function(MeshPeerState) state;
  int offers = 0, restarts = 0, closes = 0;
  @override
  Future<Map<String, Object?>> createOffer({bool iceRestart = false}) async {
    offers++;
    if (iceRestart) restarts++;
    return {'type': 'offer', 'sdp': 'offer-$offers'};
  }

  @override
  Future<Map<String, Object?>> answerOffer(Map<String, Object?> offer) async =>
      {'type': 'answer', 'sdp': 'answer'};
  @override
  Future<void> acceptAnswer(Map<String, Object?> answer) async {}
  @override
  Future<void> addCandidate(Map<String, Object?> candidate) async {}
  @override
  Future<void> close() async {
    closes++;
  }
}
