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
import '../../ui/icons.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/member_avatar.dart';
import '../../ui/widgets/panel_button.dart';
import '../../ui/widgets/unavo_dialog.dart';
import 'profile_source.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.api,
    required this.store,
    this.car = false,
    this.showBackButton = true,
  });
  final ApiClient api;
  final SessionStore store;
  final bool car;
  final bool showBackButton;
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

  Future<ProfileSourceChoice?> _chooseSource() async {
    if (_busy) return null;
    if (!widget.car) {
      final route = MaterialPageRoute<ProfileSourceChoice>(
        builder: (_) => ProfileSourcePage(selectedKind: _selection.kind),
      );
      final choice = await Navigator.of(
        context,
      ).push<ProfileSourceChoice>(route);
      await route.completed;
      return choice;
    }

    ModalRoute<ProfileSourceChoice>? route;
    final choice = await showUnavoChoiceDialog<ProfileSourceChoice>(
      context,
      key: const ValueKey('profile-source-dialog'),
      car: true,
      useRootNavigator: false,
      child: Builder(
        builder: (dialogContext) {
          route = ModalRoute.of<ProfileSourceChoice>(dialogContext);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PanelButton(
                key: const ValueKey('profile-gallery'),
                label: '사진첩에서 선택',
                icon: 'plus',
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop<ProfileSourceChoice>(const ProfileSourceGallery()),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  for (final kind in Avatar.mascotKinds)
                    Semantics(
                      label: '기본 아바타 ${Avatar.mascotKinds.indexOf(kind) + 1}',
                      selected: _selection.kind == kind,
                      button: true,
                      child: IconButton(
                        key: ValueKey('profile-$kind'),
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(
                          dialogContext,
                        ).pop<ProfileSourceChoice>(ProfileSourceMascot(kind)),
                        icon: MemberAvatar(
                          member: _member(Avatar(kind: kind)),
                          diameter: 96,
                          borderColor: _selection.kind == kind
                              ? UnavoColors.gold
                              : Colors.transparent,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
    // 퇴장 애니메이션과 모달 제거가 끝난 뒤 선택 결과를 처리한다.
    await route?.completed;
    return choice;
  }

  Future<void> _editSource(BuildContext screenContext) async {
    final choice = await _chooseSource();
    if (!mounted) return;
    switch (choice) {
      case ProfileSourceMascot(:final kind):
        setState(() {
          _selection = Avatar(kind: kind);
          _photo = null;
          _changed = true;
        });
      case ProfileSourceGallery():
        if (screenContext.mounted) await _pickPhoto(screenContext);
      case null:
        break;
    }
  }

  Future<void> _pickPhoto(BuildContext screenContext) async {
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
      if (screenContext.mounted)
        await showNoticeDialog(screenContext, message: errorMessage(error));
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

  Widget _buildEditButton(BuildContext context) {
    final diameter = widget.car ? 160.0 : 120.0;
    final badgeDiameter = diameter * .32;
    final badgeOffset = diameter * .86 - badgeDiameter / 2;
    // 원 밖으로 나온 배지까지 같은 버튼의 탭 영역에 포함한다.
    final editDiameter = badgeOffset + badgeDiameter;
    return Semantics(
      label: '프로필 사진 바꾸기',
      button: true,
      enabled: !_busy,
      child: IconButton(
        key: const ValueKey('profile-edit'),
        padding: EdgeInsets.zero,
        iconSize: editDiameter,
        onPressed: _busy ? null : () async => _editSource(context),
        icon: SizedBox.square(
          dimension: editDiameter,
          child: Stack(
            alignment: Alignment.topLeft,
            clipBehavior: Clip.none,
            children: [
              MemberAvatar(
                key: const ValueKey('profile-preview'),
                member: _member(_selection),
                diameter: diameter,
                showBorder: false,
                defaultMascot: true,
                api: widget.api,
                preview: _photo,
              ),
              Positioned(
                left: badgeOffset,
                top: badgeOffset,
                child: Container(
                  key: const ValueKey('profile-edit-badge'),
                  width: badgeDiameter,
                  height: badgeDiameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _busy ? UnavoColors.panel : UnavoColors.gold,
                    border: Border.all(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: UnavoIcon(
                      'camera',
                      size: badgeDiameter * .58,
                      color: UnavoColors.ink,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
                          _buildEditButton(context),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: widget.showBackButton
                        ? MainAxisAlignment.spaceBetween
                        : MainAxisAlignment.end,
                    children: [
                      if (widget.showBackButton)
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
