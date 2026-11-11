import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/map/map_tiles.dart';

void main() {
  test('기본 WMTS 경로는 z/y/x이며 키가 없으면 타일을 끈다', () {
    final tiles = MapTiles.fromDefines({});
    expect(tiles.enabled, isFalse);
    expect(MapTiles.fromDefines({'UNAVO_TILE_KEY': '  '}).enabled, isFalse);
    expect(
      tiles.url,
      'https://api.vworld.kr/req/wmts/1.0.0/{key}/{layer}/{z}/{y}/{x}.png',
    );
    expect(tiles.attribution, '© 국토교통부 브이월드');
    expect(MapTiles.userAgentPackageName, 'kr.modumoa.hdapp');
    expect(tiles.minimumZoom(Brightness.light), 6);
    expect(tiles.maximumZoom(Brightness.light), 19);
  });

  test('define을 파싱하고 키와 레이어만 치환한다', () {
    final tiles = MapTiles.fromDefines({
      'UNAVO_TILE_URL': 'https://tiles.example/{key}/{layer}/{z}/{y}/{x}.png',
      'UNAVO_TILE_KEY': 'test key',
      'UNAVO_TILE_LAYER_LIGHT': 'day',
      'UNAVO_TILE_LAYER_DARK': 'night',
      'UNAVO_TILE_ATTRIBUTION': '© test',
      'UNAVO_TILE_MIN_ZOOM': '7',
      'UNAVO_TILE_MAX_ZOOM': '17',
    });
    expect(tiles.enabled, isTrue);
    expect(
      tiles.template(Brightness.light),
      'https://tiles.example/test%20key/day/{z}/{y}/{x}.png',
    );
    expect(tiles.template(Brightness.dark), contains('/night/{z}/{y}/{x}.png'));
    expect(tiles.attribution, '© test');
    expect(tiles.minimumZoom(Brightness.dark), 7);
    expect(tiles.maximumZoom(Brightness.dark), 17);
  });

  test('다크는 midnight·18 상한, 뒤집힌 범위와 잘못된 숫자도 보정한다', () {
    const tiles = MapTiles(key: 'key');
    expect(tiles.layer(Brightness.light), 'Base');
    expect(tiles.layer(Brightness.dark), 'midnight');
    expect(tiles.maximumZoom(Brightness.dark), 18);
    final reversed = MapTiles.fromDefines({
      'UNAVO_TILE_MIN_ZOOM': '20',
      'UNAVO_TILE_MAX_ZOOM': '19',
    });
    expect(reversed.minimumZoom(Brightness.dark), 18);
    expect(reversed.minimumZoom(Brightness.light), 19);
    for (final value in ['NaN', 'Infinity', '-1', 'bad', '23']) {
      final invalid = MapTiles.fromDefines({
        'UNAVO_TILE_MIN_ZOOM': value,
        'UNAVO_TILE_MAX_ZOOM': value,
      });
      expect(invalid.minZoom, 6);
      expect(invalid.maxZoom, 19);
    }
  });

  test('환경 생성자는 컴파일 define을 읽는다', () {
    final tiles = MapTiles.fromEnvironment();
    const key = String.fromEnvironment('UNAVO_TILE_KEY');
    expect(tiles.key, key.trim());
    expect(tiles.enabled, key.trim().isNotEmpty);
  });
}
