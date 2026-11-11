import 'package:flutter/material.dart';

class AppearanceController extends ChangeNotifier {
  // 과거 수동 설정은 사용하지 않는다. OS/차량 주야간 설정이 단일 출처다.
  ThemeMode get themeMode => ThemeMode.system;
  Brightness resolve(BuildContext context) =>
      MediaQuery.platformBrightnessOf(context);
}

class UnavoAppearance extends InheritedNotifier<AppearanceController> {
  const UnavoAppearance({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);
  static AppearanceController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UnavoAppearance>()!.notifier!;
}
