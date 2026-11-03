import 'package:flutter/widgets.dart';

import 'floating_bar.dart';

// 스크롤 내용은 뷰포트에서 자르되 바깥 6dp + 3dp 포커스 링만 허용한다.
// Clip.none 단독 사용으로 내용이 패널/레터링 위로 그려지는 것을 막는다.
class PanelViewport extends StatelessWidget {
  const PanelViewport({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      ClipRect(clipper: _FocusClipper(), child: child);
}

class _FocusClipper extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) => (Offset.zero & size).inflate(9);
  @override
  bool shouldReclip(_FocusClipper oldClipper) => false;
}

class PanelScroll extends StatelessWidget {
  const PanelScroll({super.key, required this.child, this.controller});
  final Widget child;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => PanelViewport(
    child: SingleChildScrollView(
      controller: controller,
      padding: EdgeInsets.only(bottom: FloatingBarInset.of(context)),
      clipBehavior: Clip.none,
      child: child,
    ),
  );
}
