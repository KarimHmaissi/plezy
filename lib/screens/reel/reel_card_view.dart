import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focus_theme.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../services/device_performance.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_art.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/reel/reel_library.dart';
import '../../services/settings_service.dart' show ReelOkAction;
import '../../theme/fork_motion.dart';
import '../../theme/fork_spacing.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/content_utils.dart';
import '../../utils/formatters.dart';
import '../../utils/layout_constants.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/fitted_metadata_line.dart';
import '../../widgets/media_progress_bar.dart';
import '../../widgets/media_rating_badge.dart';
import '../../widgets/stat_chip.dart';
import '../../widgets/tv_spotlight_background.dart';
import 'reel_decide_view.dart';
import 'reel_keys.dart' show reelHintLine;
import 'reel_lean_back.dart';
import 'reel_sheet.dart' show reelDeckIcon;

/// One card, in the app's own look. On the TV it is Home's spotlight (logo or
/// title, the metadata line with rating badges, the summary, the same scrims)
/// with the clip playing where the artwork would be: the artwork covers a
/// clip that is slow to start (held back briefly, so a quick one never shows
/// it) and stays for AI cards. The Reel adds only its labels, the why line
/// and the key hints underneath, and the clip's progress line. With
/// [leanBack], the card goes quiet while its clip plays (V2-28).
class ReelCardView extends StatelessWidget {
  const ReelCardView({
    super.key,
    required this.controller,
    required this.slot,
    required this.tv,
    required this.onReplay,
    this.onWatch,
    this.onSave,
    this.onRemote,
    this.leanBack,
    this.okAction = ReelOkAction.watch,
  });

