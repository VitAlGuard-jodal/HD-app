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
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/ui-$name.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    semanticsLabel: label,
  );
}
