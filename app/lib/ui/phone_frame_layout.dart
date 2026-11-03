import 'dart:math' as math;

bool isNarrowPhone(double width, double height) =>
    width <= 380 || height <= 820;

// 1080×2400 배경를 중앙 정렬 cover로 그렸을 때의 폰 레터링 경계.
// 원본 y=232는 Una Vox의 보이는 획보다 위로 잡은 경계다.
// 밑변은 기존처럼 획뿐 아니라 UNAVO의 SVG 경계(y=1108)까지 보호한다.
({double top, double bottom}) phoneLetteringBounds({
  required double width,
  required double height,
  double verticalOffset = 0,
}) {
  final scale = math.max(width / 1080, height / 2400);
  final cropTop = (height - 2400 * scale) / 2;
  final narrow = isNarrowPhone(width, height);
  final translation = narrow ? 228.0 : 141.6;
  final letteringScale = narrow ? .49 : .56;
  double y(double sourceY) =>
      cropTop +
      (translation + letteringScale * sourceY) * scale +
      verticalOffset;
  return (top: y(232), bottom: y(1108));
}

class PhoneFrameLayout {
  const PhoneFrameLayout({
    required this.headerTop,
    required this.backdropOffset,
    required this.letteringTop,
    required this.letteringBottom,
    required this.panelTop,
  });

  static const headerHeight = 56.0;
  static const minimumGap = 12.0;

  final double headerTop;
  final double backdropOffset;
  final double letteringTop;
  final double letteringBottom;
  final double panelTop;

  double get headerBottom => headerTop + headerHeight;
}

// 키보드가 닫힌 폰 화면의 배치. BuildContext·플랫폼·상태에 의존하지 않는다.
PhoneFrameLayout calculatePhoneFrameLayout({
  required double width,
  required double height,
  required double safeTop,
}) {
  final headerTop = safeTop + 12;
  final headerBottom = headerTop + PhoneFrameLayout.headerHeight;
  final original = phoneLetteringBounds(width: width, height: height);
  // 정본의 상단 24dp 초과분을 옮기되, 기기 비율에 따른 중앙 crop도 보정한다.
  // 위쪽 획과 헤더 전체(56dp 조작부 포함)의 간격을 정수 dp로 올림해 확보한다.
  final backdropOffset = math
      .max(
        math.max(0.0, safeTop - 24),
        headerBottom + PhoneFrameLayout.minimumGap - original.top,
      )
      .ceilToDouble();
  final lettering = phoneLetteringBounds(
    width: width,
    height: height,
    verticalOffset: backdropOffset,
  );
  final preferredTop =
      height * (isNarrowPhone(width, height) ? 260 / 780 : 304 / 915) +
      backdropOffset;
  final panelTop = math.max(
    preferredTop,
    math.max(headerBottom, lettering.bottom) + PhoneFrameLayout.minimumGap,
  );
  return PhoneFrameLayout(
    headerTop: headerTop,
    backdropOffset: backdropOffset,
    letteringTop: lettering.top,
    letteringBottom: lettering.bottom,
    panelTop: panelTop,
  );
}
