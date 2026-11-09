import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/call/mesh_coordinator.dart';

void main() {
  for (final size in [2, 3, 4]) {
    for (final reversed in [false, true]) {
      test('$size명 ${reversed ? "역순" : "정순"} 입장·이탈 시 풀 메시와 오퍼 소유권', () async {
        final net = _Network();
        final names = ['alice', 'bob', 'charlie', 'david'].take(size).toList();
        final order = reversed ? names.reversed.toList() : names;
        final members = <String>[];
        for (final handle in order) {
          final before = net.sent.length;
          members.add(handle);
          for (final node in net.nodes.values) {
            await node.updateMembers(members);
          }
          await net.add(handle).join(members);
          await net.flush();
          final offers = net.sent.skip(before).where((m) => m.kind == 'offer');
          expect(offers.length, members.length - 1);
          expect(offers.every((m) => m.from == handle), isTrue);
          net.expectMesh(members);
        }
        for (final handle in order.reversed) {
          final leaving = net.nodes.remove(handle)!;
          await leaving.close();
          members.remove(handle);
          for (final node in net.nodes.values) {
            await node.updateMembers(members);
          }
          await net.flush();
          net.expectMesh(members);
          expect(net.created[handle]!.every((peer) => peer.closed), isTrue);
        }
        expect(net.errors, isEmpty);
        expect(
          net.created.values.expand((p) => p).every((p) => p.closeCount == 1),
          isTrue,
        );
      });
    }
  }

  test('동시 입장 glare: 작은 handle의 오퍼만 남기고 큰 쪽은 피어를 교체한다', () async {
    final net = _Network();
    final alice = net.add('alice');
    final bob = net.add('bob');
    await Future.wait([
      alice.join(['alice', 'bob']),
      bob.join(['alice', 'bob']),
    ]);
    await net.flush();
    net.expectMesh(['alice', 'bob']);
    expect(net.created['alice']!.length, 1);
    expect(net.created['bob']!.length, 2);
    expect(net.created['bob']!.first.closed, isTrue);
    final answers = net.sent.where((m) => m.kind == 'answer');
    expect(answers, isNotEmpty);
    expect(
      answers.every(
        (m) =>
            m.from == 'bob' &&
            (m.data['negotiationId'] as String).startsWith('alice:'),
      ),
      isTrue,
    );
    expect(net.errors, isEmpty);
    await net.close();
  });

  test('hello의 5번째 참여자는 피어 생성 전에 거부하고 기존 4명은 유지한다', () async {
    final net = _Network();
    final members = ['david', 'charlie', 'bob', 'alice', 'aaron'];
    final fifth = net.add('aaron');
    expect(() => fifth.join(members), throwsStateError);
    expect(net.created['aaron'], isEmpty);
    expect(MeshCoordinator.canJoin('aaron', members), isFalse);
    expect(MeshCoordinator.canJoin('alice', members), isTrue);
    final first = net.add('david');
    await first.join(members);
    await first.onSignal('aaron', 'offer', {
      'sdp': 'excluded',
      'type': 'offer',
      'negotiationId': 'aaron:test:1',
    });
    expect(first.peers, {'charlie', 'bob', 'alice'});
    await first.updateMembers(members.skip(1));
    expect(first.peers, isEmpty); // self is no longer a room member.
    expect(MeshCoordinator.canJoin('aaron', members.skip(1)), isTrue);
    await net.close();
  });

  for (final returning in ['alice', 'zebra']) {
    test('SSE 복귀 $returning: 유실된 신규 멤버 offer를 reconcile·glare로 복구한다', () async {
      final net = _Network();
      final incumbent = net.add(returning);
      await incumbent.join([returning]);
      await incumbent.updateMembers([returning, 'bob']);
      final newcomer = net.add('bob');
      await newcomer.join([returning, 'bob']);
      await newcomer.idle;
      net.pending.clear(); // The incumbent's SSE is down; the offer is lost.
      await incumbent.reconcile([returning, 'bob']);
      await net.flush();
      net.expectMesh([returning, 'bob']);
      final smaller = returning.compareTo('bob') < 0 ? returning : 'bob';
      final answer = net.sent.lastWhere((message) => message.kind == 'answer');
      expect(answer.data['negotiationId'], startsWith('$smaller:'));
      expect(net.created[smaller], hasLength(1));
      final sent = net.sent.length;
      await incumbent.reconcile([returning, 'bob']);
      await newcomer.reconcile([returning, 'bob']);
      await net.flush();
      expect(net.sent.length, sent); // Already connected: no re-offer.
      expect(net.errors, isEmpty);
      await net.close();
    });
  }

  test('reconcile은 진행 중 offer와 정원 밖 멤버에게 중복 제안하지 않는다', () async {
    final net = _Network();
    final alice = net.add('alice');
    final members = ['alice', 'bob', 'charlie', 'david', 'eve'];
    await alice.join(members);
    await net.flush();
    final offers = net.sent.where((message) => message.kind == 'offer').length;
    await alice.reconcile(members);
    await net.flush();
    expect(net.sent.where((message) => message.kind == 'offer').length, offers);
    expect(alice.peers, {'bob', 'charlie', 'david'});
    await net.close();
  });

  test('ICE가 SDP보다 먼저 오면 remote description 뒤에 적용한다', () async {
    final net = _Network();
    final alice = net.add('alice');
    await alice.join(['alice']);
    await alice.updateMembers(['alice', 'bob']);
    const id = 'bob:session:1';
    await alice.onSignal('bob', 'ice', {
      'candidate': 'early',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
      'negotiationId': id,
    });
    expect(alice.peers, isEmpty);
    await alice.onSignal('bob', 'offer', {
      'sdp': 'remote-offer',
      'type': 'offer',
      'negotiationId': id,
    });
    expect(net.created['alice']!.single.ice.map((ice) => ice['candidate']), [
      'early',
    ]);
    expect(net.errors, isEmpty);
    await net.close();
  });

  test('첫 오퍼를 놓친 참여자의 늦은 통화 참여는 오퍼와 ICE 재전송으로 연결한다', () async {
    final net = _Network();
    await net.add('alice').join(['alice', 'bob']);
    await net.flush(); // bob has no SSE/media yet, so these signals are lost.
    await net.add('bob').join(['alice', 'bob']);
    await net.flush();
    net.expectMesh(['alice', 'bob']);
    expect(net.created['bob']!.last.ice, isNotEmpty);
    expect(net.errors, isEmpty);
    await net.close();
  });

  test('통화 끊기만 해도 원격 피어를 닫고 같은 방에서 재참여할 수 있다', () async {
    final net = _Network();
    await net.add('alice').join(['alice']);
    await net.nodes['alice']!.updateMembers(['alice', 'bob']);
    await net.add('bob').join(['alice', 'bob']);
    await net.flush();
    final oldOffer = net.sent.firstWhere(
      (m) => m.from == 'bob' && m.kind == 'offer',
    );
    await net.nodes.remove('bob')!.close();
    await net.flush();
    expect(net.nodes['alice']!.peers, isEmpty);
    await net.add('bob').join(['alice', 'bob']);
    await net.flush();
    await net.nodes['alice']!.onSignal('bob', 'custom', {
      'type': 'mesh-left',
      'negotiationId': oldOffer.data['negotiationId'],
    });
    net.expectMesh(['alice', 'bob']);
    expect(net.errors, isEmpty);
    await net.close();
  });

  test('TURN 갱신 ICE restart는 작은 handle만 오퍼를 보내고 피어를 재사용한다', () async {
    final net = _Network();
    await net.add('alice').join(['alice']);
    await net.nodes['alice']!.updateMembers(['alice', 'bob']);
    await net.add('bob').join(['alice', 'bob']);
    await net.flush();
    final before = net.sent.length;
    await Future.wait(net.nodes.values.map((node) => node.restartIce()));
    await net.flush();
    final offers = net.sent
        .skip(before)
        .where((m) => m.kind == 'offer')
        .toList();
    expect(offers.length, 1);
    expect(offers.single.from, 'alice');
    expect(net.created.values.every((peers) => peers.length == 1), isTrue);
    expect(net.created['alice']!.single.restarts, 1);
    net.expectMesh(['alice', 'bob']);
    await net.close();
  });

  test('응답 없는 오퍼도 TURN 갱신 시 새 피어·협상 ID로 교체한다', () async {
    final net = _Network();
    final node = net.add('alice');
    await node.join(['alice', 'bob']);
    await net.flush();
    final oldId = net.sent
        .firstWhere((m) => m.kind == 'offer')
        .data['negotiationId'];
    await node.restartIce();
    await net.flush();
    expect(net.created['alice']!.length, 2);
    expect(net.created['alice']!.first.closed, isTrue);
    expect(
      net.sent.lastWhere((m) => m.kind == 'offer').data['negotiationId'],
      isNot(oldId),
    );
    await net.close();
  });

  test('한 피어의 close가 실패해도 나머지 피어를 모두 정리한다', () async {
    final net = _Network();
    final node = net.add('alice');
    await node.join(['alice', 'bob', 'charlie', 'david']);
    net.created['alice']!.first.failClose = true;
    await expectLater(node.close(), throwsStateError);
    expect(net.created['alice']!.every((peer) => peer.closed), isTrue);
    expect(node.peers, isEmpty);
  });

  test('피어 생성 중 leave는 늦게 생성된 피어도 닫고 오퍼를 보내지 않는다', () async {
    final factory = Completer<MeshPeer>();
    final entered = Completer<void>();
    final sent = <String>[];
    final peer = _FakePeer('bob', (_) {}, (_) {});
    final node = MeshCoordinator(
      selfHandle: 'alice',
      sessionId: 'cancelled',
      createPeer: (_, candidate, state) {
        entered.complete();
        return factory.future;
      },
      sendSignal: (_, kind, payload) async {
        sent.add(kind);
      },
    );
    final joining = node.join(['alice', 'bob']);
    await entered.future;
    final leaving = node.close();
    factory.complete(peer);
    await Future.wait([joining, leaving]);
    expect(peer.closeCount, 1);
    expect(node.peers, isEmpty);
    expect(sent, isEmpty);
  });
}

