import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/device_performance.dart';
import '../../services/reel/reel_controller.dart';
import '../../theme/fork_motion.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/layout_constants.dart';
import '../../widgets/app_icon.dart';
import 'reel_card_view.dart' show ReelDeckStrip;

/// TV: the Reel's sound at a glance. Every TV visit starts muted
/// (`ReelStartSound.muted`), so while the card is muted a badge sits bottom
/// right, inside the overscan margin, saying so and which key brings the
/// sound in: "Sound off · press ≡ for sound". It stays through quiet mode
/// (V2-28), on every card, until the sound is on. When the viewer turns the
/// sound on ([soundOn]) it says "Sound on" for [confirmFor], then goes.
/// A screen reader hears each change (V2-54).
///
/// It takes no focus: OK stays Watch (D12), and ≡ is the key.
class ReelSoundBadge extends StatefulWidget {
  const ReelSoundBadge({super.key, required this.controller, required this.soundOn});

  final ReelController controller;

  /// Bumped each time the viewer turns the sound on.
  final ValueListenable<int> soundOn;

  /// How long "Sound on" shows before the badge goes.
  static const Duration confirmFor = Duration(seconds: 2);

  @override
  State<ReelSoundBadge> createState() => _ReelSoundBadgeState();
}

class _ReelSoundBadgeState extends State<ReelSoundBadge> {
  bool _confirming = false;
  Timer? _confirm;

  /// The mute as last seen, so only muting again (not the moment before the
  /// sound comes on) ends the confirmation.
  late bool _wasMuted = widget.controller.clips.muted;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    widget.soundOn.addListener(_onSoundOn);
  }

  @override
  void didUpdateWidget(ReelSoundBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
    if (!identical(oldWidget.soundOn, widget.soundOn)) {
      oldWidget.soundOn.removeListener(_onSoundOn);
      widget.soundOn.addListener(_onSoundOn);
    }
  }

  @override
  void dispose() {
    _confirm?.cancel();
    widget.controller.removeListener(_onChanged);
    widget.soundOn.removeListener(_onSoundOn);
    super.dispose();
  }

  /// Muted again (the sheet, the phone): the confirmation gives way.
  void _onChanged() {
    if (!mounted) return;
    final muted = widget.controller.clips.muted;
    if (muted && !_wasMuted && _confirming) {
      _confirm?.cancel();
      _confirming = false;
    }
    _wasMuted = muted;
    setState(() {});
  }

  void _onSoundOn() {
    if (!mounted) return;
    _confirm?.cancel();
    _confirm = Timer(ReelSoundBadge.confirmFor, () {
      if (mounted) setState(() => _confirming = false);
    });
    setState(() => _confirming = true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = widget.controller.clips.muted;
    final size = MediaQuery.sizeOf(context);
    final margin = ReelDeckStrip.overscan;
    final reduce = ForkMotion.reduceMotion(context);
    final Widget badge = muted
        ? _Badge(
            key: const ValueKey('reel-sound-off'),
            icon: Symbols.volume_off_rounded,
            label: t.reel.card.soundOffBadge,
            hint: t.reel.card.soundOffKey,
            announce: t.reel.card.soundOffAnnounce,
          )
        : _confirming
        ? _Badge(
            key: const ValueKey('reel-sound-on'),
            icon: Symbols.volume_up_rounded,
            label: t.reel.card.soundOn,
            announce: t.reel.card.soundOnAnnounce,
          )
        : const SizedBox.shrink(key: ValueKey('reel-sound-none'));
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          right: size.width * margin,
          bottom: size.height * margin,
          child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetIn),
              reverseDuration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetOut),
              switchInCurve: ForkMotion.enterCurve,
              switchOutCurve: ForkMotion.exitCurve,
              transitionBuilder: (child, animation) => ForkMotion.riseTransition(animation, child),
              layoutBuilder: (currentChild, previousChildren) =>
                  Stack(alignment: Alignment.bottomRight, children: [...previousChildren, ?currentChild]),
              child: badge,
            ),
          ),
        ),
      ],
    );
  }
}

/// The badge's pill: the icon, the state in bold and, while muted, the key
/// in the muted text colour. Sized from the TV scale so it reads from the
/// sofa.
class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.icon, required this.label, required this.announce, this.hint});

  final IconData icon;
  final String label;
  final String? hint;

  /// What a screen reader says, as a live region (the glyph ≡ reads badly).
  final String announce;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<MonoTokens>();
    final scheme = theme.colorScheme;
    final scale = TvLayoutConstants.scaleOf(context);
    final text = tokens?.text ?? scheme.onSurface;
    final muted = tokens?.textMuted ?? scheme.onSurfaceVariant;
    final fontSize = 20 * scale;
    return Semantics(
      container: true,
      liveRegion: true,
      label: announce,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (tokens?.surface ?? scheme.surface).withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(MonoTokens.radiusFull),
            border: Border.all(color: tokens?.outline ?? scheme.outlineVariant),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 10 * scale),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(icon, size: 26 * scale, fill: 1, color: text),
                SizedBox(width: 10 * scale),
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(color: text, fontSize: fontSize, fontWeight: FontWeight.w700),
                ),
                if (hint case final hint?)
                  Text(
                    '  ·  $hint',
                    maxLines: 1,
                    style: TextStyle(color: muted, fontSize: fontSize, fontWeight: FontWeight.w500),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
