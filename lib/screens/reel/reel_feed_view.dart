import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../media/ids.dart';
import '../../providers/theme_provider.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/feed_players.dart';
import '../../services/device_performance.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/settings_service.dart';
import '../../theme/fork_motion.dart';
import '../../theme/mono_theme.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/immersive_mode_guard.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/orientation_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/pressable.dart';
import '../../widgets/stat_chip.dart';
import 'reel_card_view.dart';

/// The phone feed's theme (V2-24). The feed paints on black whatever the app
/// theme is, so its text, buttons and loading and empty states always take the
/// dark half of the user's [palette]: the palette itself when it is dark,
/// otherwise Dark ([ThemeProvider.darkThemeFor]). Status bar icons go light to
/// match. The TV keeps Home's theme.
class ReelFeedTheme extends StatelessWidget {
  const ReelFeedTheme({super.key, required this.palette, required this.child});

  /// The palette on screen ([ThemeProvider.activePalette]).
  final MonoPalette? palette;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    value: SystemUiOverlayStyle.light,
    child: Theme(data: ThemeProvider.darkThemeFor(palette), child: child),
  );
}

/// The phone Reel, a feed you thumb through: each card plays in its own
/// page (the clip is drawn into the page, so it slides with your thumb), and
/// the cards around it are already open and parked on their first frame
/// ([ReelFeedPlayers]). Swipe right to hide everything and just watch; swipe
/// left to bring it back. The deck is picked from the button at the top.
///
/// Immersive (V2-31): swiping right hides the controls and the system bars
/// (`immersiveSticky`, kept through a screen switch by [ImmersiveModeGuard]),
/// darkens the art behind the picture (to black on an OLED ground) and
/// leaves only the hairline of progress. Swiping left or Back brings it all
/// back; Back never leaves the tab from there. The first time, a snackbar
/// says how. The feed leaves immersive by itself when it is put away (a tab
/// switch, a page over it, the app in the background).
///
/// A swipe (V2-02): past the middle, the incoming card plays and the one
/// leaving pauses on its frame; the step is committed to the controller and
/// the cards off screen rewound only once the page settles, so a wobble or a
/// half swipe never snaps the outgoing picture back to its first frame. The
/// pages either side are built ahead (`allowImplicitScrolling`).
///
/// A screen switch (V2-65): the Fold moving between its screens, or turning,
/// changes the window's size without recreating the activity
/// (`android:configChanges` covers it) and without touching the players'
/// surfaces (`video_player_android` 2.12.2 drops a texture's surface only on
/// a background memory trim, and hands it back itself on resume). So the
/// feed keeps its card and re-syncs its window: the page under the thumb
/// keeps playing mid-swipe and the step still commits on the settle; at
/// rest the page is put back on the controller's cursor if it slid. The
/// cursor is the page's one source: the [PageController] keeps nothing in
/// page storage, so a rebuilt feed always opens where the controller is.
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
    this.onResize,
    this.onImmersive,
    this.metered = false,
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

  /// The window changed size under the feed (V2-65), told after the feed has
  /// re-synced its players (the `[ReelPerf]` fold sample starts here).
  final VoidCallback? onResize;

  /// The feed entered (true) or left (false) its immersive view (V2-31). The
  /// shell reads it so that Back, which the feed takes to bring its controls
  /// back, doesn't also step to Home.
  final ValueChanged<bool>? onImmersive;

  /// On a metered link (mobile data with no Wi-Fi) the window holds only the
  /// card on screen and the next (V2-08).
  final bool metered;

  @override
  State<ReelFeedView> createState() => _ReelFeedViewState();
}

class _ReelFeedViewState extends State<ReelFeedView> {
  // keepPage off (V2-65): under a PageStorageKey, page storage would reopen
  // a rebuilt feed on the page it last settled on, not the controller's
  // cursor.
  late final PageController _pages = PageController(initialPage: widget.controller.index, keepPage: false);

  /// The window's size, to tell a screen switch from other metrics changes.
  Size? _size;

  /// The page under the thumb: it runs ahead of the controller's cursor
  /// from the middle of a swipe until the page settles.
  late int _page = widget.controller.index;
  String? _deck;
  bool _immersive = false;

  /// The feed asked for the system bars to hide and has not given them back.
  bool _ownsBars = false;
  bool _burst = false;

  /// Counts bursts, so each one grows in afresh.
  int _bursts = 0;

