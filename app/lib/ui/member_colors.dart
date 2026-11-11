import 'package:flutter/painting.dart';

const _rainbow = <Color>[
  Color(0xFFFF4D4D),
  Color(0xFFFF9A3C),
  Color(0xFFFFD93C),
  Color(0xFF4CD964),
  Color(0xFF3C8CFF),
  Color(0xFF4B5BD6),
  Color(0xFFB36BFF),
];

Color rainbowColor(int order) => _rainbow[order % _rainbow.length];
