import 'package:flutter/material.dart';

// 밤과 낮은 배경만 달라진다. 조작부 팔레트는 승인 정본과 동일하다.
abstract final class UnavoColors {
  static const ink = Color(0xFF0B0F1A);
  static const panel = Color(0xEB0B0F1A);
  static const input = Color(0xFF171E2B);
  static const nebula = Color(0xFF302D66);
  static const sandstone = Color(0xFFAA472A);
  static const gold = Color(0xFFF6AE30);
  static const text = Color(0xFFF3EDDF);
  static const muted = Color(0xFFC0B9AD);
  static const line = Color(0xFF818A9C);
  static const call = Color(0xFF1D513F);
  static const speaking = Color(0xFF7CFF5B);
  static const onCall = Color(0xFF9FE3B2);
  static const danger = Color(0xFF73332F);
  static const onDanger = Color(0xFFFFB6AB);
  static const daySky = [
    Color(0xFF452B56),
    Color(0xFFAA5262),
    Color(0xFFDE8557),
    Color(0xFFF5B378),
  ];
}

abstract final class UnavoType {
  static const body = TextStyle(
    fontSize: 16,
    height: 1.4,
    color: UnavoColors.text,
  );
  static const caption = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: UnavoColors.muted,
  );
  static const title = TextStyle(
    fontSize: 24,
    height: 1.25,
    fontWeight: FontWeight.w700,
    color: UnavoColors.text,
  );
  static const display = TextStyle(
    fontFamily: 'BlackHanSans',
    color: UnavoColors.text,
    height: 1.1,
  );
  static const western = TextStyle(fontFamily: 'Rye', color: UnavoColors.gold);
}

BoxDecoration panelDecoration({bool opaque = false}) => BoxDecoration(
  color: opaque ? UnavoColors.ink : UnavoColors.panel,
  border: Border.all(color: UnavoColors.line),
);

ThemeData unavoTheme(Brightness brightness) => ThemeData(
  brightness: brightness,
  scaffoldBackgroundColor: UnavoColors.ink,
  colorScheme:
      ColorScheme.fromSeed(
        seedColor: UnavoColors.gold,
        brightness: brightness,
      ).copyWith(
        primary: UnavoColors.gold,
        onPrimary: UnavoColors.ink,
        surface: UnavoColors.ink,
        onSurface: UnavoColors.text,
        error: UnavoColors.onDanger,
        onError: UnavoColors.ink,
      ),
  textTheme: const TextTheme(
    bodyMedium: UnavoType.body,
    bodyLarge: UnavoType.body,
    titleLarge: UnavoType.title,
    labelLarge: UnavoType.body,
  ),
  textSelectionTheme: const TextSelectionThemeData(
    cursorColor: UnavoColors.gold,
    selectionColor: Color(0x66F6AE30),
    selectionHandleColor: UnavoColors.gold,
  ),
  splashFactory: NoSplash.splashFactory,
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: _NoPageTransition(),
      TargetPlatform.iOS: _NoPageTransition(),
    },
  ),
);

class _NoPageTransition extends PageTransitionsBuilder {
  const _NoPageTransition();
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