  /// TV: decodes [card]'s spotlight art into the image cache exactly as
  /// this view will build it once the card is on screen (plan V2-13): the
  /// same server, path, screen-sized slot and, for a card with a [clip],
  /// the lighter thumbnail art (V2-05).
  static Future<void> precacheArt(BuildContext context, ReelCardData card, MediaItem item, {required bool clip}) async {
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(card.best.serverId));
    final provider = TvSpotlightBackground.artProviderFor(context, item, client, lightArt: clip);
    if (provider != null) await ReelArt.precache(provider, context);
  }

  final ReelController controller;
  final ReelSlot slot;
  final bool tv;
  final VoidCallback onReplay;
  final VoidCallback? onWatch;
  final VoidCallback? onSave;
  final VoidCallback? onRemote;

  /// TV: quiet mode and the hint rule (V2-28); null always shows everything.
  final ReelLeanBack? leanBack;

  /// TV: what OK does (D12, V2-50), which the hint line follows.
  final ReelOkAction okAction;

  @override
  Widget build(BuildContext context) {
    final content = _content(context);
    if (!tv) return content;
    // V2-27: loading, a failure, an empty deck or its end and the card fade
    // into each other. One card to the next keeps the same key, so it
    // changes in place (the spotlight runs its own cross-fade).
    final duration = stateFade(context);
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: duration,
      switchInCurve: ForkMotion.enterCurve,
      switchOutCurve: ForkMotion.exitCurve,
      layoutBuilder: (currentChild, previousChildren) =>
          Stack(fit: StackFit.expand, children: [...previousChildren, ?currentChild]),
      child: KeyedSubtree(key: ValueKey(stateKey(slot.kind, controller.deck.id)), child: content),
    );
  }

  /// What the TV's state fade switches on: every card is one state, the
  /// other kinds are one per deck.
  @visibleForTesting
  static String stateKey(ReelSlotKind kind, String deckId) =>
      kind == ReelSlotKind.card ? 'card' : '${kind.name}:$deckId';

  /// The state fade: [ForkMotion.sheetIn], none with animations off.
  static Duration stateFade(BuildContext context) =>
      ForkMotion.reduceMotion(context) ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetIn);

  Widget _content(BuildContext context) {
    switch (slot.kind) {
      case ReelSlotKind.loading:
        return tv ? const ReelTvSkeleton() : const ReelCurtain();
      case ReelSlotKind.failed:
        return ReelMessage(
          icon: Symbols.cloud_off_rounded,
          title: t.reel.card.failedTitle(deck: controller.deck.name),
          body: tv ? t.reel.card.failedBodyTv : t.reel.card.failedBodyTap,
          action: FilledButton.tonalIcon(
            onPressed: () => unawaited(controller.retryDeck()),
            icon: const Icon(Symbols.refresh_rounded),
            label: Text(t.reel.card.tryAgain),
          ),
        );
      case ReelSlotKind.empty:
        return ReelMessage(
          icon: reelDeckIcon(controller.deck.id),
          title: t.reel.card.emptyTitle(deck: controller.deck.name),
          body: tv ? t.reel.card.emptyBodyTv : t.reel.card.emptyBodyPhone,
        );
      case ReelSlotKind.poolEnd:
        return ReelMessage(
          icon: Symbols.check_circle_rounded,
          title: controller.deck.id == 'for-you'
              ? t.reel.card.endForYou
              : t.reel.card.endTitle(deck: controller.deck.name),
          body: tv ? t.reel.card.endBodyTv(deck: _nextDeckName()) : t.reel.card.endBodyPhone(deck: _nextDeckName()),
        );
      case ReelSlotKind.decide:
        return ReelDecideView(controller: controller, slot: slot, tv: tv, onWatch: onWatch);
      case ReelSlotKind.card:
        break;
    }
    final card = slot.card!;
    final isCurrent = identical(controller.current.card, card);
    final clips = controller.clips;
    return ListenableBuilder(
      listenable: Listenable.merge([clips.phase, clips.onScreen, ?leanBack]),
      builder: (context, _) {
        final state = ReelCardView.clipState(
          clip: slot.clip?.source,
          onScreen: clips.onScreen.value,
          phase: clips.phase.value,
          isCurrent: isCurrent,
        );
        return ReelArtCover(
          cover: !state.showingClip,
          delay: state.artDelay,
          builder: (context, showArtwork) => _tv(
            context,
            showArtwork: showArtwork,
            showInfo: !state.behind,
            held: state.held,
            progress: state.progress,
          ),
        );
      },
    );
  }

  /// What the TV card shows for its clip (V2-01).
  ///
  /// - [showingClip]: only this card's own clip, once its first frame is up
  ///   ([ClipPlayer.onScreen]), takes the artwork away; never the clip of
  ///   the card before it.
  /// - [behind]: the card before's clip is still on screen while this one
  ///   opens, so this card's text waits rather than drawing over it.
  /// - [artDelay]: a card with a clip holds its artwork back by
  ///   [ReelArtCover.clipGrace], so a preloaded start (about 170 ms) never
  ///   shows it; AI cards and failures show it at once.
  /// - [progress]: the card has a clip of its own, so its progress line
  ///   shows (at zero until the first frame, V2-28).
  static ({bool showingClip, bool behind, bool held, Duration artDelay, bool progress}) clipState({
    required ClipSource? clip,
    required ClipSource? onScreen,
    required ClipPhase phase,
    required bool isCurrent,
  }) {
    final failed = phase == ClipPhase.failed;
    final hasClip = isCurrent && clip != null && !failed;
    return (
      showingClip: hasClip && onScreen == clip,
      behind: hasClip && onScreen != null && onScreen != clip,
      held: isCurrent && phase == ClipPhase.held,
      artDelay: hasClip ? ReelArtCover.clipGrace : Duration.zero,
      progress: hasClip,
    );
  }

  Widget _tv(
    BuildContext context, {
    required bool showArtwork,
    required bool showInfo,
    required bool held,
    required bool progress,
  }) {
    final scale = TvLayoutConstants.scaleOf(context);
    // V2-28: lean back. Held and failed clips are never quiet (the lean-back
    // state only goes quiet while a clip plays).
    final lean = leanBack;
    final quiet = lean?.quiet ?? false;
    final showHints = lean?.showHints ?? true;
    final quietFade = ReelLeanBack.fade(context, quiet: quiet);
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(slot.card!.best.serverId));
    final screenWidth = MediaQuery.sizeOf(context).width;
    final right = screenWidth * 0.43;
    // V2-25: the extras sit on the bottom edge at their own height (no fixed
    // box), and the spotlight's info block starts just above them.
    final extras = _ExtrasLayout.of(
      context,
      controller: controller,
      slot: slot,
      held: held,
      okAction: okAction,
      hints: lean?.hintsReserved ?? true,
      width: screenWidth - TvLayoutConstants.horizontalInset - right,
    );
    final extrasBottom = 24 * scale;
    final extrasTop = extrasBottom + extras.height;
    final duration = _infoFade(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        TvSpotlightBackground(
          item: slot.item,
          client: client,
          showArtwork: showArtwork,
          showInfo: showInfo,
          artworkCurve: Easing.emphasizedDecelerate,
          // A clip card's art shows for a few hundred ms before the clip
          // covers it, so it decodes at the thumbnail cap (plan V2-05). AI
          // cards and cards still resolving keep the full backdrop.
          lightArt: slot.clip != null,
          onArtProvider: ReelArt.track,
          metadataTrailing: _clipKind(context, scale),
          contentBottom: extrasTop + 20 * scale,
          contentTop: 120 * scale,
          // V2-26: until the metadata lands, the title sits in the info
          // block's own logo slot over a skeleton, and the item's info
          // cross-fades in over it in place.
          pendingTitle: slot.card!.title.title,
          // The skeleton stays until the item lands or its read comes back
          // empty; the clip's answer no longer waits on it (V2-03).
          pendingSkeleton: !slot.itemMissed,
          quiet: quiet,
          quietFade: quietFade,
        ),
        if (showInfo) ...[
          Positioned(
            left: TvLayoutConstants.horizontalInset,
            right: right,
            bottom: extrasBottom,
            // The spotlight's own info cross-fade, so the two change together.
            child: AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              layoutBuilder: (currentChild, previousChildren) =>
                  Stack(alignment: Alignment.bottomLeft, children: [...previousChildren, ?currentChild]),
              child: _Extras(
                key: ValueKey('extras:${slot.card!.id}'),
                layout: extras,
                resize: duration,
                onReplay: onReplay,
                quiet: quiet,
                quietFade: quietFade,
                showHints: showHints,
                hintsFade: ReelLeanBack.fade(context, quiet: !showHints),
              ),
            ),
          ),
          Positioned(
            left: TvLayoutConstants.horizontalInset,
            right: right,
            bottom: _ExtrasLayout.progressBottom * scale,
            child: _ProgressLine(clips: clips, visible: progress, scale: scale),
          ),
        ],
      ],
    );
  }

  ClipPlayer get clips => controller.clips;

  /// The spotlight's 280 ms info cross-fade (none on the reduced tier or
  /// with animations turned off).
  static Duration _infoFade(BuildContext context) => ForkMotion.reduceMotion(context)
      ? Duration.zero
      : DevicePerformance.reducedDuration(const Duration(milliseconds: 280));

  /// The clip's kind (Trailer, Opening 1) as the last fact on the
  /// spotlight's metadata line, in the line's own style.
  Widget? _clipKind(BuildContext context, double scale) {
    final clip = slot.clip;
    if (clip == null) return null;
    final style = TvSpotlightBackground.metadataTextStyle(context);
    return Row(
      key: const ValueKey('reel-clip-kind'),
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(
          clip.source.origin == ClipOrigin.animeTheme ? Symbols.music_note_rounded : Symbols.movie_rounded,
          size: style.fontSize,
          fill: 1,
          color: style.color,
        ),
        SizedBox(width: 4 * scale),
        Text(clip.label, maxLines: 1, style: style),
      ],
    );
  }

  /// The deck → goes to: the next shown deck in the user's order.
  String _nextDeckName() => controller.nextDeck?.name ?? t.reel.card.anotherDeck;
}

