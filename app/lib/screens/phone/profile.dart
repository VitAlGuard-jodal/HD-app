import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    show ImagePickerPlatform;

import '../../auth/session_store.dart';
import '../../core/errors.dart';
import '../../net/api_client.dart';
import '../../net/models.dart';
import '../../ui/avatar_images.dart';
import '../../ui/control_scale.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/member_avatar.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/unavo_dialog.dart';

class ProfileAvatarButton extends StatelessWidget {
  const ProfileAvatarButton({
    super.key,
    required this.api,
    required this.store,
  });
  final ApiClient api;
  final SessionStore store;

  @override
  Widget build(BuildContext context) {
    final car = ControlScale.isCar(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Semantics(
        label: '내 프로필 편집',
        button: true,
        child: IconButton(
          key: const ValueKey('open-profile'),
          constraints: BoxConstraints.tightFor(
            width: car ? 80 : 56,
            height: car ? 80 : 56,
          ),
          padding: const EdgeInsets.all(8),
          style: IconButton.styleFrom(shape: const CircleBorder()),
          onPressed: store.handle == null
              ? null
              : () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ProfileScreen(api: api, store: store, car: car),
                  ),
                ),
          icon: MemberAvatar(
            member: Member(
              store.handle ?? '',
              store.displayName ?? store.handle ?? '',
              '',
              avatar: store.avatar,
            ),
            diameter: car ? 56 : 40,
            showBorder: false,
            defaultMascot: true,
            api: api,
          ),
        ),
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.api,
    required this.store,
    this.car = false,
  });
  final ApiClient api;
  final SessionStore store;
  final bool car;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Avatar _selection = widget.store.avatar;
  Uint8List? _photo;
  bool _busy = false, _changed = false;

  Member _member(Avatar avatar) => Member(
    widget.store.handle ?? '',
    widget.store.displayName ?? widget.store.handle ?? '',
    '',
    avatar: avatar,
  );

  Future<void> _pickPhoto(BuildContext dialogContext) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // image_picker의 설치된 Android 구현은 16 미만에서 명시적 opt-in이 필요하다.
      final platform = ImagePickerPlatform.instance;
      if (platform is ImagePickerAndroid) platform.useAndroidPhotoPicker = true;
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (file == null || !mounted) return;
      final png = await prepareAvatarPng(await file.readAsBytes());
      if (!mounted) return;
      setState(() {
        _photo = png;
        _selection = Avatar(
          kind: 'photo',
          version: widget.store.avatar.version,
        );
        _changed = true;
      });
    } catch (error) {
      if (dialogContext.mounted)
        await showNoticeDialog(dialogContext, message: errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(BuildContext dialogContext) async {
    if (_busy || !_changed) return;
    setState(() => _busy = true);
    final token = widget.store.token;
    try {
      final user = _selection.kind == null
          ? await widget.api.deleteAvatar()
          : await widget.api.updateAvatar(_selection.kind!, png: _photo);
      if (widget.store.token != token) return;
      await widget.store.updateAvatar(user.avatar);
      if (mounted) {
        setState(() => _busy = false);
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (dialogContext.mounted)
        await showNoticeDialog(dialogContext, message: errorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ControlScale(
    car: widget.car,
    child: Builder(
      builder: (context) => PopScope(
        canPop: !_busy,
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          const SizedBox(height: 12),
                          MemberAvatar(
                            key: const ValueKey('profile-preview'),
                            member: _member(_selection),
                            diameter: widget.car ? 160 : 120,
                            showBorder: false,
                            defaultMascot: true,
                            api: widget.api,
                            preview: _photo,
                          ),
                          const SizedBox(height: 28),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            alignment: WrapAlignment.center,
                            children: [
                              for (final kind in Avatar.mascotKinds)
                                Semantics(
                                  label:
                                      '기본 아바타 ${Avatar.mascotKinds.indexOf(kind) + 1}',
                                  selected: _selection.kind == kind,
                                  button: true,
                                  child: IconButton(
                                    key: ValueKey('profile-$kind'),
                                    padding: EdgeInsets.zero,
                                    onPressed: _busy
                                        ? null
                                        : () => setState(() {
                                            _selection = Avatar(kind: kind);
                                            _photo = null;
                                            _changed = true;
                                          }),
                                    icon: MemberAvatar(
                                      member: _member(Avatar(kind: kind)),
                                      diameter: widget.car ? 96 : 72,
                                      borderColor: _selection.kind == kind
                                          ? UnavoColors.gold
                                          : Colors.transparent,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          PanelButton(
                            key: const ValueKey('profile-gallery'),
                            label: '사진첩에서 선택',
                            icon: 'plus',
                            onPressed: _busy
                                ? null
                                : () async => _pickPhoto(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      PanelButton(
                        key: const ValueKey('profile-back'),
                        label: '되돌리기',
                        icon: 'back',
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                      ),
                      PanelButton(
                        key: const ValueKey('profile-save'),
                        label: '프로필 저장',
                        icon: 'check',
                        style: PanelButtonStyle.gold,
                        onPressed: _busy || !_changed
                            ? null
                            : () async => _save(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
