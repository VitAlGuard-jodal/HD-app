import 'package:flutter/material.dart';

import '../control_scale.dart';
import '../theme.dart';
import 'floating_bar.dart';

/// TextField's default Android toolbar embeds MaterialIcons.more_vert and
/// arrow_back. Keep editing actions, but render our own SVG-only menu.
class PanelEditMenu extends StatelessWidget {
  const PanelEditMenu({super.key, required this.editable, required this.car});
  final EditableTextState editable;
  final bool car;

  @override
  Widget build(BuildContext context) {
    if (SystemContextMenu.isSupportedByField(editable)) {
      return SystemContextMenu.editableText(editableTextState: editable);
    }
    final anchors = editable.contextMenuAnchors;
    final top = MediaQuery.paddingOf(context).top + 8;
    final adjustment = Offset(8, top);
    final strings = MaterialLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, top, 8, 8),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove: anchors.primaryAnchor - adjustment - const Offset(0, 8),
          anchorBelow:
              (anchors.secondaryAnchor ?? anchors.primaryAnchor) -
              adjustment +
              const Offset(0, 20),
        ),
        child: Material(
          color: UnavoColors.input,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: UnavoColors.line),
          ),
          child: ControlScale(
            car: car,
            child: Wrap(
              children: [
                for (final item in editable.contextMenuButtonItems)
                  FloatingBarButton(
                    icon: switch (item.type) {
                      ContextMenuButtonType.cut => 'cut',
                      ContextMenuButtonType.copy => 'copy',
                      ContextMenuButtonType.paste => 'paste',
                      ContextMenuButtonType.selectAll => 'selectall',
                      ContextMenuButtonType.delete => 'trash',
                      ContextMenuButtonType.lookUp ||
                      ContextMenuButtonType.searchWeb => 'search',
                      ContextMenuButtonType.share => 'arrow',
                      ContextMenuButtonType.liveTextInput => 'scan',
                      ContextMenuButtonType.custom => 'plus',
                    },
                    label:
                        item.label ??
                        switch (item.type) {
                          ContextMenuButtonType.cut => strings.cutButtonLabel,
                          ContextMenuButtonType.copy => strings.copyButtonLabel,
                          ContextMenuButtonType.paste =>
                            strings.pasteButtonLabel,
                          ContextMenuButtonType.selectAll =>
                            strings.selectAllButtonLabel,
                          ContextMenuButtonType.delete =>
                            strings.deleteButtonTooltip,
                          ContextMenuButtonType.lookUp =>
                            strings.lookUpButtonLabel,
                          ContextMenuButtonType.searchWeb =>
                            strings.searchWebButtonLabel,
                          ContextMenuButtonType.share =>
                            strings.shareButtonLabel,
                          ContextMenuButtonType.liveTextInput =>
                            strings.scanTextButtonLabel,
                          ContextMenuButtonType.custom => '편집',
                        },
                    onPressed: item.onPressed,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
