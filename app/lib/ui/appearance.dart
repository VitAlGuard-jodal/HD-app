import 'package:flutter/material.dart';

class AppearanceController extends ChangeNotifier {
  Brightness? overrideBrightness;
  ThemeMode get themeMode => switch (overrideBrightness) {
    Brightness.dark => ThemeMode.dark,
    Brightness.light => ThemeMode.light,
    null => ThemeMode.system,
  };
  Brightness resolve(BuildContext context) =>
      overrideBrightness ?? MediaQuery.platformBrightnessOf(context);
  void toggle(BuildContext context) {
    overrideBrightness = resolve(context) == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    notifyListeners();
  }
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
