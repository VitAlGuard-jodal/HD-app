import 'package:flutter/material.dart';

import '../theme.dart';

class UnavoWatermark extends StatelessWidget {
  const UnavoWatermark({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? UnavoColors.text : UnavoColors.gold;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Opacity(
          opacity: dark ? .16 : .18,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth * .8;
              return Center(
                child: SizedBox(
                  width: width,
                  height: constraints.maxHeight * .4,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 큰 패널에서도 고정 글자 크기에 묶이지 않게 한 뒤 맞춘다.
                        Text(
                          'Una Vox',
                          style: UnavoType.western.copyWith(
                            color: color,
                            fontSize: width / 2,
                            height: 1,
                          ),
                        ),
                        Text(
                          'UNAVO',
                          style: UnavoType.western.copyWith(
                            color: color,
                            fontSize: width,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
