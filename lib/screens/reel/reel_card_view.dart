import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_controller.dart';
import '../../utils/content_utils.dart';
import '../../utils/formatters.dart';
import '../../utils/layout_constants.dart';
import '../../utils/provider_extensions.dart';
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
    final extrasHeight = 150 * scale;
    return Stack(
      fit: StackFit.expand,
      children: [
        TvSpotlightBackground(
          item: slot.item,
          client: client,
          showArtwork: showArtwork,
          showInfo: showInfo,
          artworkCurve: Easing.emphasizedDecelerate,
          contentBottom: extrasHeight + 44 * scale,
          contentTop: 120 * scale,
        ),
        if (showInfo) ...[
          if (slot.item == null) _titleOnly(context, scale, bottom: extrasHeight + 24 * scale),
          Positioned(
            left: TvLayoutConstants.horizontalInset,
            right: MediaQuery.sizeOf(context).width * 0.43,
            bottom: 24 * scale,
            height: extrasHeight,
            child: Align(
              alignment: Alignment.topLeft,
              child: _Extras(controller: controller, slot: slot, held: held, tv: true, onReplay: onReplay),
            ),
          ),
        ],
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

/// What the Reel adds under the title block: its labels (deck chip, seen,
/// clip kind), the why line, the theme credit, Replay, and the TV key hints.
class _Extras extends StatelessWidget {
  const _Extras({
    required this.controller,
    required this.slot,
    required this.held,
    required this.tv,
    required this.onReplay,
  });

  final ReelController controller;
  final ReelSlot slot;
  final bool held;
  final bool tv;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = tv ? TvLayoutConstants.scaleOf(context) : 1.0;
    final card = slot.card!;
    final badge = card.facts.seen.badge;
    final bodySize = (tv ? 18 : 15) * scale;
    return Column(
      key: ValueKey('extras:${card.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (slot.clip != null)
              StatChip(
                icon: slot.clip!.source.origin == ClipOrigin.animeTheme
                    ? Symbols.music_note_rounded
                    : Symbols.movie_rounded,
                label: slot.clip!.label,
              ),
            if (card.chip case final chip?) StatChip(label: chip),
            if (badge != null && controller.deck.keepsSeen) StatChip(icon: Symbols.check_rounded, label: badge),
            if (slot.clip?.source.origin == ClipOrigin.animeTheme)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Theme via AnimeThemes',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
        if (card.why case final why?) ...[
          SizedBox(height: 8 * scale),
          Text(
            why,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
              fontSize: bodySize,
            ),
          ),
        ],
        if (held) ...[
          SizedBox(height: 10 * scale),
          FilledButton.icon(
            // The Reel's own focus node keeps the keys; OK replays here.
            onPressed: onReplay,
            icon: const Icon(Symbols.replay_rounded),
            label: const Text('Replay'),
          ),
        ],
        if (tv) ...[
          SizedBox(height: 10 * scale),
          Text(
            // OK replays a held clip (ReelScreen's key map).
            '${held ? 'OK replay' : 'OK watch'}  ·  ↓ next  ·  → next deck  ·  hold OK for more',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 14 * scale,
            ),
          ),
        ],
      ],
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
