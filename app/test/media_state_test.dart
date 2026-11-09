import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/call/media_engine.dart';
import 'package:unavo/call/mesh_coordinator.dart';

void main() {
  test('수신 가능한 피어 1명 또는 혼자 대기면 정상, 로컬 실패는 우선한다', () {
    expect(
      receiveConnectionState(MediaConnectionState.connected, []),
      MediaConnectionState.connected,
    );
    for (final other in MeshPeerState.values) {
      expect(
        receiveConnectionState(MediaConnectionState.connected, [
          MeshPeerState.connected,
          other,
        ]),
        MediaConnectionState.connected,
      );
    }
    expect(
      receiveConnectionState(MediaConnectionState.connected, [
        MeshPeerState.connecting,
        MeshPeerState.failed,
      ]),
      MediaConnectionState.connecting,
    );
    // Mesh failed is terminal: all peer recovery attempts have been exhausted.
    expect(
      receiveConnectionState(MediaConnectionState.connected, [
        MeshPeerState.failed,
      ]),
      MediaConnectionState.failed,
    );
    expect(
      receiveConnectionState(MediaConnectionState.connected, [
        MeshPeerState.failed,
        MeshPeerState.failed,
      ]),
      MediaConnectionState.failed,
    );
    for (final local in [
      MediaConnectionState.idle,
      MediaConnectionState.connecting,
      MediaConnectionState.failed,
    ]) {
      expect(receiveConnectionState(local, [MeshPeerState.connected]), local);
    }
  });

  test('피어 상태 스트림은 불변 스냅샷을 전달하고 종료할 수 있다', () async {
    final engine = _Engine();
    final received = <Map<String, MeshPeerState>>[];
    final subscription = engine.peerStateChanges.listen(received.add);
    final states = {'bob': MeshPeerState.connecting};
    engine.emit(states);
    states['bob'] = MeshPeerState.connected;
    engine.emit(states);
    await Future<void>.delayed(Duration.zero);
    expect(received.first['bob'], MeshPeerState.connecting);
    expect(engine.peerStates['bob'], MeshPeerState.connected);
    expect(() => received.first.clear(), throwsUnsupportedError);
    engine.emit({});
    expect(engine.peerStates, isEmpty);
    await subscription.cancel();
    await engine.dispose();
  });
}

class _Engine extends NoopMediaEngine {
  void emit(Map<String, MeshPeerState> states) => publishPeerStates(states);
}
