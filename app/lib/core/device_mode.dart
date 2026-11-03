import 'package:flutter/services.dart';

enum DeviceMode { phone, car }

// Pleos CALL volume is controlled by hardware keys. Flip only after option A
// is approved; the native system-volume bridge remains available.
const carVolumeSlider = false;

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
      // 네이티브 채널이 없는 데스크톱 등에서는 폰 레이아웃으로 표시한다.
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
