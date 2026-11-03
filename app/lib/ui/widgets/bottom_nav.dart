import 'package:flutter/widgets.dart';

import '../theme.dart';
import 'panel_button.dart';

class BottomNav extends StatelessWidget {
  const BottomNav({super.key, required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Container(
    height: 76,
    decoration: panelDecoration(),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    child: Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: PanelButton(
              label: const ['방', '친구', '마이크'][i],
              icon: const ['rooms', 'friends', 'mic'][i],
              selected: i == index,
              style: i == index
                  ? PanelButtonStyle.gold
                  : PanelButtonStyle.neutral,
              onPressed: () => onChanged(i),
            ),
          ),
        ],
      ],
    ),
  );
}
