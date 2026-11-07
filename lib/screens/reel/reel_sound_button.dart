import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focus_theme.dart';
import '../../i18n/strings.g.dart';
import '../../services/device_performance.dart';
import '../../services/reel/reel_controller.dart';
import '../../theme/fork_motion.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/layout_constants.dart';
import '../../widgets/app_icon.dart';
import 'reel_card_view.dart' show ReelDeckStrip;
import 'reel_lean_back.dart';

/// TV: the Reel's sound button, bottom right inside the overscan margin.
/// Every TV visit starts muted (`ReelStartSound.muted`), so it is always
/// there to say so and to turn the sound on: "Sound on" while muted,
/// "Mute" once the sound is on (the phone's mute button and the sheet's
/// entry say the same).
///
/// It follows the controller's mute ([ReelController.muted]), so ≡, the
/// sheet, On TV mode and every visit that starts muted again change it with
/// no state of its own.
///
/// Focus is drawn, not taken (as the card's Replay): the Reel's focus node
/// keeps the keys, the card keeps OK, and Back on the card brings the
/// button in ([focused]); OK on it is [onToggle] (`ReelScreen._onKey`).
/// While muted it stays through quiet mode; with the sound on it fades with
/// the card's chrome unless it is focused. A screen reader hears each change
/// (V2-54) and can press it.
class ReelSoundButton extends StatelessWidget {
  const ReelSoundButton({
    super.key,
    required this.controller,
    required this.focused,
    required this.onToggle,
    this.leanBack,
  });

  final ReelController controller;

  /// Whether the button is the Reel's focus (drawn with the focus ring).
  final ValueListenable<bool> focused;

  /// Turns the sound on, or mutes it.
  final VoidCallback onToggle;

  /// Quiet mode (V2-28): the button fades with the card's chrome while the
  /// sound is on.
  final ReelLeanBack? leanBack;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final margin = ReelDeckStrip.overscan;
    final reduce = ForkMotion.reduceMotion(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          right: size.width * margin,
          bottom: size.height * margin,
          child: ListenableBuilder(
            listenable: Listenable.merge([controller, focused, ?leanBack]),
            builder: (context, _) {
              final muted = controller.muted;
              final isFocused = focused.value;
              final visible = muted || isFocused || !(leanBack?.quiet ?? false);
              final Widget pill = _Pill(
                key: ValueKey(muted ? 'reel-sound-off' : 'reel-sound-on'),
                icon: muted ? Symbols.volume_off_rounded : Symbols.volume_up_rounded,
                label: muted ? t.reel.card.soundOn : t.reel.card.mute,
                hint: isFocused
                    ? t.reel.card.soundButtonOk
                    : muted
                    ? t.reel.card.soundButtonKeys
                    : null,
                announce: muted ? t.reel.card.soundOffAnnounce : t.reel.card.soundOnAnnounce,
                focused: isFocused,
                onTap: onToggle,
              );
              return AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetOut),
                curve: Curves.easeOutCubic,
                child: AnimatedSwitcher(
                  duration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetIn),
                  reverseDuration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetOut),
                  switchInCurve: ForkMotion.enterCurve,
                  switchOutCurve: ForkMotion.exitCurve,
                  transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                  layoutBuilder: (currentChild, previousChildren) =>
                      Stack(alignment: Alignment.bottomRight, children: [...previousChildren, ?currentChild]),
                  child: pill,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The button's pill: the icon (the sound as it is), the action in bold
/// and the key that does it in the muted text colour, inside the focus ring
/// when focused. Sized from the TV scale so it reads from the sofa.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.icon,
    required this.label,
    required this.announce,
    required this.focused,
    required this.onTap,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String? hint;

  /// The sound as it is, which a screen reader says after the action, as a
  /// live region (the glyph ≡ reads badly).
  final String announce;
  final bool focused;
  final VoidCallback onTap;

  /// The ring's gap from the pill, as the card's Replay.
  static const double ringGap = 3;

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
      button: true,
      focused: focused,
      // What it does ("Sound on" / "Mute"), then the sound as it is now and
      // the keys for it.
      label: label,
      value: announce,
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: DecoratedBox(
            key: focused ? const ValueKey('reel-sound-focus') : null,
            decoration: FocusTheme.focusDecoration(context, isFocused: focused, borderRadius: MonoTokens.radiusFull),
            child: Padding(
              padding: EdgeInsets.all(FocusTheme.focusBorderWidth + ringGap * scale),
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
          ),
        ),
      ),
    );
  }
}