/// Holds the spotlight's artwork back for [delay] after [cover] turns on, so
/// a clip whose first frame lands inside it never shows the art at all (the
/// art blink between cards). Turning [cover] off takes effect at once; the
/// spotlight itself runs the 320 ms reveal and the fade out.
class ReelArtCover extends StatefulWidget {
  const ReelArtCover({super.key, required this.cover, required this.delay, required this.builder});

  /// About a preloaded TV start (169 ms measured) plus a frame or two.
  static const Duration clipGrace = Duration(milliseconds: 200);

  final bool cover;
  final Duration delay;
  final Widget Function(BuildContext context, bool showArtwork) builder;

  @override
  State<ReelArtCover> createState() => _ReelArtCoverState();
}

class _ReelArtCoverState extends State<ReelArtCover> {
  late bool _show;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    _show = widget.cover && widget.delay <= Duration.zero;
    if (widget.cover && !_show) _hold();
  }

  @override
  void didUpdateWidget(ReelArtCover old) {
    super.didUpdateWidget(old);
    if (!widget.cover) {
      _wait?.cancel();
      _wait = null;
      _show = false;
    } else if (!_show && widget.delay <= Duration.zero) {
      _wait?.cancel();
      _wait = null;
      _show = true;
    } else if (!_show && _wait == null) {
      _hold();
    }
  }

  void _hold() {
    _wait = Timer(widget.delay, () {
      _wait = null;
      if (mounted && widget.cover) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _show);
}

/// The spotlight's metadata line (ratings with their badges, certificate,
/// length, year) for the phone card, where there is no spotlight. It is
/// always one line tall, even before anything is known.
class ReelMetadataLine extends StatelessWidget {
  const ReelMetadataLine({super.key, required this.item, this.year, required this.fontSize});

  final MediaItem? item;
  final int? year;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.1,
    );
    final m = item;
    final parts = <MetadataLinePart>[
      if (m != null && mediaRatingsFor(m).isNotEmpty) MetadataLineRatings(mediaRatingsFor(m), dropPriority: 4),
      if (m?.contentRating case final r?) MetadataLineText(formatContentRating(r), dropPriority: 2),
      if (m?.durationMs case final d?) MetadataLineText(formatDurationTextual(d), dropPriority: 1),
      if ((m?.year ?? year) case final y?) MetadataLineText('$y', dropPriority: 0),
    ];
    // V2-26: the line takes its height before the metadata lands, so the
    // title above it stays put when the facts arrive.
    return Stack(
      alignment: AlignmentDirectional.centerStart,
      children: [
        Text('\u00a0', maxLines: 1, style: style),
        if (parts.isNotEmpty)
          FittedMetadataLine(textStyle: style, parts: parts, ratingIconSize: fontSize, ratingSpacing: 4),
      ],
    );
  }
}

