import 'package:flutter/widgets.dart';

import 'floating_bar.dart';

class BottomNav extends StatelessWidget {
  const BottomNav({super.key, required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => FloatingBar(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var i = 0; i < 3; i++)
          FloatingBarButton(
            label: const ['방', '친구', '마이크'][i],
            icon: const ['rooms', 'friends', 'mic'][i],
            selected: i == index,
            onPressed: () => onChanged(i),
          ),
      ],
    ),
  );
}
