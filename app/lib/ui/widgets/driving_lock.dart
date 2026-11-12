import 'package:flutter/material.dart';

import '../../core/device_mode.dart';
import '../../core/driving_state.dart';
import '../icons.dart';
import '../theme.dart';

/// MaterialApp.builder에서 Navigator 전체를 감싸 다이얼로그도 잠근다.
class DrivingLockOverlay extends StatefulWidget {
  const DrivingLockOverlay({
    super.key,
    required this.mode,
    required this.driving,
    required this.child,
  });

  final DeviceMode mode;
  final DrivingState driving;
  final Widget child;

  @override
  State<DrivingLockOverlay> createState() => _DrivingLockOverlayState();
}

class _DrivingLockOverlayState extends State<DrivingLockOverlay> {
  bool _wasRestricted = false;

  @override
  Widget build(BuildContext context) {
    if (widget.mode != DeviceMode.car) {
      _wasRestricted = false;
      return widget.child;
    }
    return ListenableBuilder(
      listenable: widget.driving,
      child: widget.child,
      builder: (context, child) {
        final restricted = widget.driving.restricted;
        if (restricted && !_wasRestricted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                widget.mode == DeviceMode.car &&
                widget.driving.restricted) {
              FocusManager.instance.primaryFocus?.unfocus();
            }
          });
        }
        _wasRestricted = restricted;
        return AbsorbPointer(
          absorbing: restricted,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(excluding: restricted, child: child!),
              if (restricted)
                Positioned.fill(
                  // MaterialApp.builder 는 Scaffold 바깥이라 Material 없이는
                  // Text 가 기본 밑줄(노란 이중선)로 그려진다.
                  child: Material(
                    key: const ValueKey('driving-lock-scrim'),
                    color: UnavoColors.ink.withValues(alpha: .9),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Semantics(
                            liveRegion: true,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const UnavoIcon(
                                  'steering-wheel',
                                  size: 96,
                                  color: UnavoColors.gold,
                                ),
                                const SizedBox(height: 16),
                                const UnavoIcon('lock', size: 32),
                                const SizedBox(height: 20),
                                Text(
                                  '주행 중에는 조작할 수 없습니다',
                                  maxLines: 1,
                                  softWrap: false,
                                  style: UnavoType.title.copyWith(fontSize: 26),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
