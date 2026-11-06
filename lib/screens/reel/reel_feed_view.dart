import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../media/ids.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/feed_players.dart';
import '../../services/reel/reel_controller.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/stat_chip.dart';
import 'reel_card_view.dart';

/// The phone Reel, a feed you thumb through: each card plays in its own
/// page (the clip is drawn into the page, so it slides with your thumb), and
/// the cards around it are already open and parked on their first frame
/// ([ReelFeedPlayers]). Swipe right to hide everything and just watch; swipe
/// left to bring it back. The deck is picked from the button at the top.
class ReelFeedView extends StatefulWidget {
  const ReelFeedView({
    super.key,
    required this.controller,
    required this.players,
    required this.onWatch,
    required this.watchOnTv,
    required this.onSheet,
    required this.onDecks,
    this.onRemote,
  });

  final ReelController controller;
  final ReelFeedPlayers players;

  /// Watch: on the TV when [watchOnTv], otherwise here.
  final VoidCallback onWatch;
  final bool watchOnTv;
  final VoidCallback onSheet;
  final VoidCallback onDecks;

  /// On TV mode, offered while this phone is a connected remote.
  final VoidCallback? onRemote;

  @override
  State<ReelFeedView> createState() => _ReelFeedViewState();
}

class _ReelFeedViewState extends State<ReelFeedView> {
  late final PageController _pages = PageController(initialPage: widget.controller.index);
  String? _deck;
  bool _immersive = false;
  bool _burst = false;

  ReelController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _deck = _c.deck.id;
    _c.addListener(_onController);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(ReelFeedView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
    _pages.dispose();
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    // A new deck starts at its own cursor; a card dropped (Not for me) or
    // a step from the TV moves the page to match.
    if (_deck != _c.deck.id) {
      _deck = _c.deck.id;
      if (_pages.hasClients) _pages.jumpToPage(_c.index);
    } else if (_pages.hasClients && !_pages.position.isScrollingNotifier.value) {
      final page = _pages.page?.round();
      if (page != null && page != _c.index) _pages.jumpToPage(_c.index);
    }
    _sync();
    setState(() {});
  }

  /// The card on screen, the next two, then the one behind.
  void _sync() {
    // Hidden, paused or handing over to real playback: nothing plays.
    if (!_c.active) return;
    final i = _c.index;
    final window = <FeedClip>[
      for (final j in [i, i + 1, i + 2, i - 1])
        if (j >= 0)
          if (_c.slotAt(j) case ReelSlot(card: final card?, clip: final clip?))
            if (Uri.tryParse(clip.source.uri) case final uri?) (id: card.id, uri: uri),
    ];
    widget.players.sync(current: _c.current.card?.id, window: window, memoryLevel: _c.memoryLevel);
  }

