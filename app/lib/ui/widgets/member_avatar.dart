import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../net/api_client.dart';
import '../../net/models.dart';
import '../member_colors.dart';
import '../theme.dart';

/// 카드·프로필·지도에서 동일한 원형 마스크와 마스코트 여백을 사용한다.
class MemberAvatar extends StatefulWidget {
  const MemberAvatar({
    super.key,
    required this.member,
    required this.diameter,
    this.api,
    this.speaking = false,
    this.fallbackOrder = 0,
    this.showBorder = true,
    this.borderColor,
    this.preview,
    this.decodedImage,
    this.imageResolved = false,
    this.fallback,
    this.defaultMascot = false,
  });
  final Member member;
  final double diameter;
  final ApiClient? api;
  final bool speaking, showBorder, imageResolved;
  final int fallbackOrder;
  final Color? borderColor;
  final Uint8List? preview;
  final ui.Image? decodedImage;
  final Widget? fallback;
  final bool defaultMascot;

  @override
  State<MemberAvatar> createState() => _MemberAvatarState();
}

class _MemberAvatarState extends State<MemberAvatar> {
  Future<Uint8List>? _photo;
  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  @override
  void didUpdateWidget(MemberAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.member.handle != widget.member.handle ||
        oldWidget.member.avatar != widget.member.avatar ||
        oldWidget.api != widget.api ||
        oldWidget.preview != widget.preview ||
        oldWidget.imageResolved != widget.imageResolved)
      _loadPhoto();
  }

  void _loadPhoto() {
    _photo =
        !widget.imageResolved &&
            widget.preview == null &&
            widget.member.avatar.kind == 'photo'
        ? widget.api?.avatarPhoto(
            widget.member.handle,
            widget.member.avatar.version,
          )
        : null;
  }

  Widget _initial() {
    final member = widget.member;
    final name = member.displayName.trim().isEmpty
        ? member.handle
        : member.displayName.trim();
    return widget.fallback ??
        Center(
          child: Text(
            name.isEmpty ? '?' : name.characters.first,
            style: UnavoType.body.copyWith(fontSize: widget.diameter * .4),
          ),
        );
  }

  Widget _pixels(Uint8List bytes) => Image.memory(
    bytes,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => _initial(),
  );

  Widget _image() {
    if (widget.preview case final bytes?) return _pixels(bytes);
    if (widget.imageResolved) {
      return widget.decodedImage == null
          ? _initial()
          : RawImage(
              image: widget.decodedImage,
              fit: widget.member.avatar.isMascot
                  ? BoxFit.contain
                  : BoxFit.cover,
            );
    }
    if (widget.member.avatar.isMascot) {
      return Image.asset(
        'assets/avatars/${widget.member.avatar.kind}.png',
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _initial(),
      );
    }
    if (widget.member.avatar.kind == null && widget.defaultMascot) {
      return Image.asset(
        'assets/avatars/mascot-01.png',
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _initial(),
      );
    }
    if (_photo != null) {
      return FutureBuilder<Uint8List>(
        key: ValueKey((widget.member.handle, widget.member.avatar.version)),
        future: _photo,
        builder: (_, snapshot) =>
            snapshot.hasData ? _pixels(snapshot.data!) : _initial(),
      );
    }
    return _initial();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${widget.member.displayName}${widget.speaking ? ", 말하는 중" : ""}',
    child: Container(
      width: widget.diameter,
      height: widget.diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: UnavoColors.input,
        border: widget.showBorder
            ? Border.all(
                width: 3,
                color:
                    widget.borderColor ??
                    rainbowColor(widget.member.order ?? widget.fallbackOrder),
              )
            : null,
        boxShadow: widget.speaking
            ? [
                BoxShadow(
                  color: UnavoColors.speaking.withValues(alpha: .65),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: ClipOval(
        child: SizedBox.expand(
          child: Transform.scale(
            scale: widget.member.avatar.scale,
            child: _image(),
          ),
        ),
      ),
    ),
  );
}
