import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/map/map_provider.dart';

void main() {
  // 비어 있지 않다는 조건만 위한 합성 문자열이며 실제 인증값은 사용하지 않는다.
  final present = String.fromCharCodes(List.filled(4, 120));

  test('기본 auto와 빈 키는 브이월드다', () {
    expect(selectMapProvider(), MapProvider.vworld);
    expect(
      selectMapProvider(requested: 'auto', clientId: ''),
      MapProvider.vworld,
    );
    expect(selectMapProvider(clientId: ' \n\t '), MapProvider.vworld);
  });

  test('auto는 네이버 인증값이 있을 때 네이버를 고른다', () {
    expect(selectMapProvider(clientId: present), MapProvider.naver);
    expect(
      selectMapProvider(requested: 'auto', clientId: present),
      MapProvider.naver,
    );
  });

  test('명시적 naver는 빈 키도 SDK 인증 오류로 처리하도록 선택을 유지한다', () {
    for (final clientId in ['', ' ', present]) {
      expect(
        selectMapProvider(requested: 'naver', clientId: clientId),
        MapProvider.naver,
      );
    }
  });

  test('명시적 vworld는 네이버 인증값이 있어도 브이월드다', () {
    for (final clientId in ['', ' ', present]) {
      expect(
        selectMapProvider(requested: 'vworld', clientId: clientId),
        MapProvider.vworld,
      );
    }
  });

  test('공백과 대소문자를 정규화한다', () {
    expect(selectMapProvider(requested: ' NAVER '), MapProvider.naver);
    expect(
      selectMapProvider(requested: ' VWORLD ', clientId: present),
      MapProvider.vworld,
    );
    expect(
      selectMapProvider(requested: ' AUTO ', clientId: present),
      MapProvider.naver,
    );
  });

  test('미지정·잘못된 공급원 문자열은 auto 규칙을 쓴다', () {
    for (final requested in ['', 'unknown']) {
      expect(selectMapProvider(requested: requested), MapProvider.vworld);
      expect(
        selectMapProvider(requested: requested, clientId: present),
        MapProvider.naver,
      );
    }
  });
}
