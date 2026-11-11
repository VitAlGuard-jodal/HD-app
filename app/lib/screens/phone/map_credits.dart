import 'package:flutter/material.dart';

import '../../map/map_provider.dart';
import '../../map/map_tiles.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/panel_scroll.dart';

class MapCreditsScreen extends StatelessWidget {
  const MapCreditsScreen({super.key, this.provider = MapProvider.vworld});
  final MapProvider provider;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: PanelButton(
                label: '뒤로',
                icon: 'back',
                iconOnly: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: PanelScroll(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (provider == MapProvider.naver)
                      const Text(
                        '지도: 네이버 지도 (NAVER Cloud Platform Maps)·지도 왼쪽 아래 NAVER 로고를 누르면 법적 고지와 오픈소스 정보',
                        style: UnavoType.body,
                      )
                    else ...[
                      Text(mapTiles.attribution, style: UnavoType.title),
                      const SizedBox(height: 24),
                      const Text(
                        '국토교통부의 저작물 “브이월드 배경지도”를 공공누리 제1유형(출처표시)에 따라 이용합니다. 수정·가공하지 않음.',
                        style: UnavoType.body,
                      ),
                    ],
                    const SizedBox(height: 24),
                    const Text(
                      '위치는 방이 있는 동안만 서버(국내 리전)에 남습니다',
                      style: UnavoType.body,
                    ),
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: PanelButton(
                        label: '패키지 라이선스',
                        icon: 'chevron',
                        iconOnly: true,
                        onPressed: () => showLicensePage(
                          context: context,
                          applicationName: '우나보',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
