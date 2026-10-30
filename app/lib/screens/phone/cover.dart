import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/device_mode.dart';
import '../../ui/appearance.dart';
import '../../ui/backdrop.dart';
import '../../ui/theme.dart';

class CoverScreen extends StatefulWidget {
  const CoverScreen({super.key, required this.mode, required this.onContinue});
  final DeviceMode mode;
  final VoidCallback onContinue;
  @override
  State<CoverScreen> createState() => _CoverScreenState();
}

class _CoverScreenState extends State<CoverScreen> {
  Timer? _timer;
  bool _continued = false;
  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 1200), _continue);
  }

  void _continue() {
    if (!mounted || _continued) return;
    _continued = true;
    _timer?.cancel();
    widget.onContinue();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Semantics(
      button: true,
      label: '우나보 시작',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _continue,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Backdrop(
              mode: widget.mode,
              brightness: UnavoAppearance.of(context).resolve(context),
              cover: true,
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 300,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      UnavoColors.ink.withValues(alpha: .75),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 12, 26, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      '우나보',
                      style: UnavoType.display.copyWith(fontSize: 46),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '낯선 길도, 함께라면 우리의 길.',
                      style: TextStyle(
                        fontSize: 21,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        color: UnavoColors.text,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '같이 길을 개척한다.',
                      style: TextStyle(fontSize: 16, color: UnavoColors.text),
                    ),
                    const Align(
                      alignment: Alignment.centerRight,
                      child: HyundaiPlaceholder(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class HyundaiPlaceholder extends StatelessWidget {
  const HyundaiPlaceholder({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Container(
      width: 80,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border.all(color: UnavoColors.muted)),
      child: const Text(
        '현대 엠블럼\n자리표시',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, height: 1.2, color: UnavoColors.muted),
      ),
    ),
  );
}