/// What the Reel adds under the spotlight on the TV, and its height before
/// layout (V2-25): its labels (deck chip, seen) sized in the TV scale, the
/// why line, the theme credit on its own line, Replay when the clip is held,
/// and the key hints. The block has no fixed height: [height] is what it
/// will take at [width], so the spotlight's info block can sit right above.
class _ExtrasLayout {
  _ExtrasLayout._({
    required this.scale,
    required this.width,
    required this.held,
    required this.chips,
    required this.chipFontSize,
    required this.why,
    required this.whyStyle,
    required this.credit,
    required this.creditStyle,
    required this.hints,
    required this.hintStyle,
    required this.height,
  });

  factory _ExtrasLayout.of(
    BuildContext context, {
    required ReelController controller,
    required ReelSlot slot,
    required bool held,
    required double width,
    ReelOkAction okAction = ReelOkAction.watch,
    bool hints = true,
  }) {
    final theme = Theme.of(context);
    final scale = TvLayoutConstants.scaleOf(context);
    final card = slot.card!;
    final badge = card.facts.seen.badge;
    final chips = <({IconData? icon, String label})>[
      if (card.chip case final chip?) (icon: null, label: chip),
      if (badge != null && controller.deck.keepsSeen) (icon: Symbols.check_rounded, label: badge),
    ];
    // The compact spotlight's metadata size, so the labels scale with it.
    final chipFontSize = TvSpotlightBackground.metadataFontSize(scale, compact: true);
    final whyStyle = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
      fontSize: 18 * scale,
    );
    final hintStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: hintSize * scale,
    );
    final creditStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: hintSize * scale,
    );
    final credit = slot.clip?.source.origin == ClipOrigin.animeTheme ? t.reel.card.themeCredit : null;
    // OK replays a held clip, else follows the OK pref (ReelScreen's key
    // map); a resume card's Watch plays the show's next episode (V2-40).
    final hintText = reelHintLine(held: held, okAction: okAction, resumeEpisode: slot.resumeEpisode);

    var height = 0.0;
    if (chips.isNotEmpty) height += _chipsHeight(context, chips, chipFontSize, scale, width);
    if (card.why case final why?) {
      if (height > 0) height += whyGap * scale;
      height += _textHeight(context, why, whyStyle, width, maxLines: 2);
    }
    if (credit != null) {
      if (height > 0) height += creditGap * scale;
      height += _textHeight(context, credit, creditStyle, width);
    }
    if (held) height += heldExtra * scale;
    // V2-28: past the first sessions the hint line takes no room until it
    // shows ([ReelLeanBack.hintsReserved]).
    if (hints) height += sectionGap * scale + _textHeight(context, hintText, hintStyle, width);

    return _ExtrasLayout._(
      scale: scale,
      width: width,
      held: held,
      chips: chips,
      chipFontSize: chipFontSize,
      why: card.why,
      whyStyle: whyStyle,
      credit: credit,
      creditStyle: creditStyle,
      hints: hints ? hintText : null,
      hintStyle: hintStyle,
      height: height,
    );
  }

  static const double whyGap = 8;
  static const double creditGap = 6;
  static const double sectionGap = 10;
  static const double hintSize = 14;
  static const double chipSpacing = 8;
  static const double chipRunSpacing = 6;

  /// Replay's gap and button, the room a held clip adds: the button and
  /// the focus ring around it ([replayRingGap] clear of the button, V2-28).
  static const double replayHeight = 56;
  static const double replayRingGap = 3;
  static const double heldExtra = sectionGap + replayHeight;

  /// The progress line (V2-28): its thickness and its gap to the bottom
  /// edge, under the hint line.
  static const double progressHeight = 3;
  static const double progressBottom = 10;

  final double scale;
  final double width;
  final bool held;
  final List<({IconData? icon, String label})> chips;
  final double chipFontSize;
  final String? why;
  final TextStyle? whyStyle;
  final String? credit;
  final TextStyle? creditStyle;

  /// Null when the hint line takes no room.
  final String? hints;
  final TextStyle? hintStyle;

  /// What the block takes at [width], Replay included when [held].
  final double height;

  /// The chips as [Wrap] lays them out at [width].
  static double _chipsHeight(
    BuildContext context,
    List<({IconData? icon, String label})> chips,
    double fontSize,
    double scale,
    double width,
  ) {
    var total = 0.0;
    var runWidth = 0.0;
    var runHeight = 0.0;
    var runs = 0;
    for (final c in chips) {
      final size = StatChip.sizeFor(context, c.label, icon: c.icon != null, fontSize: fontSize);
      if (runs > 0 && runWidth + chipSpacing * scale + size.width > width + 1e-10) {
        total += runHeight + chipRunSpacing * scale;
        runWidth = size.width;
        runHeight = size.height;
      } else {
        runWidth += (runs > 0 ? chipSpacing * scale : 0) + size.width;
        runHeight = runHeight > size.height ? runHeight : size.height;
      }
      runs++;
    }
    return total + runHeight;
  }

  static double _textHeight(BuildContext context, String text, TextStyle? style, double width, {int? maxLines}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }
}

