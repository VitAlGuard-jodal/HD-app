import 'package:flutter/widgets.dart';

class CarShell extends StatelessWidget {
  const CarShell({super.key, required this.child});
  final Widget child;
  // TODO(F2): 이 경계에서 차량 전용 레이아웃으로 교체한다.
  // F1은 같은 앱의 같은 세션·화면을 그대로 감싼다.
  @override
  Widget build(BuildContext context) => child;
}