class _Message {
  _Message(this.from, this.to, this.kind, this.data);
  final String from;
  final String to;
  final String kind;
  final Map<String, Object?> data;
}

class _Network {
  final Map<String, MeshCoordinator> nodes = {};
  final Map<String, List<_FakePeer>> created = {};
  final List<_Message> sent = [];
  final List<_Message> pending = [];
  final List<Object> errors = [];
  int session = 0;

  MeshCoordinator add(String handle) {
    created.putIfAbsent(handle, () => []);
    return nodes[handle] = MeshCoordinator(
      selfHandle: handle,
      sessionId: '${++session}',
      createPeer: (remote, candidate, state) async {
        final peer = _FakePeer(remote, candidate, state);
        created[handle]!.add(peer);
        return peer;
      },
      sendSignal: (to, kind, data) async {
        final message = _Message(handle, to, kind, Map.of(data));
        sent.add(message);
        pending.add(message);
      },
      onError: errors.add,
    );
  }

  Future<void> flush() async {
    for (var count = 0; count < 500; count++) {
      for (final node in nodes.values) {
        await node.idle;
      }
      if (pending.isEmpty) return;
      final message = pending.removeAt(0);
      await nodes[message.to]?.onSignal(
        message.from,
        message.kind,
        message.data,
      );
    }
    fail('signaling did not settle');
  }

