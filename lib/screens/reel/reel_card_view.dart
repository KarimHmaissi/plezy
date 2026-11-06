import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../services/reel/clip_player.dart';
import '../../services/device_performance.dart';
import '../../services/reel/reel_controller.dart';
import '../../theme/fork_motion.dart';
import '../../utils/content_utils.dart';
import '../../utils/formatters.dart';
import '../../utils/layout_constants.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/fitted_metadata_line.dart';
import '../../widgets/media_rating_badge.dart';
import '../../widgets/stat_chip.dart';
import '../../widgets/tv_spotlight_background.dart';

/// One card, in the app's own look. On the TV it is Home's spotlight (logo or
/// title, the metadata line with rating badges, the summary, the same scrims)
/// with the clip playing where the artwork would be: the artwork covers a
/// clip that is slow to start (held back briefly, so a quick one never shows
/// it) and stays for AI cards. The Reel adds only its labels, the why line
/// and the key hints underneath.
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
  });

  final ReelController controller;
  final ReelSlot slot;
  final bool tv;
  final VoidCallback onReplay;
  final VoidCallback? onWatch;
  final VoidCallback? onSave;
  final VoidCallback? onRemote;

  @override
  Widget build(BuildContext context) {
    switch (slot.kind) {
      case ReelSlotKind.loading:
        return const ReelCurtain();
      case ReelSlotKind.empty:
        return ReelMessage(
          icon: Symbols.movie_rounded,
          title: 'Nothing in ${controller.deck.name} yet',
          body: tv ? 'Press → for the next deck.' : 'Swipe sideways for the next deck.',
        );
      case ReelSlotKind.poolEnd:
        return ReelMessage(
          icon: Symbols.check_circle_rounded,
          title: controller.deck.id == 'for-you' ? "That's today's For You" : "That's all of ${controller.deck.name}",
          body: tv ? 'Press → for ${_nextDeckName()}.' : 'Swipe sideways for ${_nextDeckName()}.',
        );
      case ReelSlotKind.card:
        break;
    }
    final card = slot.card!;
    final isCurrent = identical(controller.current.card, card);
    final clips = controller.clips;
    return ListenableBuilder(
      listenable: Listenable.merge([clips.phase, clips.onScreen]),
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
          builder: (context, showArtwork) =>
              _tv(context, showArtwork: showArtwork, showInfo: !state.behind, held: state.held),
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
  static ({bool showingClip, bool behind, bool held, Duration artDelay}) clipState({
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
    );
  }

  Widget _tv(BuildContext context, {required bool showArtwork, required bool showInfo, required bool held}) {
    final scale = TvLayoutConstants.scaleOf(context);
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
          metadataTrailing: _clipKind(context, scale),
          contentBottom: extrasTop + 20 * scale,
          contentTop: 120 * scale,
        ),
        if (showInfo) ...[
          if (slot.item == null) _titleOnly(context, scale, bottom: extrasTop),
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
              ),
            ),
          ),
        ],
      ],
    );
  }

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

  /// Until the card's metadata lands: the title in the spotlight's style.
  Widget _titleOnly(BuildContext context, double scale, {required double bottom}) {
    final theme = Theme.of(context);
    return Positioned(
      left: TvLayoutConstants.horizontalInset,
      right: MediaQuery.sizeOf(context).width * 0.43,
      bottom: bottom,
      child: Text(
        slot.card!.title.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.displaySmall?.copyWith(
          color: theme.colorScheme.onSurface,
          fontSize: 54 * scale,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _nextDeckName() {
    final d = controller.decks;
    return d.length < 2 ? 'another deck' : d[(controller.deckIndex + 1) % d.length].name;
  }
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
/// length, year) for the phone card, where there is no spotlight.
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
    if (parts.isEmpty) return const SizedBox.shrink();
    return FittedMetadataLine(textStyle: style, parts: parts, ratingIconSize: fontSize, ratingSpacing: 4);
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
    final credit = slot.clip?.source.origin == ClipOrigin.animeTheme ? 'Theme via AnimeThemes' : null;
    // OK replays a held clip (ReelScreen's key map).
    final hints = '${held ? 'OK replay' : 'OK watch'}  ·  ↓ next  ·  → next deck  ·  hold OK for more';

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
    height += sectionGap * scale + _textHeight(context, hints, hintStyle, width);

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
      hints: hints,
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

  /// Replay's gap and button, the room a held clip adds.
  static const double replayHeight = 48;
  static const double heldExtra = sectionGap + replayHeight;

  final double scale;
  final double width;
  final bool held;
  final List<({IconData? icon, String label})> chips;
  final double chipFontSize;
  final String? why;
  final TextStyle? whyStyle;
  final String? credit;
  final TextStyle? creditStyle;
  final String hints;
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
  const _Extras({super.key, required this.layout, required this.resize, required this.onReplay});

  final _ExtrasLayout layout;

  /// How long Replay takes to open its room: the spotlight's glide, so the
  /// info block above moves up with it.
  final Duration resize;
  final VoidCallback onReplay;

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
              child: FilledButton.icon(
                // The Reel's own focus node keeps the keys; OK replays here.
                onPressed: onReplay,
                icon: const Icon(Symbols.replay_rounded),
                label: const Text('Replay'),
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
            Wrap(
              spacing: _ExtrasLayout.chipSpacing * s,
              runSpacing: _ExtrasLayout.chipRunSpacing * s,
              children: [for (final c in l.chips) StatChip(icon: c.icon, label: c.label, fontSize: l.chipFontSize)],
            ),
          ],
          if (l.why case final why?) ...[
            if (hasChips) SizedBox(height: _ExtrasLayout.whyGap * s),
            Text(why, maxLines: 2, overflow: TextOverflow.ellipsis, style: l.whyStyle),
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
          SizedBox(height: _ExtrasLayout.sectionGap * s),
          Text(l.hints, style: l.hintStyle),
        ],
      ),
    );
  }
}

/// An empty deck or the end of one.
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

/// The deck name for 1.5 s after a change, as an app chip.
class ReelDeckStrip extends StatelessWidget {
  const ReelDeckStrip({super.key, required this.controller});

  final ReelController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: controller.deckStrip,
    builder: (context, name, _) {
      final theme = Theme.of(context);
      return Positioned(
        top: 36,
        right: 40,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: name == null
              ? const SizedBox.shrink()
              : Container(
                  key: ValueKey(name),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Symbols.movie_rounded, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(name, style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
        ),
      );
    },
  );
}
