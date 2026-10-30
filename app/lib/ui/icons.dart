import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'theme.dart';

class UnavoIcon extends StatelessWidget {
  const UnavoIcon(
    this.name, {
    super.key,
    this.size = 24,
    this.color = UnavoColors.text,
    this.label,
  });
  final String name;
  final double size;
  final Color color;
  final String? label;

  static const _names = [
    'arrow',
    'back',
    'bluetooth',
    'car',
    'check',
    'chevron',
    'earpiece',
    'exit',
    'friends',
    'hangup',
    'headset',
    'lock',
    'mic',
    'micoff',
    'mobile',
    'moon',
    'phone',
    'plus',
    'refresh',
    'rooms',
    'server',
    'speaker',
    'star',
    'sun',
    'trash',
    'user',
    'wave',
  ];

  static Future<void> precache(BuildContext context) {
    // SvgPicture.asset과 같은 bundle/theme으로 캐시 키를 맞춘다.
    // 비동기 작업에는 BuildContext를 넘기지 않아 표지를 떠나도 안전하다.
    final bundle = DefaultAssetBundle.of(context);
    final theme = DefaultSvgTheme.of(context)?.theme ?? const SvgTheme();
    return runZonedGuarded<Future<void>>(
      () async {
        await Future.wait<void>([
          for (final name in _names)
            _precacheAsset(
              SvgAssetLoader(
                'assets/icons/ui-$name.svg',
                assetBundle: bundle,
                theme: theme,
              ),
            ),
        ]);
      },
      (error, stackTrace) {
        // flutter_svg 2.3.2 캐시 내부의 별도 then 체인도 오류를 전파한다.
        // 예열에 한정한 zone에서 삼켜 앱의 일반 오류 처리에는 영향이 없다.
      },
    )!;
  }

  static Future<void> _precacheAsset(SvgAssetLoader loader) async {
    try {
      // 2.3.2의 loadBytes는 SVG를 벡터 데이터로 변환해 svg.cache에 보관한다.
      await loader.loadBytes(null);
    } catch (_) {
      // 한 아이콘을 못 읽어도 나머지 예열과 화면 진입은 계속한다.
    }
  }

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/ui-$name.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    semanticsLabel: label,
  );
}
