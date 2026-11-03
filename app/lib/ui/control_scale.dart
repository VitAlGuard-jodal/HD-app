import 'package:flutter/widgets.dart';

/// 차량 조작부의 크기는 창 높이나 키보드 높이가 아닌 기기 모드로 결정한다.
class ControlScale extends InheritedWidget {
  const ControlScale({super.key, required this.car, required super.child});
  final bool car;
  static bool isCar(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ControlScale>()?.car ?? false;
  static double target(BuildContext context) => isCar(context) ? 80 : 56;
  static double icon(BuildContext context) => isCar(context) ? 36 : 24;
  @override
  bool updateShouldNotify(ControlScale oldWidget) => car != oldWidget.car;
}
