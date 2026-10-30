class ServerAddress {
  static String normalize(String value, {bool allowPrivateCleartext = false}) {
    final address = value.trim().replaceFirst(RegExp(r'/+$'), '');
    late Uri uri;
    try {
      // Dart Uri는 공백을 자동 인코딩하므로 java.net.URI와 같이 거부한다.
      if (RegExp(r'[\s\\]').hasMatch(address) ||
          RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(address)) {
        throw const FormatException();
      }
      uri = Uri.parse(address);
    } on FormatException {
      throw const FormatException('서버 주소를 확인해 주세요.');
    }
    if (!{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('http:// 또는 https://로 시작하는 서버 주소를 입력해 주세요.');
    }
    int port;
    try {
      port = uri.port;
    } on FormatException {
      throw const FormatException(
        '서버 주소에는 계정 정보·쿼리·조각 식별자를 넣을 수 없습니다. 포트도 확인해 주세요.',
      );
    }
    // Dart Uri는 빈 userinfo("https://@host")를 authority에서 지우므로
    // java.net.URI처럼 원문 authority에 '@'가 있으면 거부한다.
    final rawAuthority =
        RegExp(r'^[^:/?#]+://([^/?#]*)').firstMatch(address)?.group(1) ?? '';
    if (rawAuthority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (port < 1 || port > 65535))) {
      throw const FormatException(
        '서버 주소에는 계정 정보·쿼리·조각 식별자를 넣을 수 없습니다. 포트도 확인해 주세요.',
      );
    }
    final local = {'10.0.2.2', 'localhost', '127.0.0.1'}.contains(uri.host);
    if (uri.scheme != 'https' &&
        !local &&
        !(allowPrivateCleartext && _isPrivateIpv4(uri.host))) {
      throw const FormatException('로컬 개발 서버 외의 주소는 HTTPS를 사용해 주세요.');
    }
    return address;
  }

  static bool _isPrivateIpv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4 ||
        parts.any((p) => !RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(p))) {
      return false;
    }
    final bytes = parts.map(int.parse).toList();
    if (bytes.any((b) => b > 255)) return false;
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
}
