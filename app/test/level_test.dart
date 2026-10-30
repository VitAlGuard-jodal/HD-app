import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/audio/level.dart';

void main() {
  test('silenceHasZeroLevel', () {
    final dbfs = rmsToDbfs(0);
    expect(dbfs, double.negativeInfinity);
    expect(dbfsToLevel(dbfs), 0);
  });
  test('fullScaleHasZeroDbfsAndFullLevel', () {
    final dbfs = rmsToDbfs(32768);
    expect(dbfs, closeTo(0, .0001));
    expect(dbfsToLevel(dbfs), 1);
  });
  test('nearMinusSixtyDbfsHasAlmostZeroLevel', () {
    final dbfs = rmsToDbfs(33);
    expect(dbfs, closeTo(-60, .1));
    expect(dbfsToLevel(dbfs), closeTo(0, .02));
  });
  test('nearMinusThirtyDbfsHasHalfLevel', () {
    final dbfs = rmsToDbfs(1037);
    expect(dbfs, closeTo(-30, .1));
    expect(dbfsToLevel(dbfs), closeTo(.5, .02));
  });
}