  ReelController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _deck = _c.deck.id;
    _c.addListener(_onController);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final was = _size;
    _size = size;
    if (was != null && was != size) {
      // After this frame's layout, when the page view has its new size.
      WidgetsBinding.instance.addPostFrameCallback((_) => _resized());
    }
  }

  /// The window changed size (V2-65): re-sync the players for the window as
  /// it stands, then, at rest, put the page back on the controller's cursor.
  /// Mid-swipe (or under a finger) the page is left alone: the settle
  /// commits whichever card it lands on, as for any swipe.
  void _resized() {
    if (!mounted) return;
    if (_pages.hasClients && !_pages.position.isScrollingNotifier.value) {
      final page = _pages.page;
      final atRest = page != null && (page - page.round()).abs() <= 0.01;
      if (atRest) {
        _page = _c.index;
        if (page.round() != _c.index) _pages.jumpToPage(_c.index);
      }
    }
    _sync();
    widget.onResize?.call();
  }

  @override
  void didUpdateWidget(ReelFeedView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
    if (old.metered != widget.metered) _sync();
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
    _pages.dispose();
    _showBars();
    if (_immersive) widget.onImmersive?.call(false);
    super.dispose();
  }

  void _onController() {
    if (!mounted) return;
    // Put away (another tab, a page over it, the background): the bars come
    // back for whatever shows next, and the feed returns with its controls.
    if (!_c.active && _immersive) _setImmersive(false);
    // A new deck starts at its own cursor; a card dropped (Not for me) or
    // a step from the TV moves the page to match.
    if (_deck != _c.deck.id) {
      _deck = _c.deck.id;
      _page = _c.index;
      if (_pages.hasClients) _pages.jumpToPage(_c.index);
    } else if (_pages.hasClients && !_pages.position.isScrollingNotifier.value) {
      _page = _c.index;
      final page = _pages.page?.round();
      if (page != null && page != _c.index) _pages.jumpToPage(_c.index);
    } else if (!_pages.hasClients) {
      _page = _c.index;
    }
    _sync();
    setState(() {});
  }

  /// Past the middle of a swipe: the incoming card plays and the window
  /// moves with it; the controller hears of it when the page settles.
  void _onPageChanged(int page) {
    _page = page;
    _sync();
  }

  /// The page came to rest: commit the step and rewind what is off screen.
  bool _onScrollEnd(ScrollEndNotification n) {
    if (n.depth != 0) return false;
    final metrics = n.metrics;
    final page = metrics is PageMetrics ? metrics.page : null;
    if (page == null) return false;
    final at = page.round();
    // Caught mid-flight by a finger: the release ends somewhere else.
    if ((page - at).abs() > 0.01) return false;
    _page = at;
    if (at != _c.index) unawaited(_c.step(at - _c.index));
    unawaited(widget.players.settle());
    return false;
  }

  /// The card on screen, the next two, then the one behind; the players
  /// open them in stages as the card on screen loads (V2-08).
  void _sync() {
    // Hidden, paused or handing over to real playback: nothing plays.
    if (!_c.active) return;
    final i = _page;
    final window = <FeedClip>[
      for (final offset in const [0, 1, 2, -1])
        if (i + offset >= 0)
          if (_c.slotAt(i + offset) case ReelSlot(card: final card?, clip: final clip?))
            if (Uri.tryParse(clip.source.uri) case final uri?) (id: card.id, uri: uri, offset: offset),
    ];
    widget.players.sync(
      current: _c.slotAt(i).card?.id,
      window: window,
      memoryLevel: _c.memoryLevel,
      metered: widget.metered,
    );
  }

  /// Into or out of the immersive view (V2-31).
  void _setImmersive(bool on) {
    if (on == _immersive) return;
    setState(() => _immersive = on);
    if (on) {
      _hideBars();
      _hintOnce();
    } else {
      _showBars();
    }
    widget.onImmersive?.call(on);
  }

  /// The system bars hide, sticky, the way the player hides them; the guard
  /// hides them again if a screen switch brings them back.
  void _hideBars() {
    _ownsBars = true;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    ImmersiveModeGuard.acquire(this);
  }

  /// The bars come back as the player gives them back
  /// ([OrientationHelper.restoreSystemUI]). The guard lets go first, or the
  /// re-show that follows would hide them again.
  void _showBars() {
    if (!_ownsBars) return;
    _ownsBars = false;
    ImmersiveModeGuard.release(this);
    unawaited(
      OrientationHelper.restoreSystemUI().catchError((Object e) {
        appLogger.w('Reel: failed to restore system UI', error: e);
      }),
    );
  }

  /// The first time only, on this device: how to get the controls back.
  void _hintOnce() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null || settings.read(SettingsService.reelImmersiveHintSeen)) return;
    unawaited(settings.write(SettingsService.reelImmersiveHintSeen, true));
    showAppSnackBar(context, 'Swipe left to bring the controls back');
  }

  /// Back while immersive brings the controls back. A sheet open over the
  /// feed takes that Back to close itself, so the feed stays as it is.
  void _onPop(bool didPop, Object? _) {
    if (didPop || !_immersive) return;
    if (OverlaySheetController.maybeOf(context)?.isOpen ?? false) return;
    _setImmersive(false);
  }

  /// Save from the button or a double-tap (V2-29). The filled bookmark and
  /// the burst confirm it, so the controller says nothing (a toast would
  /// float over the buttons); a card already saved neither bursts nor saves
  /// again.
  void _save() {
    final card = _c.current.card;
    if (card == null || _c.isSaved(card.id)) return;
    ForkMotion.success();
    setState(() {
      _burst = true;
      _bursts++;
    });
    // How long the burst holds, not a motion: reduce motion keeps it (V2-32).
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _burst = false);
    });
    unawaited(_c.save(silent: true));
  }

  @override
  Widget build(BuildContext context) {
    final list = _c.cards;
    final count = list == null ? 1 : list.length + 1;
    return PopScope<Object?>(
      canPop: !_immersive,
      onPopInvokedWithResult: _onPop,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            NotificationListener<ScrollEndNotification>(
              onNotification: _onScrollEnd,
              child: PageView.builder(
                controller: _pages,
                scrollDirection: Axis.vertical,
                // The page either side is built before the drag reaches it.
                allowImplicitScrolling: true,
                itemCount: count,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, i) => _pageFor(_c.slotAt(i)),
              ),
            ),
            ListenableBuilder(
              listenable: widget.players,
              builder: (context, _) => _TopBar(
                hidden: _immersive,
                deckName: _c.deck.name,
                muted: widget.players.muted,
                onDecks: widget.onDecks,
                onMute: () => unawaited(widget.players.setMuted(!widget.players.muted)),
                onRemote: widget.onRemote,
              ),
            ),
            _SaveBurst(shown: _burst, count: _bursts),
          ],
        ),
      ),
    );
  }

  Widget _pageFor(ReelSlot slot) {
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
    // Built once per page build and handed through, so a player change
    // redraws the picture and not the title and buttons.
    final info = AnimatedOpacity(
      opacity: _immersive ? 0 : 1,
      duration: _motion(context, const Duration(milliseconds: 220)),
      child: IgnorePointer(
        ignoring: _immersive,
        child: RepaintBoundary(
          child: _Info(
            controller: _c,
            slot: slot,
            watchOnTv: widget.watchOnTv,
            onWatch: widget.onWatch,
            saved: _c.isSaved(card.id),
            onDetails: () => unawaited(_c.openDetails()),
            onSave: _save,
            onMore: widget.onSheet,
          ),
        ),
      ),
    );
    // Sideways anywhere on the page hides or shows the controls. Tap,
    // double-tap and long-press live on the picture only, so the buttons
    // answer at once instead of waiting out the double-tap window.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() < 250 || (v > 0) == _immersive) return;
        ForkMotion.selection();
        _setImmersive(v > 0);
      },
      child: ValueListenableBuilder<FeedCardState>(
        valueListenable: widget.players.card(card.id),
        child: info,
        builder: (context, state, info) {
          final video = state.video;
          final isCurrent = state.current;
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
                    _Backdrop(slot: slot, dim: _immersive ? _immersiveDim(context) : 0.55),
                    AnimatedAlign(
                      duration: _motion(context, const Duration(milliseconds: 280)),
                      curve: Curves.easeOutCubic,
                      alignment: _immersive ? Alignment.center : const Alignment(0, -0.16),
                      child: RepaintBoundary(
                        child: _Picture(slot: slot, video: video, paused: state.paused),
                      ),
                    ),
                  ],
                ),
              ),
              info!,
              if (video != null && isCurrent) _Progress(video: video),
            ],
          );
        },
      ),
    );
  }
}

