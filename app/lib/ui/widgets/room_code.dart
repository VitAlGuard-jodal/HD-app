import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

class RoomCode extends StatelessWidget {
  const RoomCode(this.code, {super.key, this.fontSize = 64});
  final String code;
  final double fontSize;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '방 코드 $code',
    excludeSemantics: true,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final style = UnavoType.display.copyWith(
          fontSize: fontSize,
          letterSpacing: fontSize == 64 ? -1 : 0,
        );
        final painter = TextPainter(
          text: TextSpan(text: code, style: style),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final width = painter.width;
        final height = math.max(fontSize == 64 ? 72.0 : 44.0, painter.height);
        painter.dispose();
        final scaleX = width == 0
            ? 1.0
            : math.min(1.0, constraints.maxWidth / width);
        // 64sp 높이는 보존하고 WWWWWW 같은 넓은 코드의 가로 폭만 맞춘다.
        return SizedBox(
          height: height,
          child: ClipRect(
            child: Transform(
              transform: Matrix4.diagonal3Values(scaleX, 1, 1),
              alignment: Alignment.centerLeft,
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: width,
                maxWidth: width,
                child: Text(
                  code,
                  maxLines: 1,
                  softWrap: false,
                  style: style,
                  textDirection: TextDirection.ltr,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// Reject an entire mixed/non-ASCII edit, including IME composition and paste.
class RoomCodeFormatter extends TextInputFormatter {
  const RoomCodeFormatter();
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!RegExp(r'^[a-zA-Z0-9]*$').hasMatch(newValue.text)) return oldValue;
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      composing: TextRange.empty,
    );
  }
}
