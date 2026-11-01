import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/fork_motion.dart';
import '../utils/platform_detector.dart';

/// Fork: Plex-style touch feedback around anything tappable. On touch down
/// the child sinks slightly and dims; when a long press is recognised it
/// sinks a little further with a haptic tick; on release it springs back.
///
/// It only watches raw pointers (a [Listener]), so the child's own tap,
/// long-press and scroll gestures work exactly as before: a drag past the
/// touch slop (scrolling a row) cancels the effect. Off on TV, where focus
/// does this job.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.enabled = true, this.longPress = true, this.borderRadius});

  final Widget child;
  final bool enabled;

  /// Whether a held press gets the long-press tick and deeper sink.
  final bool longPress;

  /// Rounds the press highlight to match the child.
  final BorderRadius? borderRadius;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final AnimationController _scale = AnimationController(
    vsync: this,
    lowerBound: ForkMotion.longPressedScale,
    upperBound: 1,
    value: 1,
  );
  Timer? _longTimer;
  Offset? _down;
  bool _pressed = false;

  @override
  void dispose() {
    _longTimer?.cancel();
    _scale.dispose();
    super.dispose();
  }

  void _animateTo(double target, {required bool pressing}) {
    if (ForkMotion.reduceMotion(context)) return;
    _scale.animateTo(
      target,
      duration: pressing ? ForkMotion.pressIn : ForkMotion.release,
      curve: pressing ? ForkMotion.pressCurve : ForkMotion.releaseCurve,
    );
  }

  void _onDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryButton) return;
    _down = e.position;
    setState(() => _pressed = true);
    _animateTo(ForkMotion.pressedScale, pressing: true);
    _longTimer?.cancel();
    if (widget.longPress) {
      _longTimer = Timer(kLongPressTimeout, () {
        if (!mounted || !_pressed) return;
        ForkMotion.longPress();
        _animateTo(ForkMotion.longPressedScale, pressing: true);
      });
    }
  }

  void _onMove(PointerMoveEvent e) {
    final down = _down;
    if (down != null && (e.position - down).distance > kTouchSlop) _release();
  }

  void _release() {
    _longTimer?.cancel();
    _down = null;
    if (!_pressed) return;
    setState(() => _pressed = false);
    _animateTo(1, pressing: false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || PlatformDetector.isTV()) return widget.child;
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: ScaleTransition(
        scale: _scale,
        child: Stack(
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _pressed ? 1 : 0,
                  duration: _pressed ? ForkMotion.pressIn : ForkMotion.release,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