  void _save() {
    HapticFeedback.mediumImpact();
    setState(() => _burst = true);
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _burst = false);
    });
    unawaited(_c.save());
  }

  @override
  Widget build(BuildContext context) {
    final list = _c.cards;
    final count = list == null ? 1 : list.length + 1;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pages,
            scrollDirection: Axis.vertical,
            itemCount: count,
            onPageChanged: (i) => unawaited(_c.step(i - _c.index)),
            itemBuilder: (context, i) => _page(_c.slotAt(i)),
          ),
          _TopBar(
            hidden: _immersive,
            deckName: _c.deck.name,
            muted: widget.players.muted,
            onDecks: widget.onDecks,
            onMute: () => unawaited(widget.players.setMuted(!widget.players.muted)),
            onRemote: widget.onRemote,
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _burst ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Center(
                child: AnimatedScale(
                  scale: _burst ? 1 : 0.6,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    Symbols.bookmark_added_rounded,
                    fill: 1,
                    size: 96,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _page(ReelSlot slot) {
    switch (slot.kind) {
      case ReelSlotKind.loading:
        return const ReelCurtain();
      case ReelSlotKind.empty:
        return ReelMessage(
          icon: Symbols.movie_rounded,
          title: 'Nothing in ${_c.deck.name} yet',
          body: 'Pick another deck to keep going.',
          action: FilledButton.tonalIcon(
            onPressed: widget.onDecks,
            icon: const Icon(Symbols.video_library_rounded),
            label: const Text('Decks'),
          ),
        );
      case ReelSlotKind.poolEnd:
        return ReelMessage(
          icon: Symbols.check_circle_rounded,
          title: _c.deck.id == 'for-you' ? "That's today's For You" : "That's all of ${_c.deck.name}",
          body: 'Pick another deck to keep going.',
          action: FilledButton.tonalIcon(
            onPressed: widget.onDecks,
            icon: const Icon(Symbols.video_library_rounded),
            label: const Text('Decks'),
          ),
        );
      case ReelSlotKind.card:
        break;
    }
    final card = slot.card!;
    final isCurrent = card.id == _c.current.card?.id;
    // Sideways anywhere on the page hides or shows the controls. Tap,
    // double-tap and long-press live on the picture only, so the buttons
    // answer at once instead of waiting out the double-tap window.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() < 250) return;
        HapticFeedback.selectionClick();
        setState(() => _immersive = v > 0);
      },
      child: ListenableBuilder(
        listenable: widget.players,
        builder: (context, _) {
          final video = widget.players.videoFor(card.id);
          final paused = isCurrent && widget.players.paused;
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: isCurrent ? () => unawaited(widget.players.togglePause()) : null,
                onDoubleTap: isCurrent ? _save : null,
                onLongPress: isCurrent ? widget.onSheet : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _Backdrop(slot: slot, dim: _immersive ? 0.9 : 0.55),
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      alignment: _immersive ? Alignment.center : const Alignment(0, -0.16),
                      child: _Picture(slot: slot, video: video, paused: paused),
                    ),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: _immersive ? 0 : 1,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: _immersive,
                  child: _Info(
                    controller: _c,
                    slot: slot,
                    watchOnTv: widget.watchOnTv,
                    onWatch: widget.onWatch,
                    onDetails: () => unawaited(_c.openDetails()),
                    onSave: _save,
                    onMore: widget.onSheet,
                  ),
                ),
              ),
              if (video != null && isCurrent) _Progress(video: video),
            ],
          );
        },
      ),
    );
  }
}

/// The card's own art, full-bleed and dimmed, behind the picture.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.slot, required this.dim});

  final ReelSlot slot;
  final double dim;

  @override
  Widget build(BuildContext context) {
    final item = slot.item;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Ambient light from the card's own art: fetched tiny and scaled up,
        // it reads as a soft blur without a blur pass on every scroll frame.
        if (item != null)
          OptimizedMediaImage(
            client: context.tryGetMediaClientWithFallback(serverIdOrNull(slot.card!.best.serverId)),
            imagePath: item.artPath ?? item.thumbPath,
            width: 36,
            height: 64,
            fit: BoxFit.cover,
            imageType: ImageType.art,
            placeholder: (_, _) => const SizedBox.shrink(),
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          color: Colors.black.withValues(alpha: dim),
        ),
      ],
    );
  }
}

/// The clip, at its own shape, over the card's art in the same frame: the
/// art is the still until the first frame, and stays for a card with no clip.
class _Picture extends StatelessWidget {
  const _Picture({required this.slot, required this.video, required this.paused});

