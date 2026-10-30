import 'package:flutter/services.dart';

enum DeviceMode { phone, car }

class DeviceCapabilities {
  const DeviceCapabilities({required this.mode, required this.hasMicrophone});

  final DeviceMode mode;
  final bool hasMicrophone;

  static const channel = MethodChannel('unavo/device');

  static Future<DeviceCapabilities> detect() async {
    try {
      final car = await channel.invokeMethod<bool>('isAutomotive') ?? false;
      final microphone =
          await channel.invokeMethod<bool>('hasMicrophone') ?? false;
      return DeviceCapabilities(
        mode: car ? DeviceMode.car : DeviceMode.phone,
        hasMicrophone: microphone,
      );
    } on MissingPluginException {
      // F2에서 iOS 장치·오디오 구현을 연결한다. 화면은 폰 모드로 동작한다.
      return const DeviceCapabilities(
        mode: DeviceMode.phone,
        hasMicrophone: false,
      );
    } on PlatformException {
      return const DeviceCapabilities(
        mode: DeviceMode.phone,
        hasMicrophone: false,
      );
    }
  }
}
