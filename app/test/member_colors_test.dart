import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/member_colors.dart';

void main() {
  test('입장 순서 0~6은 지정 무지개 색이고 이후 7명마다 순환한다', () {
    const expected = [
      0xFFFF4D4D,
      0xFFFF9A3C,
      0xFFFFD93C,
      0xFF4CD964,
      0xFF3C8CFF,
      0xFF4B5BD6,
      0xFFB36BFF,
    ];
    for (var order = 0; order < 70; order++) {
      expect(rainbowColor(order), Color(expected[order % 7]));
    }
    expect(rainbowColor(-1), const Color(0xFFB36BFF));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