  final ReelSlot slot;
  final FeedVideo? video;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final v = video;
    final aspect = v?.aspectRatio ?? 16 / 9;
    final item = slot.item;
    return AspectRatio(
      aspectRatio: aspect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item != null)
            OptimizedMediaImage(
              client: context.tryGetMediaClientWithFallback(serverIdOrNull(slot.card!.best.serverId)),
              imagePath: item.artPath ?? item.thumbPath,
              width: 960,
              height: 540,
              fit: BoxFit.cover,
              imageType: ImageType.art,
              placeholder: (_, _) => const ColoredBox(color: Colors.black26),
              errorWidget: (_, _, _) => const ColoredBox(color: Colors.black26),
            ),
          AnimatedOpacity(
            opacity: v == null ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            child: v == null ? const SizedBox.shrink() : v.view(),
          ),
          AnimatedOpacity(
            opacity: paused ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Center(
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Icon(
                    Symbols.play_arrow_rounded,
                    fill: 1,
                    size: 44,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The deck button, mute and On TV, over a soft top scrim.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.hidden,
    required this.deckName,
    required this.muted,
    required this.onDecks,
    required this.onMute,
    this.onRemote,
  });

  final bool hidden;
  final String deckName;
  final bool muted;
  final VoidCallback onDecks;
  final VoidCallback onMute;
  final VoidCallback? onRemote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        child: IgnorePointer(
          ignoring: hidden,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.55), Colors.transparent],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(8, top + 4, 8, 20),
              child: Row(
                children: [
                  TextButton(
                    onPressed: onDecks,
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.onSurface),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.55),
                          child: Text(
                            deckName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Symbols.keyboard_arrow_down_rounded),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (onRemote != null)
                    IconButton(
                      tooltip: 'On TV',
                      onPressed: onRemote,
                      icon: const Icon(Symbols.settings_remote_rounded),
                    ),
                  IconButton(
                    tooltip: muted ? 'Sound on' : 'Mute',
                    onPressed: onMute,
                    icon: Icon(muted ? Symbols.volume_off_rounded : Symbols.volume_up_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Title, facts, why, and the controls: Watch and Details first.
class _Info extends StatelessWidget {
  const _Info({
    required this.controller,
    required this.slot,
    required this.watchOnTv,
    required this.onWatch,
    required this.onDetails,
    required this.onSave,
    required this.onMore,
  });

  final ReelController controller;
  final ReelSlot slot;
  final bool watchOnTv;
  final VoidCallback onWatch;
  final VoidCallback onDetails;
  final VoidCallback onSave;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = slot.card!;
    final clip = slot.clip;
    return Align(
      alignment: Alignment.bottomCenter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6), Colors.black.withValues(alpha: 0.85)],
            stops: const [0, 0.35, 1],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 48, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (clip != null || card.chip != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (clip != null)
                        StatChip(
                          icon: clip.source.origin == ClipOrigin.animeTheme
                              ? Symbols.music_note_rounded
                              : Symbols.movie_rounded,
                          label: clip.label,
                        ),
                      if (card.chip case final chip?) StatChip(label: chip),
                    ],
                  ),
                ),
              Text(
                card.title.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
              ),
              const SizedBox(height: 6),
              ReelMetadataLine(item: slot.item, year: card.best.year, fontSize: 14),
              if (card.why case final why?) ...[
                const SizedBox(height: 8),
                Text(
                  why,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
              if (clip?.source.origin == ClipOrigin.animeTheme) ...[
                const SizedBox(height: 4),
                Text(
                  'Theme via AnimeThemes',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onWatch,
                      icon: Icon(watchOnTv ? Symbols.tv_rounded : Symbols.play_arrow_rounded, fill: 1),
                      label: Text(watchOnTv ? 'Watch on TV' : 'Watch', maxLines: 1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onDetails,
                      icon: const Icon(Symbols.info_rounded),
                      label: const Text('Details', maxLines: 1),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(tooltip: 'Save', onPressed: onSave, icon: const Icon(Symbols.bookmark_add_rounded)),
                  IconButton(tooltip: 'More', onPressed: onMore, icon: const Icon(Symbols.more_vert_rounded)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A hairline of how far the clip is, along the page's foot.
class _Progress extends StatelessWidget {
  const _Progress({required this.video});

  final FeedVideo video;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    height: 2,
    child: ListenableBuilder(
      listenable: video,
      builder: (context, _) {
        final total = video.duration.inMilliseconds;
        final at = total <= 0 ? 0.0 : (video.position.inMilliseconds / total).clamp(0.0, 1.0);
        return LinearProgressIndicator(
          value: at,
          minHeight: 2,
          backgroundColor: Colors.white.withValues(alpha: 0.12),
          color: Theme.of(context).colorScheme.primary,
        );
      },
    ),
  );
}
