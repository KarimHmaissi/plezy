import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/device_performance.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/settings_service.dart';
import '../../theme/fork_motion.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/layout_constants.dart';
import '../../widgets/stat_chip.dart';
import '../../widgets/tv_spotlight_background.dart';
import '../../widgets/video_controls/widgets/transport_feedback_indicator.dart';
import 'reel_card_view.dart' show ReelDeckStrip;

/// The TV's lean-back state (V2-28).
///
/// - **Quiet:** after [quietAfter] of a clip playing with no key, the card's
///   summary, why line, chips and key hints fade and the scrim lightens, so
///   the clip has the screen. Any key brings them back ([poke]) and still
///   does what it does. A clip that is not playing (loading, paused, held,
///   failed) is never quiet.
/// - **Hints (CU-11):** the key hints show for the first [hintSessions]
///   sessions; after that only once [hintsAfter] has passed with no key, so
///   someone who has stopped on a card gets a nudge.
/// - **Transport:** a play or pause from a key or the phone pulses the
///   centre disc ([transport]).
class ReelLeanBack extends ChangeNotifier {
  ReelLeanBack({this.quietAfter = defaultQuietAfter, this.hintsAfter = defaultHintsAfter});

  static const Duration defaultQuietAfter = Duration(seconds: 6);
  static const Duration defaultHintsAfter = Duration(seconds: 10);

  /// Sessions that always show the hints.
  static const int hintSessions = 3;

  final Duration quietAfter;
  final Duration hintsAfter;

  int _session = 0;

  /// Between [begin] and [end]: the clocks run only while the Reel shows.
  bool _active = false;
  bool _playing = false;
  bool _quiet = false;
  bool _idle = false;
  Timer? _quietTimer;
  Timer? _idleTimer;

  /// The last accepted play or pause, for [TransportFeedbackIndicator].
  final ValueNotifier<ReelTransportPulse?> transport = ValueNotifier(null);

  /// The Reel's session number on this device (1 is the first); 0 before
  /// [begin], which shows the hints.
  int get session => _session;

  bool get quiet => _quiet;

  /// Whether the hint line takes its room: always in the first sessions
  /// (it fades in place when quiet, so nothing moves); later only while it
  /// shows.
  bool get hintsReserved => _session <= hintSessions || showHints;

  bool get showHints => !_quiet && (_session <= hintSessions || _idle);

  /// Counts a new visit on this device and returns its number (1 with no
  /// [settings]). The count stops one past [hintSessions]: past that, the
  /// number no longer matters.
  static int countSession(SettingsService? settings) {
    final session = (settings?.read(SettingsService.reelHintSessions) ?? 0) + 1;
    if (settings != null && session <= hintSessions + 1) {
      unawaited(settings.write(SettingsService.reelHintSessions, session));
    }
    return session;
  }

  /// The Reel came up as session [session] (a new visit) or, with null, as
  /// the same one (back from Watch).
  void begin({int? session}) {
    if (session != null) _session = session;
    _active = true;
    _quiet = false;
    _idle = false;
    _restartIdle();
    _restartQuiet();
    notifyListeners();
  }

  /// The Reel went away: nothing runs until the next [begin].
  void end() {
    _quietTimer?.cancel();
    _idleTimer?.cancel();
    _quietTimer = _idleTimer = null;
    _active = false;
    _playing = false;
    _quiet = false;
    _idle = false;
    notifyListeners();
  }

  /// A key (or a command from the phone): everything shows again and both
  /// clocks start over.
  void poke() {
    if (!_active) return;
    final changed = _quiet || _idle;
    _quiet = false;
    _idle = false;
    _restartIdle();
    _restartQuiet();
    if (changed) notifyListeners();
  }

  /// Whether the card's clip is playing (its picture up, not paused or
  /// held): only then can the card go quiet.
  set playing(bool value) {
    if (value == _playing) return;
    _playing = value;
    if (value) {
      _restartQuiet();
    } else {
      _quietTimer?.cancel();
      _quietTimer = null;
      if (_quiet) {
        _quiet = false;
        notifyListeners();
      }
    }
  }

  /// A play or pause was accepted: [paused] is where it left the clip.
  void pulse({required bool paused}) =>
      transport.value = ReelTransportPulse(paused: paused, count: (transport.value?.count ?? 0) + 1);

  void _restartQuiet() {
    _quietTimer?.cancel();
    _quietTimer = !_playing || !_active
        ? null
        : Timer(quietAfter, () {
            _quietTimer = null;
            if (!_playing || _quiet) return;
            _quiet = true;
            notifyListeners();
          });
  }

  void _restartIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(hintsAfter, () {
      _idleTimer = null;
      if (_idle) return;
      _idle = true;
      notifyListeners();
    });
  }

  /// How long the quiet change takes: the chrome leaves over the theme's
  /// slow step and comes back over its normal one (200 ms); none with
  /// animations off or on the reduced tier.
  static Duration fade(BuildContext context, {required bool quiet}) {
    if (ForkMotion.reduceMotion(context)) return Duration.zero;
    final t = Theme.of(context).extension<MonoTokens>();
    return DevicePerformance.reducedDuration(
      quiet ? (t?.slow ?? const Duration(milliseconds: 300)) : (t?.normal ?? const Duration(milliseconds: 200)),
    );
  }

  @override
  void dispose() {
    _quietTimer?.cancel();
    _idleTimer?.cancel();
    transport.dispose();
    super.dispose();
  }
}

@immutable
class ReelTransportPulse {
  const ReelTransportPulse({required this.paused, required this.count});

  final bool paused;
  final int count;
}

/// The TV's pause feedback (V2-28): the player's centre disc on every
/// accepted play or pause, and a "Paused" chip top left (opposite the deck
/// strip, inside the same overscan margin) while the card's clip is paused.
class ReelPauseFeedback extends StatelessWidget {
  const ReelPauseFeedback({super.key, required this.controller, required this.leanBack});

  final ReelController controller;
  final ReelLeanBack leanBack;

  /// Whether the clip on screen is the card's own and paused.
  static bool pausedOnCard(ReelController c) {
    final clip = c.current.clip?.source;
    return clip != null && c.clips.current == clip && c.clips.phase.value == ClipPhase.paused;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final scale = TvLayoutConstants.scaleOf(context);
    final reduce = ForkMotion.reduceMotion(context);
    final margin = ReelDeckStrip.overscan;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: ValueListenableBuilder<ReelTransportPulse?>(
            valueListenable: leanBack.transport,
            builder: (context, pulse, _) => pulse == null
                ? const SizedBox.shrink()
                : TransportFeedbackIndicator(
                    key: const ValueKey('reel-transport'),
                    icon: pulse.paused ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                    text: pulse.paused ? t.reel.card.paused : t.reel.card.playing,
                    pulse: pulse.count,
                  ),
          ),
        ),
        Positioned(
          top: size.height * margin,
          left: size.width * margin,
          child: ListenableBuilder(
            listenable: Listenable.merge([controller, controller.clips.phase]),
            builder: (context, _) => AnimatedSwitcher(
              duration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetIn),
              reverseDuration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetOut),
              transitionBuilder: (child, animation) => ForkMotion.riseTransition(animation, child),
              layoutBuilder: (currentChild, previousChildren) =>
                  Stack(alignment: Alignment.topLeft, children: [...previousChildren, ?currentChild]),
              child: pausedOnCard(controller)
                  ? StatChip(
                      key: const ValueKey('reel-paused'),
                      icon: Symbols.pause_rounded,
                      label: t.reel.card.paused,
                      fontSize: TvSpotlightBackground.metadataFontSize(scale, compact: true),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}
