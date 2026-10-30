class HandleRules {
  static final _pattern = RegExp(r'^[a-z0-9_]{3,20}$');
  static bool isValid(String handle) {
    final match = _pattern.firstMatch(handle);
    return match != null && match.end == handle.length;
  }

  static const help = '아이디는 소문자 영문·숫자·밑줄로 3~20자 입력해 주세요.';
}
