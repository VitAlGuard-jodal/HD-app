import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/audio/mic_ranker.dart';

void main() {
  test('carChoosesBuiltInMicFromSevenPleosInputs', () {
    const inputs = [
      MicDevice(1, 15, 'Built-In Mic'),
      MicDevice(2, 15, 'Built-In Back Mic'),
      MicDevice(3, 25, 'Remote Submix In'),
      MicDevice(4, 16, 'FM Tuner'),
      MicDevice(5, 21, 'Tone Generator 0'),
      MicDevice(6, 21, 'Tone Generator 1'),
      MicDevice(7, 28, 'Echo-Reference Mic'),
    ];
    final ranked = MicRanker.rank(MicMode.car, inputs);
    expect(ranked.first.name, 'Built-In Mic');
    expect(ranked.map((e) => e.id), [1, 2]);
    expect(ranked.any((e) => {28, 16, 25, 18, 21}.contains(e.type)), isFalse);
  });
  test('phonePrefersBluetoothScoOverBuiltInMic', () {
    final ranked = MicRanker.rank(MicMode.phone, const [
      MicDevice(1, 15, 'Built-In Mic'),
      MicDevice(2, 7, 'Bluetooth SCO'),
    ]);
    expect(ranked.first.type, 7);
  });
  test('carFallsBackToUsbHeadsetWithoutBuiltInMic', () {
    expect(
      MicRanker.rank(MicMode.car, const [
        MicDevice(3, 22, 'USB Headset'),
      ]).first.type,
      22,
    );
  });
  test('exclusionsApplyInBothModesAndNoCandidateIsAllowed', () {
    final inputs = [
      28,
      16,
      25,
      18,
      21,
    ].map((type) => MicDevice(type, type, '제외 장치')).toList();
    for (final mode in MicMode.values) {
      expect(MicRanker.rank(mode, inputs), isEmpty);
    }
  });
  test('carKeepsBuiltInAheadOfHeadsetsAndOtherInputs', () {
    const inputs = [
      MicDevice(1, 11, 'USB Device'),
      MicDevice(2, 3, 'Wired Headset'),
      MicDevice(3, 15, 'Built-In Mic'),
    ];
    expect(MicRanker.rank(MicMode.car, inputs).map((e) => e.id), [3, 2, 1]);
    expect(MicRanker.rank(MicMode.phone, inputs).map((e) => e.id), [2, 3, 1]);
    expect(inputs.map((e) => e.id), [1, 2, 3]);
  });
}
