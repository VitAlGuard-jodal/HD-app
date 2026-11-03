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

  static const names = [
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
    'login',
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
    'userplus',
    'wave',
  ];

  // 별도 zone의 수동 예열은 release에서 빈 아이콘을 유발했다.
  // SVG의 로딩과 캐시 수명은 실제 SvgPicture 위젯에만 맡긴다.
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/ui-$name.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    semanticsLabel: label,
  );
}