class _Extras extends StatelessWidget {
  const _Extras({
    super.key,
    required this.layout,
    required this.resize,
    required this.onReplay,
    this.quiet = false,
    this.quietFade = Duration.zero,
    this.showHints = true,
    this.hintsFade = Duration.zero,
  });

  final _ExtrasLayout layout;

  /// How long Replay takes to open its room: the spotlight's glide, so the
  /// info block above moves up with it.
  final Duration resize;
  final VoidCallback onReplay;

  /// Lean back (V2-28): the chips and the why line fade out in place; the
  /// credit stays.
  final bool quiet;
  final Duration quietFade;

  /// Whether the hint line shows (it fades in place when it has room).
  final bool showHints;
  final Duration hintsFade;

  Widget _fading(bool visible, Duration over, Widget child) =>
      AnimatedOpacity(opacity: visible ? 1 : 0, duration: over, curve: Curves.easeOutCubic, child: child);

  @override
  Widget build(BuildContext context) {
    final l = layout;
    final s = l.scale;
    final hasChips = l.chips.isNotEmpty;
    final replay = l.held
        ? Padding(
            padding: EdgeInsets.only(top: _ExtrasLayout.sectionGap * s),
            child: SizedBox(
              height: _ExtrasLayout.replayHeight * s,
              // V2-28: drawn focused, as OK replays it (the Reel's own focus
              // node keeps the keys, so the button never takes focus).
              child: DecoratedBox(
                key: const ValueKey('reel-replay-focus'),
                decoration: FocusTheme.focusDecoration(context, isFocused: true, borderRadius: MonoTokens.radiusFull),
                child: Padding(
                  padding: EdgeInsets.all(FocusTheme.focusBorderWidth + _ExtrasLayout.replayRingGap * s),
                  child: FilledButton.icon(
                    onPressed: onReplay,
                    icon: const Icon(Symbols.replay_rounded),
                    label: Text(t.reel.card.replay),
                  ),
                ),
              ),
            ),
          )
        : const SizedBox.shrink();
    return SizedBox(
      width: l.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasChips) ...[
            _fading(
              !quiet,
              quietFade,
              Wrap(
                spacing: _ExtrasLayout.chipSpacing * s,
                runSpacing: _ExtrasLayout.chipRunSpacing * s,
                children: [for (final c in l.chips) StatChip(icon: c.icon, label: c.label, fontSize: l.chipFontSize)],
              ),
            ),
          ],
          if (l.why case final why?) ...[
            if (hasChips) SizedBox(height: _ExtrasLayout.whyGap * s),
            _fading(!quiet, quietFade, Text(why, maxLines: 2, overflow: TextOverflow.ellipsis, style: l.whyStyle)),
          ],
          if (l.credit case final credit?) ...[
            if (hasChips || l.why != null) SizedBox(height: _ExtrasLayout.creditGap * s),
            Text(credit, style: l.creditStyle),
          ],
          // AnimatedSize cannot run at zero length (it re-dirties itself
          // mid-layout), so reduced motion places Replay directly.
          if (resize == Duration.zero)
            replay
          else
            AnimatedSize(duration: resize, curve: Curves.easeOutCubic, alignment: Alignment.topLeft, child: replay),
          if (l.hints case final hints?) ...[
            SizedBox(height: _ExtrasLayout.sectionGap * s),
            _fading(showHints, hintsFade, Text(key: const ValueKey('reel-hints'), hints, style: l.hintStyle)),
          ],
        ],
      ),
    );
  }
}

