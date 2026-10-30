import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/auth/handle_rules.dart';

void main() {
  test('acceptsLowercaseDigitsAndUnderscores', () {
    for (final handle in ['abc', 'driver_01', '123', '___', 'a' * 20]) {
      expect(HandleRules.isValid(handle), isTrue, reason: handle);
    }
  });
  test('rejectsOutsideLengthBounds', () {
    for (final handle in ['', 'ab', 'a' * 21]) {
      expect(HandleRules.isValid(handle), isFalse, reason: handle);
    }
  });
  test('rejectsUppercaseWhitespaceAndOtherCharacters', () {
    for (final handle in [
      'ABC',
      'a b',
      'user-name',
      'user.name',
      '사용자',
      'abc\n',
      ' abc',
      'abc ',
      'abc@x',
    ]) {
      expect(HandleRules.isValid(handle), isFalse, reason: handle);
    }
  });
}
