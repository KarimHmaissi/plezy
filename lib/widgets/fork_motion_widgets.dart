import 'package:flutter/material.dart';

import '../theme/fork_motion.dart';

/// Fork: fades [child] in with a short rise the first time it's built,
/// [index] steps of [ForkMotion.staggerStep] after its siblings, so a row
/// of new things arrives one after another instead of all at once. Give it
/// a key that changes when the content is new (a new Tonight, a new
/// answer) to play again. Nothing moves when the system asks for less
/// motion.
class ForkEntrance extends StatefulWidget {
  const ForkEntrance({super.key, required this.child, this.index = 0, this.play = true});

  final Widget child;
  final int index;

  /// When false as it's first built, [child] is simply there; the tree
  /// stays the same either way, so turning it off later keeps state.
  final bool play;

  @override
  State<ForkEntrance> createState() => _ForkEntranceState();
}

class _ForkEntranceState extends State<ForkEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: ForkMotion.sheetIn);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.play || ForkMotion.reduceMotion(context)) {
      _controller.value = 1;
      return;
    }
    final delay = ForkMotion.staggerStep * widget.index.clamp(0, ForkMotion.staggerMax);
    Future<void>.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ForkMotion.riseTransition(_controller, widget.child);
}

/// Fork: a soft light sweeping across [child] while [active], for things
/// that are being worked on (a request's tile). Still when inactive or when
/// the system asks for less motion.
class ForkShimmer extends StatefulWidget {
  const ForkShimmer({super.key, required this.child, this.active = true});

  final Widget child;
  final bool active;

  @override
  State<ForkShimmer> createState() => _ForkShimmerState();
}

class _ForkShimmerState extends State<ForkShimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ForkShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final run = widget.active && !ForkMotion.reduceMotion(context);
    if (run && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!run && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // One tree either way, so the child keeps its state when work ends.
    final on = widget.active && !ForkMotion.reduceMotion(context);
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        // The band travels from off the left edge to off the right.
        final x = -1.5 + 3 * _controller.value;
        final light = Theme.of(context).colorScheme.onSurface;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            child!,
            if (on)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(x - 0.6, -0.3),
                        end: Alignment(x + 0.6, 0.3),
                        colors: [light.withValues(alpha: 0), light.withValues(alpha: 0.07), light.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
