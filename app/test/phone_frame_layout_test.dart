import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/phone_frame_layout.dart';

void main() {
  const frames = [
    (
      name: 'canonical 412x915 safeTop24',
      width: 412.0,
      height: 915.0,
      safeTop: 24.0,
      offset: 1.0,
      headerBottom: 92.0,
      letteringTop: 104.302074,
      letteringBottom: 291.441630,
      panelTop: 305.0,
    ),
    (
      name: 'iPhone17 402x874 safeTop62',
      width: 402.0,
      height: 874.0,
      safeTop: 62.0,
      offset: 51.0,
      headerBottom: 130.0,
      letteringTop: 142.399111,
      letteringBottom: 324.996444,
      panelTop: 341.378142,
    ),
    (
      name: 'iPhone17e 390x844 safeTop59',
      width: 390.0,
      height: 844.0,
      safeTop: 59.0,
      offset: 53.0,
      headerBottom: 127.0,
      letteringTop: 139.715556,
      letteringBottom: 316.862222,
      panelTop: 333.410929,
    ),
    (
      name: 'iPhone12 390x844 safeTop47',
      width: 390.0,
      height: 844.0,
      safeTop: 47.0,
      offset: 41.0,
      headerBottom: 115.0,
      letteringTop: 127.715556,
      letteringBottom: 304.862222,
      panelTop: 321.410929,
    ),
  ];

  for (final frame in frames) {
    test('${frame.name} keeps both lettering gaps at least 12dp', () {
      final layout = calculatePhoneFrameLayout(
        width: frame.width,
        height: frame.height,
        safeTop: frame.safeTop,
      );
      expect(layout.headerTop, greaterThanOrEqualTo(frame.safeTop));
      expect(layout.headerBottom, frame.headerBottom);
      expect(layout.backdropOffset, frame.offset);
      expect(layout.letteringTop, closeTo(frame.letteringTop, .000001));
      expect(layout.letteringBottom, closeTo(frame.letteringBottom, .000001));
      expect(layout.panelTop, closeTo(frame.panelTop, .000001));
      expect(
        layout.letteringTop - layout.headerBottom,
        greaterThanOrEqualTo(12),
      );
      expect(
        layout.panelTop - layout.letteringBottom,
        greaterThanOrEqualTo(12),
      );
      // 하단 안전영역 34dp + 탐색 영역 96dp + 패널 패딩 32dp를 제해도
      // 스크롤 뷰포트가 양수여야 한다. 실제 RenderFlex 검증은 위젯/기기 몫이다.
      expect(frame.height - 34 - 96 - layout.panelTop - 32, greaterThan(0));
    });
  }
}