  void expectMesh(List<String> members) {
    for (final handle in members) {
      expect(
        nodes[handle]!.peers,
        members.where((other) => other != handle).toSet(),
      );
      final live = created[handle]!.where((peer) => !peer.closed);
      expect(live.length, members.length - 1);
      expect(live.every((peer) => peer.remoteDescription), isTrue);
    }
  }

  Future<void> close() async {
    await Future.wait(nodes.values.map((node) => node.close()));
  }
}

class _FakePeer implements MeshPeer {
  _FakePeer(this.handle, this.candidate, this.state);
  final String handle;
  final void Function(Map<String, Object?>) candidate;
  final void Function(MeshPeerState) state;
  bool closed = false;
  bool failClose = false;
  bool remoteDescription = false;
  int closeCount = 0;
  int restarts = 0;
  final List<Map<String, Object?>> ice = [];

  @override
  Future<Map<String, Object?>> createOffer({bool iceRestart = false}) async {
    expect(closed, isFalse);
    if (iceRestart) restarts++;
    candidate({
      'candidate': 'candidate-$handle',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
    return {'type': 'offer', 'sdp': 'offer-$handle'};
  }

  @override
  Future<Map<String, Object?>> answerOffer(Map<String, Object?> offer) async {
    expect(closed, isFalse);
    remoteDescription = true;
    candidate({
      'candidate': 'answer-candidate-$handle',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
    state(MeshPeerState.connected);
    return {'type': 'answer', 'sdp': 'answer-$handle'};
  }

  @override
  Future<void> acceptAnswer(Map<String, Object?> answer) async {
    expect(closed, isFalse);
    remoteDescription = true;
    state(MeshPeerState.connected);
  }

  @override
  Future<void> addCandidate(Map<String, Object?> candidate) async {
    expect(closed, isFalse);
    expect(remoteDescription, isTrue, reason: 'ICE must wait for remote SDP');
    ice.add(candidate);
  }

  @override
  Future<void> close() async {
    closeCount++;
    closed = true;
    if (failClose) throw StateError('native close failed');
  }
}
