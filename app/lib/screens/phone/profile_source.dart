import 'package:flutter/material.dart';

import '../../net/models.dart';
import '../../ui/control_scale.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/member_avatar.dart';
import '../../ui/widgets/panel_button.dart';

sealed class ProfileSourceChoice {
  const ProfileSourceChoice();
}

final class ProfileSourceGallery extends ProfileSourceChoice {
  const ProfileSourceGallery();
}

final class ProfileSourceMascot extends ProfileSourceChoice {
  const ProfileSourceMascot(this.kind);
  final String kind;
}

class ProfileSourcePage extends StatelessWidget {
  const ProfileSourcePage({
    super.key = const ValueKey('profile-source-page'),
    required this.selectedKind,
  });
  final String? selectedKind;

  @override
  Widget build(BuildContext context) => ControlScale(
    car: false,
    child: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: PanelButton(
                  key: const ValueKey('profile-source-back'),
                  label: '되돌리기',
                  icon: 'back',
                  onPressed: () =>
                      Navigator.of(context).pop<ProfileSourceChoice>(),
                ),
              ),
              const SizedBox(height: 24),
              PanelButton(
                key: const ValueKey('profile-gallery'),
                label: '사진첩에서 선택',
                icon: 'plus',
                onPressed: () => Navigator.of(
                  context,
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
                      selected: selectedKind == kind,
                      button: true,
                      child: IconButton(
                        key: ValueKey('profile-$kind'),
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(
                          context,
                        ).pop<ProfileSourceChoice>(ProfileSourceMascot(kind)),
                        icon: MemberAvatar(
                          member: Member(
                            '',
                            '',
                            '',
                            avatar: Avatar(kind: kind),
                          ),
                          diameter: 72,
                          borderColor: selectedKind == kind
                              ? UnavoColors.gold
                              : Colors.transparent,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
