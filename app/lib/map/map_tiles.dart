import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class MapTiles {
  const MapTiles({
    this.url = defaultUrl,
    this.key = '',
    this.lightLayer = 'Base',
    this.darkLayer = 'midnight',
    this.attribution = defaultAttribution,
    this.minZoom = 6,
    this.maxZoom = 19,
  });

  factory MapTiles.fromEnvironment() => MapTiles.fromDefines(const {
    'UNAVO_TILE_URL': String.fromEnvironment('UNAVO_TILE_URL'),
    'UNAVO_TILE_KEY': String.fromEnvironment('UNAVO_TILE_KEY'),
    'UNAVO_TILE_LAYER_LIGHT': String.fromEnvironment('UNAVO_TILE_LAYER_LIGHT'),
    'UNAVO_TILE_LAYER_DARK': String.fromEnvironment('UNAVO_TILE_LAYER_DARK'),
    'UNAVO_TILE_ATTRIBUTION': String.fromEnvironment('UNAVO_TILE_ATTRIBUTION'),
    'UNAVO_TILE_MIN_ZOOM': String.fromEnvironment('UNAVO_TILE_MIN_ZOOM'),
    'UNAVO_TILE_MAX_ZOOM': String.fromEnvironment('UNAVO_TILE_MAX_ZOOM'),
  });

  factory MapTiles.fromDefines(Map<String, String> defines) {
    String value(String name, String fallback) {
      final text = defines[name]?.trim();
      return text == null || text.isEmpty ? fallback : text;
    }

    double zoom(String name, double fallback) {
      final number = double.tryParse(defines[name] ?? '');
      return number == null || !number.isFinite || number < 0 || number > 22
          ? fallback
          : number;
    }

    final maxZoom = zoom('UNAVO_TILE_MAX_ZOOM', 19);
    return MapTiles(
      url: value('UNAVO_TILE_URL', defaultUrl),
      key: value('UNAVO_TILE_KEY', ''),
      lightLayer: value('UNAVO_TILE_LAYER_LIGHT', 'Base'),
      darkLayer: value('UNAVO_TILE_LAYER_DARK', 'midnight'),
      attribution: value('UNAVO_TILE_ATTRIBUTION', defaultAttribution),
      minZoom: math.min(zoom('UNAVO_TILE_MIN_ZOOM', 6), maxZoom),
      maxZoom: maxZoom,
    );
  }

  static const defaultUrl =
      'https://api.vworld.kr/req/wmts/1.0.0/{key}/{layer}/{z}/{y}/{x}.png';
  static const defaultAttribution = '© 국토교통부 브이월드';
  static const userAgentPackageName = 'kr.modumoa.hdapp';
  final String url, key, lightLayer, darkLayer, attribution;
  final double minZoom, maxZoom;
  bool get enabled => key.trim().isNotEmpty;

  String layer(Brightness brightness) =>
      brightness == Brightness.dark ? darkLayer : lightLayer;

  double maximumZoom(Brightness brightness) =>
      math.min(maxZoom, brightness == Brightness.dark ? 18 : maxZoom);

  double minimumZoom(Brightness brightness) =>
      math.min(minZoom, maximumZoom(brightness));

  String template(Brightness brightness) => url
      .replaceAll('{key}', Uri.encodeComponent(key))
      .replaceAll('{layer}', Uri.encodeComponent(layer(brightness)));
}

final mapTiles = MapTiles.fromEnvironment();