/// The clip's progress (V2-28): a thin line under the extras, on the
/// app's own progress bar. The mono scheme maps `surfaceContainerHighest`
/// onto `surface`, so the track is set from `onSurface` here.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.clips, required this.visible, required this.scale});

  final ClipPlayer clips;
  final bool visible;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final height = _ExtrasLayout.progressHeight * scale;
    return AnimatedOpacity(
      key: const ValueKey('reel-progress'),
      opacity: visible ? 1 : 0,
      duration: ReelLeanBack.fade(context, quiet: !visible),
      curve: Curves.easeOutCubic,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: ValueListenableBuilder<ClipProgress>(
          valueListenable: clips.progress,
          builder: (context, p, _) => MediaProgressBar(
            viewOffset: visible ? p.position.inMilliseconds : 0,
            duration: visible ? p.length.inMilliseconds : 0,
            minHeight: height,
            backgroundColor: onSurface.withValues(alpha: 0.12),
          ),
        ),
      ),
    );
  }
}

/// An empty deck or the end of one, or the first-run intro (V2-55).
class ReelMessage extends StatelessWidget {
  const ReelMessage({super.key, required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Center(
        // A readable measure for a longer body (the intro) on a wide screen.
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          padding: EdgeInsets.symmetric(horizontal: ForkSpacing.of(context).edgeInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (action case final a?) ...[const SizedBox(height: 20), a],
            ],
          ),
        ),
      ),
    );
  }
}