/// How dark the art behind the picture goes in the immersive view (V2-31):
/// all the way to black on an OLED ground (a palette whose background is
/// pure black), so only the picture is lit.
double _immersiveDim(BuildContext context) =>
    Theme.of(context).extension<MonoTokens>()?.bg == MonoPalette.oled.bg ? 1.0 : 0.9;

/// How long one of the feed's motions runs (V2-32), through the app's own
/// gates: none with reduce motion on ([ForkMotion.reduceMotion]) or on the
/// reduced effects tier ([DevicePerformance.reducedDuration]), otherwise
/// [full]. Clip playback and autoplay don't go through it.
Duration _motion(BuildContext context, Duration full) =>
    ForkMotion.reduceMotion(context) ? Duration.zero : DevicePerformance.reducedDuration(full);

/// The Save burst (V2-29): the filled bookmark grows in with the app's
/// release spring and leaves by fading only, so it never shrinks back over
/// the picture. With reduce motion on it fades without growing; on the
/// reduced effects tier it shows and goes at once.
class _SaveBurst extends StatelessWidget {
  const _SaveBurst({required this.shown, required this.count});

  final bool shown;

  /// Each burst grows from the start again.
  final int count;

  @override
  Widget build(BuildContext context) {
    final still = ForkMotion.reduceMotion(context);
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: DevicePerformance.reducedDuration(shown ? ForkMotion.release : ForkMotion.sheetOut),
        curve: shown ? ForkMotion.enterCurve : ForkMotion.exitCurve,
        child: Center(
          child: TweenAnimationBuilder<double>(
            key: ValueKey(count),
            tween: Tween(begin: still ? 1 : 0.6, end: 1),
            duration: _motion(context, ForkMotion.release),
            curve: ForkMotion.releaseCurve,
            builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
            child: Icon(
              Symbols.bookmark_added_rounded,
              fill: 1,
              size: 96,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
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
          duration: _motion(context, const Duration(milliseconds: 280)),
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
            duration: _motion(context, const Duration(milliseconds: 160)),
            child: v == null ? const SizedBox.shrink() : v.view(),
          ),
          AnimatedOpacity(
            opacity: paused ? 1 : 0,
            duration: _motion(context, const Duration(milliseconds: 150)),
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
        duration: _motion(context, const Duration(milliseconds: 220)),
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

/// Title, facts, why, and the controls (V2-29, D7): Details is the primary
/// control, and the title block opens it too; Watch is tonal here, filled
/// as Watch on TV while connected. Save fills once the card is saved.
class _Info extends StatelessWidget {
  const _Info({
    required this.controller,
    required this.slot,
    required this.watchOnTv,
    required this.saved,
    required this.onWatch,
    required this.onDetails,
    required this.onSave,
    required this.onMore,
  });

  final ReelController controller;
  final ReelSlot slot;
  final bool watchOnTv;
  final bool saved;
  final VoidCallback onWatch;
  final VoidCallback onDetails;
  final VoidCallback onSave;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = slot.card!;
    final clip = slot.clip;
    final radius = BorderRadius.circular(theme.extension<MonoTokens>()?.radiusSm ?? 8);
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
              Pressable(
                longPress: false,
                borderRadius: radius,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: radius,
                    onTap: onDetails,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                      ],
                    ),
                  ),
                ),
              ),
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
                      onPressed: onDetails,
                      icon: const Icon(Symbols.info_rounded),
                      label: const Text('Details', maxLines: 1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: watchOnTv
                        ? FilledButton.icon(
                            onPressed: onWatch,
                            icon: const Icon(Symbols.tv_rounded, fill: 1),
                            label: const Text('Watch on TV', maxLines: 1),
                          )
                        : FilledButton.tonalIcon(
                            onPressed: onWatch,
                            icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
                            label: const Text('Watch', maxLines: 1),
                          ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: saved ? 'Saved' : 'Save',
                    isSelected: saved,
                    onPressed: onSave,
                    icon: const Icon(Symbols.bookmark_add_rounded),
                    selectedIcon: const Icon(Symbols.bookmark_added_rounded, fill: 1),
                  ),
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

/// A hairline of how far the clip is, along the page's foot. The player
/// reports its position only every 100 ms or so, so between reports the bar
/// runs on at play speed (V2-02); each report puts it back on the truth. It
/// runs ahead at most [_ahead], so a stalled clip doesn't race the bar on.
/// With reduce motion on, or on the reduced effects tier, it steps with the
/// reports.
class _Progress extends StatefulWidget {
  const _Progress({required this.video});

  final FeedVideo video;

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> with SingleTickerProviderStateMixin {
  static const _ahead = Duration(milliseconds: 250);

  late final AnimationController _bar = AnimationController(vsync: this);
  bool _still = false;

  @override
  void initState() {
    super.initState();
    widget.video.addListener(_onVideo);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = _motion(context, _ahead) == Duration.zero;
    _onVideo();
  }

  @override
  void didUpdateWidget(_Progress old) {
    super.didUpdateWidget(old);
    if (!identical(old.video, widget.video)) {
      old.video.removeListener(_onVideo);
      widget.video.addListener(_onVideo);
      _onVideo();
    }
  }

  @override
  void dispose() {
    widget.video.removeListener(_onVideo);
    _bar.dispose();
    super.dispose();
  }

  void _onVideo() {
    final v = widget.video;
    final total = v.duration.inMilliseconds;
    if (total <= 0) {
      _bar.value = 0;
      return;
    }
    double at(Duration p) => (p.inMilliseconds / total).clamp(0.0, 1.0);
    _bar.value = at(v.position);
    if (_still || !v.playing) return;
    final to = at(v.position + _ahead);
    if (to > _bar.value) _bar.animateTo(to, duration: _ahead, curve: Curves.linear);
  }

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    height: 2,
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _bar,
        builder: (context, _) => LinearProgressIndicator(
          value: _bar.value,
          minHeight: 2,
          backgroundColor: Colors.white.withValues(alpha: 0.12),
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}
