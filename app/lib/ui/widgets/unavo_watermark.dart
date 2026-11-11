import 'package:flutter/material.dart';

import '../theme.dart';

class UnavoWatermark extends StatelessWidget {
  const UnavoWatermark({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: Opacity(
        opacity: .10,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Una Vox',
                    style: UnavoType.western.copyWith(fontSize: 40, height: 1),
                  ),
                  Text(
                    'UNAVO',
                    style: UnavoType.western.copyWith(fontSize: 80, height: 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