/// TV loading (V2-27): Home's spotlight with nothing in it yet, and the info
/// block as a shimmering skeleton where the first card's will sit, instead
/// of a bare spinner.
class ReelTvSkeleton extends StatelessWidget {
  const ReelTvSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scale = TvLayoutConstants.scaleOf(context);
    return TvSpotlightBackground(
      key: const ValueKey('reel-tv-skeleton'),
      item: null,
      client: null,
      // A card's resting info block: the key hints under it, no extras.
      contentTop: 120 * scale,
      contentBottom: 80 * scale,
      pendingTitle: '',
    );
  }
}

/// Loading, as everywhere else in the app.
class ReelCurtain extends StatelessWidget {
  const ReelCurtain({super.key});

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: const Center(child: CircularProgressIndicator()),
  );
}

/// The deck strip (V2-27): ‹ previous · CURRENT · next › in a pill, top
/// right inside the TV's overscan-safe margin, sized in the TV scale. It
/// rises in with the app's sheet motion and stays until the new deck has
/// shown ([ReelController.defaultStripHold]).
class ReelDeckStrip extends StatelessWidget {
  const ReelDeckStrip({super.key, required this.controller});

  final ReelController controller;

  /// Android TV's overscan-safe margin: 5% of each edge
  /// (https://developer.android.com/design/ui/tv/guides/styles/layouts).
  static const double overscan = 0.05;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ReelDeckStripState?>(
    valueListenable: controller.deckStrip,
    builder: (context, strip, _) {
      final size = MediaQuery.sizeOf(context);
      final reduce = ForkMotion.reduceMotion(context);
      return Positioned(
        top: size.height * overscan,
        right: size.width * overscan,
        child: AnimatedSwitcher(
          duration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetIn),
          reverseDuration: reduce ? Duration.zero : DevicePerformance.reducedDuration(ForkMotion.sheetOut),
          transitionBuilder: (child, animation) => ForkMotion.riseTransition(animation, child),
          layoutBuilder: (currentChild, previousChildren) =>
              Stack(alignment: Alignment.topRight, children: [...previousChildren, ?currentChild]),
          child: strip == null
              ? const SizedBox.shrink()
              : _DeckStripPill(
                  key: ValueKey('reel-deck-strip:${strip.current.id}'),
                  strip: strip,
                  maxWidth: size.width * (1 - 2 * overscan),
                ),
        ),
      );
    },
  );
}

class _DeckStripPill extends StatelessWidget {
  const _DeckStripPill({super.key, required this.strip, required this.maxWidth});

  final ReelDeckStripState strip;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = TvLayoutConstants.scaleOf(context);
    final currentStyle = theme.textTheme.titleMedium?.copyWith(
      color: theme.colorScheme.onSurface,
      fontSize: (theme.textTheme.titleMedium?.fontSize ?? 16) * scale,
      fontWeight: FontWeight.w700,
    );
    final sideStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * scale,
    );
    final gap = SizedBox(width: 10 * scale);
    Widget side(String text) => Flexible(
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: sideStyle),
    );
    final previous = strip.previous, next = strip.next;
    return Semantics(
      liveRegion: true,
      label: strip.current.name,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 18 * scale, vertical: 8 * scale),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (previous != null) ...[side('‹  ${previous.name}'), gap, Text('·', style: sideStyle), gap],
                Icon(reelDeckIcon(strip.current.id), size: 20 * scale, color: theme.colorScheme.primary),
                SizedBox(width: 8 * scale),
                Flexible(
                  flex: 2,
                  child: Text(strip.current.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: currentStyle),
                ),
                if (next != null) ...[gap, Text('·', style: sideStyle), gap, side('${next.name}  ›')],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
