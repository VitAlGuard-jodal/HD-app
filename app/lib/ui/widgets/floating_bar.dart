import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../control_scale.dart';
import '../icons.dart';
import '../theme.dart';

/// Shared pill surface. Cars use it as a permanently visible dock.
class FloatingBar extends StatelessWidget {
  const FloatingBar({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    height: ControlScale.isCar(context) ? 96 : 64,
    // 테두리 1px 을 빼야 차량 버튼이 정확히 80dp 가 된다(96 - 7*2 - 1*2).
    padding: EdgeInsets.all(ControlScale.isCar(context) ? 7 : 3),
    decoration: BoxDecoration(
      color: const Color(0xEB171B1B),
      borderRadius: BorderRadius.circular(56),
      border: Border.all(color: const Color(0x667C8581)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x50000000),
          blurRadius: 20,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: child,
  );
}

class FloatingBarButton extends StatelessWidget {
  const FloatingBarButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.danger = false,
  });
  final String label;
  final String icon;
  final VoidCallback? onPressed;
  final bool selected;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final size = ControlScale.isCar(context) ? 80.0 : 48.0;
    final disabledColor = UnavoColors.text.withValues(alpha: 0.4);
    return Semantics(
      label: label,
      button: true,
      enabled: onPressed != null,
      selected: selected,
      onTap: onPressed,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: ExcludeSemantics(
          child: SizedBox.square(
            dimension: size,
            child: IconButton(
              onPressed: onPressed,
              style: IconButton.styleFrom(
                minimumSize: Size.square(size),
                padding: EdgeInsets.zero,
                backgroundColor: selected
                    ? UnavoColors.gold
                    : Colors.transparent,
                disabledBackgroundColor: UnavoColors.panel,
                foregroundColor: selected ? UnavoColors.ink : UnavoColors.text,
                disabledForegroundColor: disabledColor,
                side: onPressed == null
                    ? BorderSide(color: disabledColor)
                    : null,
                shape: const CircleBorder(),
              ),
              icon: UnavoIcon(
                icon,
                size: ControlScale.icon(context),
                color: onPressed == null
                    ? disabledColor
                    : selected
                    ? UnavoColors.ink
                    : danger
                    ? const Color(0xFFFF7D77)
                    : UnavoColors.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Scrollables consume this inset inside their content, so the pill never
/// obscures the last item and does not take height from the viewport.
class FloatingBarInset extends InheritedWidget {
  const FloatingBarInset({
    super.key,
    required this.bottom,
    required super.child,
  });
  final double bottom;
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FloatingBarInset>()?.bottom ??
      0;
  @override
  bool updateShouldNotify(FloatingBarInset oldWidget) =>
      bottom != oldWidget.bottom;
}

class FloatingBarOverlay extends StatefulWidget {
  const FloatingBarOverlay({
    super.key,
    required this.child,
    required this.bar,
    this.keepVisible = false,
    this.fixed = false,
    this.bottom = 8,
  });
  final Widget child;
  final Widget bar;
  final bool keepVisible;
  final bool fixed;
  final double bottom;
  @override
  State<FloatingBarOverlay> createState() => _FloatingBarOverlayState();
}

class _FloatingBarOverlayState extends State<FloatingBarOverlay> {
  Timer? _timer;
  bool _visible = true;
  bool _hideDue = false;
  int _pointers = 0;
  bool _focused = false;
  final Set<Object> _holds = {};
  ScrollDirection _direction = ScrollDirection.idle;
  bool get _pinned =>
      widget.fixed ||
      widget.keepVisible ||
      _pointers > 0 ||
      _focused ||
      _holds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(FloatingBarOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.keepVisible != oldWidget.keepVisible ||
        widget.fixed != oldWidget.fixed) {
      if (_pinned) {
        _visible = true;
      } else if (_hideDue) {
        _visible = false;
      }
      if (widget.fixed) _timer?.cancel();
      if (oldWidget.fixed && !widget.fixed) _arm();
    }
  }

  void _hold(Object owner, bool active) {
    if (!mounted) return;
    final changed = active ? _holds.add(owner) : _holds.remove(owner);
    if (!changed) return;
    if (_pinned) {
      setState(() => _visible = true);
    } else if (_hideDue) {
      setState(() => _visible = false);
    }
  }

  void _arm() {
    _timer?.cancel();
    _hideDue = false;
    if (widget.fixed || !_visible) return;
    _timer = Timer(const Duration(seconds: 3), () {
      _timer = null;
      _hideDue = true;
      if (mounted && !_pinned) setState(() => _visible = false);
    });
  }

  void _show() {
    setState(() => _visible = true);
    _arm();
  }

  void _toggle() {
    if (_pinned) {
      _show();
      return;
    }
    setState(() => _visible = !_visible);
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.axis == Axis.vertical &&
              notification.direction != ScrollDirection.idle &&
              notification.direction != _direction) {
            _direction = notification.direction;
            _show();
          }
          return false;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _toggle,
          child: FloatingBarInset(bottom: 80, child: widget.child),
        ),
      ),
      Positioned(
        left: 24,
        right: 24,
        bottom: widget.bottom,
        child: IgnorePointer(
          ignoring: !_visible,
          child: ExcludeSemantics(
            excluding: !_visible,
            child: AnimatedSlide(
              key: const ValueKey('floating-bar-slide'),
              offset: _visible ? Offset.zero : const Offset(0, 1.4),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: AnimatedOpacity(
                key: const ValueKey('floating-bar-opacity'),
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Focus(
                  onFocusChange: (focused) {
                    _focused =
                        focused &&
                        FocusManager.instance.highlightMode ==
                            FocusHighlightMode.traditional;
                    if (_focused)
                      _show();
                    else
                      _arm();
                  },
                  child: Listener(
                    onPointerDown: (_) {
                      _pointers++;
                      _show();
                    },
                    onPointerUp: (_) {
                      _pointers = (_pointers - 1).clamp(0, 100);
                      _arm();
                    },
                    onPointerCancel: (_) {
                      _pointers = (_pointers - 1).clamp(0, 100);
                      _arm();
                    },
                    child: widget.bar,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Errors inside any home tab keep its controls available until cleared.
class FloatingBarHold extends StatefulWidget {
  const FloatingBarHold({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;
  @override
  State<FloatingBarHold> createState() => _FloatingBarHoldState();
}

class _FloatingBarHoldState extends State<FloatingBarHold> {
  _FloatingBarOverlayState? _overlay;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _overlay = context.findAncestorStateOfType<_FloatingBarOverlayState>();
    _update();
  }

  @override
  void didUpdateWidget(FloatingBarHold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _update();
  }

  void _update() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _overlay?._hold(this, widget.active);
    });
  }

  @override
  void dispose() {
    final overlay = _overlay;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => overlay?._hold(this, false),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
