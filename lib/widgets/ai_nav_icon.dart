import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/ai/ai_activity.dart';
import 'app_icon.dart';

/// The side nav's AI icon: pulses gently while requests run in the
/// background, with a dot when new picks arrived while the tab was hidden.
class AiNavIcon extends StatefulWidget {
  const AiNavIcon({super.key, required this.color});

  final Color color;

  @override
  State<AiNavIcon> createState() => _AiNavIconState();
}

class _AiNavIconState extends State<AiNavIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.35,
  );

  @override
  void initState() {
    super.initState();
    AiActivity.running.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    AiActivity.running.removeListener(_sync);
    _pulse.dispose();
    super.dispose();
  }

  void _sync() {
    if (AiActivity.running.value > 0) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: FadeTransition(
              opacity: _pulse,
              child: AppIcon(Symbols.auto_awesome_rounded, fill: 1, size: 22, color: widget.color),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: AiActivity.unseen,
            builder: (context, unseen, _) => unseen == 0
                ? const SizedBox.shrink()
                : Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
