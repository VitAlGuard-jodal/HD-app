import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/call/webrtc_media_engine.dart';

void main() {
  group('offerConstraints', () {
    test('ICE 재시작을 요청하면 mandatory에 IceRestart를 포함한다', () {
      final constraints = offerConstraints(iceRestart: true);
      final mandatory = constraints['mandatory'] as Map<String, Object?>;

      expect(mandatory['IceRestart'], isTrue);
    });

    test('ICE 재시작을 요청하지 않으면 IceRestart 키를 생략한다', () {
      final constraints = offerConstraints(iceRestart: false);
      final mandatory = constraints['mandatory'] as Map<String, Object?>;

      expect(mandatory.containsKey('IceRestart'), isFalse);
    });

    for (final iceRestart in [true, false]) {
      test('iceRestart=$iceRestart: 네이티브 제약 구조와 오디오 수신 설정을 유지한다', () {
        final constraints = offerConstraints(iceRestart: iceRestart);
        final mandatory = constraints['mandatory'] as Map<String, Object?>;

        expect(mandatory['OfferToReceiveAudio'], isTrue);
        expect(mandatory['OfferToReceiveVideo'], isFalse);
        expect(constraints.containsKey('iceRestart'), isFalse);
        expect(constraints.containsKey('offerToReceiveAudio'), isFalse);
        expect(constraints.containsKey('offerToReceiveVideo'), isFalse);
        expect(constraints['optional'], isA<List>());
      });
    }
  });
}
