import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/audio/mic_device_names.dart';

void main() {
  test('emptyAddressOnlyAddsId', () {
    expect(
      MicDeviceNames.format('Car on arm64 emulator', '', 56),
      'Car on arm64 emulator#56',
    );
  });
  test('matchingAddressIsNotRepeated', () {
    expect(
      MicDeviceNames.format('Built-In Mic', 'Built-In Mic', 57),
      'Built-In Mic#57',
    );
  });
  test('differentAddressIsAddedBeforeId', () {
    expect(
      MicDeviceNames.format('Car on arm64 emulator', 'Built-In Back Mic', 66),
      'Car on arm64 emulator · Built-In Back Mic#66',
    );
  });
}
