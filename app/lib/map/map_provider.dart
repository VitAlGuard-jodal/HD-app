enum MapProvider { naver, vworld }

const naverClientId = String.fromEnvironment('NAVER_CLIENT_ID');

MapProvider mapProviderFromEnvironment() => selectMapProvider(
  requested: const String.fromEnvironment(
    'UNAVO_MAP_PROVIDER',
    defaultValue: 'auto',
  ),
  clientId: naverClientId,
);

/// 명시적 선택은 키 유무보다 우선한다. 알 수 없는 값은 auto로 취급한다.
MapProvider selectMapProvider({
  String requested = 'auto',
  String clientId = '',
}) => switch (requested.trim().toLowerCase()) {
  'naver' => MapProvider.naver,
  'vworld' => MapProvider.vworld,
  _ => clientId.trim().isEmpty ? MapProvider.vworld : MapProvider.naver,
};
