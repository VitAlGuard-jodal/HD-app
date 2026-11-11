import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../net/api_client.dart';
import '../net/models.dart';

const avatarMaxBytes = 300 * 1024;

/// 원본 비율을 보존해 디코딩한 뒤 중앙 정사각형을 256px PNG로 다시 그린다.
Future<Uint8List> prepareAvatarPng(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  late final int width, height;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = math.min(
      1.0,
      1024 / math.max(descriptor.width, descriptor.height),
    );
    width = math.max(1, (descriptor.width * scale).round());
    height = math.max(1, (descriptor.height * scale).round());
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: width,
    targetHeight: height,
    allowUpscaling: false,
  );
  ui.Image? source;
  ui.Image? cropped;
  ui.Image? output;
  ui.Picture? cropPicture;
  ui.Picture? picture;
  try {
    source = (await codec.getNextFrame()).image;
    final side = math.min(source.width, source.height);
    final squareRect = ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble());
    // 축소 필터가 잘린 영역 밖을 샘플링하지 않도록 먼저 1:1 정수 좌표로 자른다.
    final cropRecorder = ui.PictureRecorder();
    ui.Canvas(cropRecorder).drawImageRect(
      source,
      ui.Rect.fromLTWH(
        ((source.width - side) ~/ 2).toDouble(),
        ((source.height - side) ~/ 2).toDouble(),
        side.toDouble(),
        side.toDouble(),
      ),
      squareRect,
      ui.Paint()..filterQuality = ui.FilterQuality.none,
    );
    cropPicture = cropRecorder.endRecording();
    cropped = await cropPicture.toImage(side, side);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      cropped,
      squareRect,
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    picture = recorder.endRecording();
    output = await picture.toImage(256, 256);
    final data = await output.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw const FormatException('프로필 사진을 만들지 못했습니다.');
    final png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (png.length > avatarMaxBytes)
      throw const FormatException('프로필 사진은 300KB 이하여야 합니다.');
    return png;
  } finally {
    source?.dispose();
    cropped?.dispose();
    output?.dispose();
    cropPicture?.dispose();
    picture?.dispose();
    codec.dispose();
  }
}

/// 네이버 캡처 전에 완성된 픽셀을 받는다. 호출자가 ui.Image를 dispose한다.
Future<ui.Image?> decodeAvatar(
  Member member, {
  ApiClient? api,
  required AssetBundle bundle,
  bool defaultMascot = false,
}) async {
  final avatar = member.avatar.kind == null && defaultMascot
      ? const Avatar(kind: 'mascot-01')
      : member.avatar;
  Uint8List bytes;
  if (avatar.isMascot) {
    final data = await bundle.load('assets/avatars/${avatar.kind}.png');
    bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } else if (avatar.kind == 'photo' && api != null) {
    bytes = await api.avatarPhoto(member.handle, avatar.version);
  } else {
    return null;
  }
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: 256,
    targetHeight: 256,
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
