import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/core/server_address.dart';

void main() {
  test('normalizesWhitespaceTrailingSlashAndKeepsBasePath', () {
    expect(
      ServerAddress.normalize(' https://voice.example.com/base/// '),
      'https://voice.example.com/base',
    );
  });
  test('allowsHttpsAndLoopbackInRelease', () {
    for (final address in [
      'https://voice.example.com',
      'http://10.0.2.2:8787',
      'http://localhost:8787',
      'http://127.0.0.1:8787',
    ]) {
      expect(ServerAddress.normalize(address), address);
    }
  });
  test('rejectsPrivateCleartextByDefault', () {
    for (final host in [
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.1.20',
    ]) {
      expect(
        () => ServerAddress.normalize('http://$host:8787'),
        throwsFormatException,
      );
    }
  });
  test('allowsOnlyRfc1918CleartextWhenEnabled', () {
    for (final host in [
      '10.0.0.1',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.1.20',
    ]) {
      expect(
        ServerAddress.normalize(
          'http://$host:8787',
          allowPrivateCleartext: true,
        ),
        'http://$host:8787',
      );
    }
    for (final host in [
      '172.15.255.255',
      '172.32.0.1',
      '192.169.1.1',
      '8.8.8.8',
      'example.com',
      '10.999.1.1',
      '10.1.1',
      '010.0.0.1',
    ]) {
      expect(
        () => ServerAddress.normalize(
          'http://$host',
          allowPrivateCleartext: true,
        ),
        throwsFormatException,
      );
    }
  });
  test('rejectsCredentialsQueryFragmentAndInvalidPort', () {
    for (final address in [
      'https://user:pass@example.com',
      'https://@example.com',
      'https://example.com?a=1',
      'https://example.com?',
      'https://example.com#room',
      'https://example.com:0',
      'https://example.com:65536',
    ]) {
      expect(
        () => ServerAddress.normalize(address),
        throwsFormatException,
        reason: address,
      );
    }
  });
  test('rejectsMissingOrUnsupportedSchemeAndMalformedUri', () {
    for (final address in [
      '',
      'example.com',
      'ftp://example.com',
      'http://',
      'https://exa mple.com',
      'https://example.com/%zz',
    ]) {
      expect(
        () => ServerAddress.normalize(address),
        throwsFormatException,
        reason: address,
      );
    }
  });
}
