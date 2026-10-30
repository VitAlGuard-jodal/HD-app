import 'package:flutter/widgets.dart';

import '../theme.dart';

class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.child});
  final Widget child;
  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (value) => setState(() {
      focused = value;
    }),
    child: CustomPaint(
      foregroundPainter: focused ? _RingPainter() : null,
      child: widget.child,
    ),
  );
}

class _RingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
    (Offset.zero & size).inflate(7.5),
    Paint()
      ..color = UnavoColors.gold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3,
  );
  @override
  bool shouldRepaint(_RingPainter oldDelegate) => false;
}
