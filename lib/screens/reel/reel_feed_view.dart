import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_item_types.dart';
import '../../providers/theme_provider.dart';
import '../../services/device_performance.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/feed_players.dart';
import '../../services/reel/reel_art.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/reel/reel_data_budget.dart';
import '../../services/reel/reel_library.dart';
import '../../services/reel/reel_premise.dart';
import '../../services/settings_service.dart';
import '../../theme/fork_motion.dart';
import '../../theme/fork_spacing.dart';
import '../../theme/mono_motion.dart';
import '../../theme/mono_theme.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/immersive_mode_guard.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/orientation_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/fork_motion_widgets.dart';
import '../../widgets/optimized_media_image.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/pressable.dart';
import '../../widgets/stat_chip.dart';
import 'reel_card_view.dart';
import 'reel_decide_view.dart';

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

/// How the phone feed lays a card out for the space it has (V2-30). The
/// splits are the app's own: [ForkSpacing]'s 600 dp phone/tablet line and
/// the music player's two-pane rule (now_playing_screen.dart).
enum ReelFeedLayout {
  /// A phone held upright: the picture above the middle, the info over its
  /// foot on a scrim.
  phone,

  /// A phone on its side (the Fold's cover screen turned): the picture fills
  /// the screen and the controls go, the way the immersive view hides them.
  /// Swiping left or Back brings them back over the picture.
  fullBleed,

  /// 600 dp wide or more and not two-pane (the Fold's inner screen held
  /// upright): the picture at the top, the info below it, so nothing covers
  /// the foot of the picture where captions and lyrics sit.
  stacked,

  /// 800 dp wide and wider than tall (the inner screen on its side): the
  /// picture on the left ([pictureShare]), the info and Up next beside it,
  /// with no scrim over the video.
  twoPane;

  /// The picture's share of the width in [twoPane]; the info takes the rest.
  static const pictureShare = 0.62;

  static ReelFeedLayout of(Size size) {
    final wide = size.width > size.height;
    if (wide && size.shortestSide < 600) return fullBleed;
    if (size.width >= 800 && wide) return twoPane;
    if (size.width >= 600) return stacked;
    return phone;
  }

  /// The info sits over the picture on a scrim (rather than beside or below).
  bool get overlays => this == phone || this == fullBleed;
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
///
/// Layouts (V2-30): the card is laid out by [ReelFeedLayout] for the space
/// the feed has, so a screen switch or a turn moves the picture and the info
/// to suit; on the cover screen on its side the feed goes immersive by
/// itself and comes back out when it is turned upright again (unless the
/// controls were asked back in between). The picture glides between its
/// placeholder shape and the clip's own instead of snapping.
///
/// When a clip ends (V2-47, D6): the players play it as often as the
/// clip-end pref says, then the card holds its last frame with Replay, in
/// the TV's button style. With Next card the feed moves on to the next card
/// with a clip instead, sliding as a swipe would, until
/// [ReelController.leanBackIdle] passes with no touch; then it holds too,
/// so the screen can sleep.
///
/// Behind a playing clip (V2-67): the card's art (the ambient backdrop and the
/// still under the picture) shows until the clip's first frame, then fades
/// out so the clip plays on black. A pause or a held last frame keeps it
/// black; an AI card, a card still opening and a clip that broke keep the art.
///
/// With a screen reader (`MediaQuery.accessibleNavigationOf`, V2-54) each
/// card is one node with Save, More and Hide/Show controls as custom
/// actions, the Reel starts muted so the clip doesn't talk over it, and the
/// controls stay shown: the sideways swipe no longer hides them.
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

  @override
  State<ReelFeedView> createState() => _ReelFeedViewState();
}

class _ReelFeedViewState extends State<ReelFeedView> {
  // keepPage off (V2-65): under a PageStorageKey, page storage would reopen
  // a rebuilt feed on the page it last settled on, not the controller's
  // cursor.
  late final PageController _pages = PageController(initialPage: widget.controller.page, keepPage: false);

  /// The window's size, to tell a screen switch from other metrics changes.
  Size? _size;

  /// The page under the thumb: it runs ahead of the controller's cursor
  /// from the middle of a swipe until the page settles.
  late int _page = widget.controller.page;
  String? _deck;
  bool _immersive = false;

  /// The feed asked for the system bars to hide and has not given them back.
  bool _ownsBars = false;

  /// The layout the feed last laid out in (V2-30).
  ReelFeedLayout? _layout;

  /// The size the feed last laid out at: the page the stills are decoded
  /// for ([reelStillDecode]).
  Size? _feedSize;

  /// The feed went immersive by itself because it was turned on its side
  /// ([ReelFeedLayout.fullBleed]), so turning it upright brings it back.
  bool _sideways = false;

  /// On its side, the controls were asked back: the feed stays out of
  /// immersive until it is turned upright and on its side again.
  bool _controlsAsked = false;
  bool _burst = false;

  /// Counts bursts, so each one grows in afresh.
  int _bursts = 0;

  /// The feed is moving on by itself from a card that played out (V2-47):
  /// the outgoing card doesn't show Replay as it slides away.
  bool _rolling = false;
  StreamSubscription<String>? _ended;

  /// A screen reader is on (V2-54).
  bool _a11y = false;

  /// The one mute a screen reader brings; unmuting after it sticks.
  bool _a11yMuted = false;

  ReelController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _deck = _c.deck.id;
    _c.addListener(_onController);
    _c.artPrecache = _precacheArt;
    _ended = widget.players.ended.listen(_onEnded);
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
    _followScreenReader();
  }

  /// A screen reader came on (V2-54): the controls come back and stay (the
  /// sideways swipe and the layout's own immersive are off while it is on),
  /// and the Reel goes quiet once, so the clip doesn't talk over it. The
  /// mute is for this visit only; unmuting after it sticks.
  void _followScreenReader() {
    final a11y = MediaQuery.accessibleNavigationOf(context);
    if (a11y == _a11y) return;
    _a11y = a11y;
    if (!a11y) return;
    // After this frame: leaving immersive and muting both tell listeners
    // that rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_immersive) _immersiveByUser(false);
      if (_a11yMuted) return;
      _a11yMuted = true;
      if (!widget.players.muted) unawaited(_setMuted(true, remember: false));
    });
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
        _page = _c.page;
        if (page.round() != _c.page) _pages.jumpToPage(_c.page);
      }
    }
    // A card the switch stopped plays on (V2-65).
    _sync(resume: true);
    widget.onResize?.call();
  }

  @override
  void didUpdateWidget(ReelFeedView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onController);
      if (old.controller.artPrecache == _precacheArt) old.controller.artPrecache = null;
      widget.controller.addListener(_onController);
      widget.controller.artPrecache = _precacheArt;
    }
    if (!identical(old.players, widget.players)) {
      unawaited(_ended?.cancel());
      _ended = widget.players.ended.listen(_onEnded);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onController);
    if (_c.artPrecache == _precacheArt) _c.artPrecache = null;
    unawaited(_ended?.cancel());
    _pages.dispose();
    _showBars();
    if (_immersive) widget.onImmersive?.call(false);
    super.dispose();
  }

  /// Decodes [card]'s ambient backdrop and still into the image cache
  /// exactly as its page will build them (plan V2-13): the same path, and
  /// the still at the size its page decodes it ([reelStillDecode]: its
  /// parked clip's shape when that is known, else 16:9).
  Future<void> _precacheArt(ReelCardData card, MediaItem item, {required bool clip}) async {
    if (!mounted) return;
    final still = _stillDecode(widget.players.videoFor(card.id)?.aspectRatio ?? _stillAspect);
    final client = context.tryGetMediaClientWithFallback(serverIdOrNull(card.best.serverId));
    final providers = [
      for (final slot in [_ambientSize, still])
        ?MediaImageHelper.serverArtworkProviderFor(
          context,
          client: client,
          thumbPath: _artPath(item),
          width: slot.width,
          height: slot.height,
          imageType: ImageType.art,
        )?.provider,
    ];
    await Future.wait([for (final p in providers) ReelArt.precache(p, context, card: card.id)]);
  }

  /// The size this feed decodes a still at, for a clip of [aspect].
  Size _stillDecode(double aspect) {
    final page = _feedSize ?? MediaQuery.sizeOf(context);
    return reelStillDecode(page, _layout ?? ReelFeedLayout.of(page), aspect, immersive: _immersive);
  }

  void _onController() {
    if (!mounted) return;
    // Put away (another tab, a page over it, the background): the bars come
    // back for whatever shows next, and the feed returns with its controls.
    if (!_c.active && _immersive) {
      _setImmersive(false);
      _sideways = false;
    }
    // A new deck starts at its own cursor; a card dropped (Not for me) or
    // a step from the TV moves the page to match.
    if (_deck != _c.deck.id) {
      _deck = _c.deck.id;
      _page = _c.page;
      if (_pages.hasClients) _pages.jumpToPage(_c.page);
    } else if (_pages.hasClients && !_pages.position.isScrollingNotifier.value) {
      _page = _c.page;
      final page = _pages.page?.round();
      if (page != null && page != _c.page) _pages.jumpToPage(_c.page);
    } else if (!_pages.hasClients) {
      _page = _c.page;
    }
    _sync();
    setState(() {});
    // Back on screen while on its side: full-bleed again.
    _followLayout();
  }

  /// The feed on its side goes immersive by itself; upright again, it comes
  /// back out if it went in by itself (V2-30). Swiping left or Back while on
  /// its side keeps the controls until the next turn.
  void _followLayout() {
    if (!mounted) return;
    if (_layout != ReelFeedLayout.fullBleed) {
      _controlsAsked = false;
      if (_sideways) {
        _sideways = false;
        _setImmersive(false);
      }
      return;
    }
    if (!_c.active || _immersive || _controlsAsked || _a11y) return;
    _setImmersive(true);
    _sideways = true;
  }

  /// A swipe or Back into or out of immersive.
  void _immersiveByUser(bool on) {
    _setImmersive(on);
    _sideways = false;
    if (!on && _layout == ReelFeedLayout.fullBleed) _controlsAsked = true;
  }

  /// An Up next row (V2-30): the next card slides in as a swipe would; one
  /// further on is jumped to, so the cards between open no players. The
  /// step commits when the page settles, as for a swipe.
  void _goTo(int page) {
    if (!_pages.hasClients) return;
    final by = _motion(context, Theme.of(context).extension<MonoTokens>()?.slow ?? const Duration(milliseconds: 300));
    if ((page - _page).abs() == 1 && by > Duration.zero) {
      unawaited(_pages.animateToPage(page, duration: by, curve: MonoMotion.emphasized));
    } else {
      _pages.jumpToPage(page);
    }
  }

  /// The card on screen played out (V2-47). With Next card the feed moves
  /// on to the next card that isn't an AI card (a still has no end to move
  /// on from), or to the deck's end; the step commits on the settle, as for
  /// a swipe. It stays held for Replay under a finger, with any other
  /// clip-end pref, or once [ReelController.leanBackIdle] has passed with
  /// no touch.
  void _onEnded(String cardId) {
    if (!mounted || !_c.active || _c.clipEnd != ReelClipEnd.nextCard || !_c.mayRollOn) return;
    if (_c.slotAt(_page).card?.id != cardId) return;
    if (!_pages.hasClients || _pages.position.isScrollingNotifier.value) return;
    var to = _page + 1;
    while (_c.slotAt(to).isAiCard) {
      to++;
    }
    setState(() => _rolling = true);
    _goTo(to);
  }

  /// Replay on a held card (V2-47): the players start it again and the
  /// controller records the replay.
  void _replay() {
    unawaited(widget.players.replay());
    unawaited(_c.replay());
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
    if (_rolling) setState(() => _rolling = false);
    if (at != _c.page) unawaited(_c.step(at - _c.page));
    unawaited(widget.players.settle());
    return false;
  }

  /// The card on screen, the next two, then the one behind (by page, so
  /// the decision card holds a place and plays nothing); the players open
  /// them in stages as the card on screen loads (V2-08). On mobile data the
  /// Reel's data budget (V2-53) narrows that: Data saver to the card on
  /// screen and the next, Stills only to none (the memory ladder's level-2
  /// path); Normal keeps the whole window.
  void _sync({bool resume = false}) {
    // Hidden, paused or handing over to real playback: nothing plays.
    if (!_c.active) return;
    final budget = _c.dataBudget;
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
      memoryLevel: budget.clips ? _c.memoryLevel : 2,
      metered: budget.ahead < ReelDataBudget.full.ahead,
      resume: resume,
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
    showAppSnackBar(context, t.reel.card.immersiveHint);
  }

  /// Back while immersive brings the controls back. A sheet open over the
  /// feed takes that Back to close itself, so the feed stays as it is.
  void _onPop(bool didPop, Object? _) {
    if (didPop || !_immersive) return;
    if (OverlaySheetController.maybeOf(context)?.isOpen ?? false) return;
    _immersiveByUser(false);
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

  /// The screen reader's Hide / Show controls action (V2-54).
  void _toggleControls() {
    ForkMotion.selection();
    _immersiveByUser(!_immersive);
  }

  @override
  Widget build(BuildContext context) {
    final count = _c.slotCount;
    return PopScope<Object?>(
      canPop: !_immersive,
      onPopInvokedWithResult: _onPop,
      // Any touch is someone there: Next card's idle stop counts from it
      // (V2-47). A card moving on by itself is not a touch.
      child: Listener(
        onPointerDown: (_) => _c.noteInput(),
        child: ColoredBox(
          color: Colors.black,
          child: LayoutBuilder(
            builder: (context, box) {
              _feedSize = box.biggest;
              final layout = ReelFeedLayout.of(box.biggest);
              if (layout != _layout) {
                _layout = layout;
                // After this frame: going immersive tells the shell.
                WidgetsBinding.instance.addPostFrameCallback((_) => _followLayout());
              }
              return _stack(count);
            },
          ),
        ),
      ),
    );
  }

  Widget _stack(int count) => Stack(
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
          itemBuilder: (context, i) => _pageFor(i, _c.slotAt(i)),
        ),
      ),
      ListenableBuilder(
        listenable: widget.players,
        builder: (context, _) => _TopBar(
          hidden: _immersive,
          deckName: _c.deck.name,
          muted: widget.players.muted,
          onDecks: widget.onDecks,
          onMute: () => unawaited(_toggleMute()),
          onRemote: widget.onRemote,
        ),
      ),
      _SaveBurst(shown: _burst, count: _bursts),
    ],
  );

  /// The mute button (V2-22): the players go silent (or rise) at once, and
  /// the controller records an unmute and keeps the choice.
  Future<void> _toggleMute() => _setMuted(!widget.players.muted);

  Future<void> _setMuted(bool muted, {bool remember = true}) async {
    await widget.players.setMuted(muted);
    await _c.setMuted(muted, remember: remember);
  }

  /// The cards after page [i] for the two-pane Up next (V2-30).
  List<(int, ReelSlot)> _upNext(int i) => [
    for (var k = 1; k <= _UpNext.rows; k++)
      if (_c.slotAt(i + k) case final s when s.kind == ReelSlotKind.card) (i + k, s),
  ];

  Widget _pageFor(int i, ReelSlot slot) {
    switch (slot.kind) {
      case ReelSlotKind.loading:
        return const ReelCurtain();
      case ReelSlotKind.failed:
        return ReelMessage(
          icon: Symbols.cloud_off_rounded,
          title: t.reel.card.failedTitle(deck: _c.deck.name),
          body: t.reel.card.failedBodyPhone,
          action: FilledButton.tonalIcon(
            onPressed: () => unawaited(_c.retryDeck()),
            icon: const Icon(Symbols.refresh_rounded),
            label: Text(t.reel.card.tryAgain),
          ),
        );
      case ReelSlotKind.empty:
        return ReelMessage(
          icon: Symbols.movie_rounded,
          title: t.reel.card.emptyTitle(deck: _c.deck.name),
          body: t.reel.card.pickAnotherDeck,
          action: FilledButton.tonalIcon(
            onPressed: widget.onDecks,
            icon: const Icon(Symbols.video_library_rounded),
            label: Text(t.reel.card.decks),
          ),
        );
      case ReelSlotKind.poolEnd:
        return ReelMessage(
          icon: Symbols.check_circle_rounded,
          title: _c.deck.id == 'for-you' ? t.reel.card.endForYou : t.reel.card.endTitle(deck: _c.deck.name),
          body: t.reel.card.pickAnotherDeck,
          action: FilledButton.tonalIcon(
            onPressed: widget.onDecks,
            icon: const Icon(Symbols.video_library_rounded),
            label: Text(t.reel.card.decks),
          ),
        );
      case ReelSlotKind.decide:
        return ReelDecideView(
          controller: _c,
          slot: slot,
          tv: false,
          onWatch: widget.onWatch,
          watchOnTv: widget.watchOnTv,
        );
      case ReelSlotKind.card:
        break;
    }
    final card = slot.card!;
    final layout = _layout ?? ReelFeedLayout.phone;
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
            layout: layout,
            upNext: layout == ReelFeedLayout.twoPane ? _upNext(i) : const [],
            onUpNext: _goTo,
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
    final onScreen = card.id == _c.slotAt(_page).card?.id;
    // One node per card for a screen reader (V2-54): its texts read
    // together, with Save, More and Hide/Show controls as custom actions.
    // The feed's own scroll actions stay on the PageView above it; the
    // sideways swipe is kept out of the tree, so the page offers no scroll
    // actions of its own.
    return Semantics(
      container: true,
      customSemanticsActions: onScreen
          ? {
              CustomSemanticsAction(label: t.reel.card.save): _save,
              CustomSemanticsAction(label: t.reel.card.more): widget.onSheet,
              CustomSemanticsAction(label: _immersive ? t.reel.card.showControls : t.reel.card.hideControls):
                  _toggleControls,
            }
          : null,
      child: _gestures(slot, card, info, layout),
    );
  }

  Widget _gestures(ReelSlot slot, ReelCardData card, Widget info, ReelFeedLayout layout) {
    // Sideways anywhere on the page hides or shows the controls (not with a
    // screen reader on). Tap, double-tap and long-press live on the picture
    // only, so the buttons answer at once instead of waiting out the
    // double-tap window.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      onHorizontalDragEnd: _a11y
          ? null
          : (d) {
              final v = d.primaryVelocity ?? 0;
              if (v.abs() < 250 || (v > 0) == _immersive) return;
              ForkMotion.selection();
              _immersiveByUser(v > 0);
            },
      child: ValueListenableBuilder<FeedCardState>(
        valueListenable: widget.players.card(card.id),
        child: info,
        builder: (context, state, info) {
          final video = state.video;
          final isCurrent = state.current;
          final glide = _motion(context, const Duration(milliseconds: 280));
          final backdrop = _Backdrop(slot: slot, video: video, dim: _immersive ? _immersiveDim(context) : 0.55);
          final held = state.held && !_rolling;
          final picture = RepaintBoundary(
            child: _Picture(
              slot: slot,
              video: video,
              decode: _stillDecode(video?.aspectRatio ?? _stillAspect),
              paused: state.paused,
              held: held,
              onReplay: _replay,
            ),
          );
          Widget tappable(Widget child) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: isCurrent ? (state.held ? _replay : () => unawaited(widget.players.togglePause())) : null,
            // Held (V2-47): no double-tap, so Replay and a tap on the
            // picture answer at once instead of waiting out its window.
            onDoubleTap: isCurrent && !state.held ? _save : null,
            onLongPress: isCurrent ? widget.onSheet : null,
            child: child,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              if (layout.overlays) ...[
                tappable(
                  Stack(
                    fit: StackFit.expand,
                    children: [
                      backdrop,
                      AnimatedAlign(
                        duration: glide,
                        curve: Curves.easeOutCubic,
                        alignment: _immersive || layout == ReelFeedLayout.fullBleed
                            ? Alignment.center
                            : const Alignment(0, -0.16),
                        child: picture,
                      ),
                    ],
                  ),
                ),
                info!,
              ] else ...[
                backdrop,
                _Split(
                  layout: layout,
                  immersive: _immersive,
                  duration: glide,
                  picture: (alignment) => tappable(
                    AnimatedPadding(
                      duration: glide,
                      curve: Curves.easeOutCubic,
                      // Clear of the top bar while it shows.
                      padding: EdgeInsets.only(top: _immersive ? 0 : _barSpace(context)),
                      child: AnimatedAlign(
                        duration: glide,
                        curve: Curves.easeOutCubic,
                        alignment: alignment,
                        child: picture,
                      ),
                    ),
                  ),
                  info: info!,
                ),
              ],
              if (video != null && isCurrent) _Progress(video: video),
            ],
          );
        },
      ),
    );
  }
}

/// The ambient backdrop's slot: the art fetched tiny and scaled up.
const Size _ambientSize = Size(36, 64);

/// The still's shape until the card's clip reports its own.
const double _stillAspect = 16 / 9;

String? _artPath(MediaItem item) => item.artPath ?? item.thumbPath;

/// The frame the picture gets in a [page]: as wide as the page at [aspect],
/// or as tall as the page when that is too tall (an [AspectRatio] under the
/// page's loose constraints).
@visibleForTesting
Size reelStillFrame(Size page, double aspect) {
  var width = page.width;
  var height = width / aspect;
  if (height > page.height) {
    height = page.height;
    width = height * aspect;
  }
  return Size(width, height);
}

/// The size a card's still is decoded at (plan V2-05): its frame at [aspect]
/// (the clip's own shape once known, else 16:9) in the area [layout] gives
/// the picture in a [page]: the whole page, or its picture share beside the
/// info in two panes (all of it in the immersive view). It is set rather
/// than read from the frame as it lays out, so the frame's glide to the
/// clip's shape never decodes the art again at each step of it, and the
/// warm (V2-13) decodes the very entry the page then reads.
@visibleForTesting
Size reelStillDecode(Size page, ReelFeedLayout layout, double aspect, {bool immersive = false}) => reelStillFrame(
  layout == ReelFeedLayout.twoPane && !immersive ? Size(page.width * ReelFeedLayout.pictureShare, page.height) : page,
  aspect,
);

/// The height the top bar takes: the status bar, then one row of buttons.
double _barSpace(BuildContext context) => MediaQuery.paddingOf(context).top + 56;

/// The picture and the info side by side or one above the other, for the
/// layouts where the info doesn't sit over the picture (V2-30). In the
/// immersive view the info's share folds away, so the picture glides out to
/// fill the page.
class _Split extends StatelessWidget {
  const _Split({
    required this.layout,
    required this.immersive,
    required this.duration,
    required this.picture,
    required this.info,
  });

  final ReelFeedLayout layout;
  final bool immersive;
  final Duration duration;

  /// The picture's area, with the picture placed at the alignment given.
  final Widget Function(Alignment alignment) picture;
  final Widget info;

  @override
  Widget build(BuildContext context) {
    if (layout == ReelFeedLayout.twoPane) {
      return LayoutBuilder(
        builder: (context, box) => Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: picture(Alignment.center)),
            ClipRect(
              child: AnimatedAlign(
                duration: duration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                widthFactor: immersive ? 0 : 1,
                child: SizedBox(width: box.maxWidth * (1 - ReelFeedLayout.pictureShare), child: info),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: picture(immersive ? Alignment.center : Alignment.topCenter)),
        ClipRect(
          child: AnimatedAlign(
            duration: duration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            heightFactor: immersive ? 0 : 1,
            child: info,
          ),
        ),
      ],
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

/// The card's own art, full-bleed and dimmed, behind the picture, until the
/// card's clip shows its first frame (V2-67): then the art fades out and the
/// clip plays on black. An AI card, a card before its first frame and a clip
/// that failed keep it.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.slot, required this.video, required this.dim});

  final ReelSlot slot;
  final FeedVideo? video;
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
          _ClipShowing(
            video: video,
            builder: (context, showing) => _ArtFade(
              key: ValueKey(('reel-ambient-art', slot.card!.id)),
              out: showing,
              child: OptimizedMediaImage(
                client: context.tryGetMediaClientWithFallback(serverIdOrNull(slot.card!.best.serverId)),
                imagePath: _artPath(item),
                width: _ambientSize.width,
                height: _ambientSize.height,
                fit: BoxFit.cover,
                imageType: ImageType.art,
                onImageProvider: (provider) => ReelArt.track(provider, card: slot.card!.id),
                placeholder: (_, _) => const SizedBox.shrink(),
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
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
/// Once the first frame shows, the art under it fades out too (V2-67), so the
/// frame's edges never show the poster while it glides to the clip's shape;
/// a clip that breaks gives the still back.
/// The frame starts 16:9 and glides to the clip's own shape once it opens
/// (V2-30), on the app's slow token and emphasized curve; with reduce motion
/// on, or on the reduced effects tier, it takes the new shape at once.
///
/// A clip that played out holds its last frame with Replay over it (V2-47),
/// the TV's filled Replay button.
class _Picture extends StatelessWidget {
  const _Picture({
    required this.slot,
    required this.video,
    required this.decode,
    required this.paused,
    required this.held,
    required this.onReplay,
  });

  final ReelSlot slot;
  final FeedVideo? video;

  /// The size the still decodes at ([reelStillDecode]).
  final Size decode;
  final bool paused;
  final bool held;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final v = video;
    final aspect = v?.aspectRatio ?? _stillAspect;
    final item = slot.item;
    final slow = Theme.of(context).extension<MonoTokens>()?.slow ?? const Duration(milliseconds: 300);
    return TweenAnimationBuilder<double>(
      // No begin: the first build takes the shape as it is, later ones glide.
      tween: Tween<double>(end: aspect),
      duration: _motion(context, slow),
      curve: MonoMotion.emphasized,
      builder: (context, aspect, child) => AspectRatio(aspectRatio: aspect, child: child),
      child: _ClipShowing(
        video: v,
        builder: (context, showing) => Stack(
          fit: StackFit.expand,
          children: [
            if (item != null)
              _ArtFade(
                key: ValueKey(('reel-still-art', slot.card!.id)),
                out: showing,
                child: OptimizedMediaImage(
                  client: context.tryGetMediaClientWithFallback(serverIdOrNull(slot.card!.best.serverId)),
                  imagePath: _artPath(item),
                  // Decoded at the frame it is shown in (plan V2-05), set
                  // rather than read from the frame as it glides; it still
                  // fills whatever the frame is.
                  width: decode.width,
                  height: decode.height,
                  fit: BoxFit.cover,
                  imageType: ImageType.art,
                  onImageProvider: (provider) => ReelArt.track(provider, card: slot.card!.id),
                  placeholder: (_, _) => const ColoredBox(color: Colors.black26),
                  errorWidget: (_, _, _) => const ColoredBox(color: Colors.black26),
                ),
              ),
            AnimatedOpacity(
              opacity: showing ? 1 : 0,
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
            AnimatedOpacity(
              opacity: held ? 1 : 0,
              duration: _motion(context, const Duration(milliseconds: 150)),
              child: IgnorePointer(
                ignoring: !held,
                child: Center(
                  child: FilledButton.icon(
                    onPressed: onReplay,
                    icon: const Icon(Symbols.replay_rounded),
                    label: Text(t.reel.card.replay),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether [video]'s picture is up (V2-67): open, its first frame ready, and
/// not broken. It follows the player itself, so a clip that breaks mid-play
/// gives the art back, and it rebuilds only when that answer changes, not at
/// every position report. A pause or a held last frame keeps the picture up.
class _ClipShowing extends StatefulWidget {
  const _ClipShowing({required this.video, required this.builder});

  final FeedVideo? video;
  final Widget Function(BuildContext context, bool showing) builder;

  @override
  State<_ClipShowing> createState() => _ClipShowingState();
}

class _ClipShowingState extends State<_ClipShowing> {
  late bool _showing = _of(widget.video);

  static bool _of(FeedVideo? v) => v != null && v.ready && !v.failed;

  @override
  void initState() {
    super.initState();
    widget.video?.addListener(_onVideo);
  }

  @override
  void didUpdateWidget(_ClipShowing old) {
    super.didUpdateWidget(old);
    if (!identical(old.video, widget.video)) {
      old.video?.removeListener(_onVideo);
      widget.video?.addListener(_onVideo);
      _showing = _of(widget.video);
    }
  }

  @override
  void dispose() {
    widget.video?.removeListener(_onVideo);
    super.dispose();
  }

  void _onVideo() {
    final showing = _of(widget.video);
    if (showing != _showing) setState(() => _showing = showing);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _showing);
}

/// The card's art fading out once its clip is up (V2-67), on the app's slow
/// token and standard curve; with reduce motion on, or on the reduced effects
/// tier, it goes at once. It stays built while out, so it comes back without
/// a fetch if the clip breaks.
class _ArtFade extends StatelessWidget {
  const _ArtFade({super.key, required this.out, required this.child});

  final bool out;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: out ? 0 : 1,
    duration: _motion(context, Theme.of(context).extension<MonoTokens>()?.slow ?? const Duration(milliseconds: 300)),
    curve: MonoMotion.standard,
    child: child,
  );
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
                      tooltip: t.reel.card.onTv,
                      onPressed: onRemote,
                      icon: const Icon(Symbols.settings_remote_rounded),
                    ),
                  IconButton(
                    tooltip: muted ? t.reel.card.soundOn : t.reel.card.mute,
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
///
/// Where it sits follows the [layout] (V2-30): over the picture's foot on a
/// scrim on a phone, below the picture when stacked, and in its own pane
/// with Up next in two-pane, where neither has a scrim. Its side insets are
/// the app's own ([ForkSpacing.edgeInset]); the icon buttons at the end
/// carry 8 of their own.
class _Info extends StatelessWidget {
  const _Info({
    required this.controller,
    required this.slot,
    required this.layout,
    required this.upNext,
    required this.onUpNext,
    required this.watchOnTv,
    required this.saved,
    required this.onWatch,
    required this.onDetails,
    required this.onSave,
    required this.onMore,
  });

  final ReelController controller;
  final ReelSlot slot;
  final ReelFeedLayout layout;

  /// The cards after this one, with their pages, for two-pane.
  final List<(int, ReelSlot)> upNext;
  final ValueChanged<int> onUpNext;
  final bool watchOnTv;
  final bool saved;
  final VoidCallback onWatch;
  final VoidCallback onDetails;
  final VoidCallback onSave;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = ForkSpacing.of(context);
    final inset = spacing.edgeInset;
    final card = slot.card!;
    final clip = slot.clip;
    final badge = controller.deck.keepsSeen ? card.facts.seen.badge : null;
    final radius = BorderRadius.circular(theme.extension<MonoTokens>()?.radiusSm ?? 8);
    final pane = layout == ReelFeedLayout.twoPane;
    final body = <Widget>[
      if (clip != null || card.chip != null || badge != null)
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
                  label: ReelCardView.clipLabel(clip),
                ),
              if (card.chip case final chip?) StatChip(label: chip),
              if (badge != null) StatChip(icon: Symbols.check_rounded, label: badge),
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
                _Premise(slot: slot),
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
          t.reel.card.themeCredit,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
      const SizedBox(height: 14),
      _Controls(
        pane: pane,
        watchOnTv: watchOnTv,
        resume: slot.resumeEpisode,
        saved: saved,
        onWatch: onWatch,
        onDetails: onDetails,
        onSave: onSave,
        onMore: onMore,
      ),
    ];
    switch (layout) {
      case ReelFeedLayout.phone || ReelFeedLayout.fullBleed:
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
              padding: EdgeInsets.fromLTRB(inset, 48, inset - 8, 14),
              // V2-26: the block grows when the metadata lands (the clip
              // chip, the credit) by gliding up from the bottom, never by
              // jumping.
              child: _Grow(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: body,
                ),
              ),
            ),
          ),
        );
      case ReelFeedLayout.stacked:
        return Padding(
          padding: EdgeInsets.fromLTRB(inset, 16, inset - 8, 14),
          child: _Grow(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: body),
          ),
        );
      case ReelFeedLayout.twoPane:
        return Padding(
          padding: EdgeInsets.fromLTRB(inset, _barSpace(context), inset - 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...body,
              if (upNext.isNotEmpty)
                Flexible(
                  child: _UpNext(cards: upNext, onTap: onUpNext),
                ),
            ],
          ),
        );
    }
  }
}

/// Details, Watch, Save and More, on one row. In a two-pane info pane
/// ([pane]) under 360 dp wide, Save and More drop to a second row so the two
/// labels keep their room; the phone keeps its one row.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.pane,
    required this.watchOnTv,
    required this.resume,
    required this.saved,
    required this.onWatch,
    required this.onDetails,
    required this.onSave,
    required this.onMore,
  });

  final bool pane;
  final bool watchOnTv;

  /// Give it another go (V2-40): the episode Watch resumes, as "E4".
  final String? resume;
  final bool saved;
  final VoidCallback onWatch;
  final VoidCallback onDetails;
  final VoidCallback onSave;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final details = FilledButton.icon(
      onPressed: onDetails,
      icon: const Icon(Symbols.info_rounded),
      label: Text(t.reel.card.details, maxLines: 1),
    );
    final watch = watchOnTv
        ? FilledButton.icon(
            onPressed: onWatch,
            icon: const Icon(Symbols.tv_rounded, fill: 1),
            label: Text(t.reel.card.watchOnTv, maxLines: 1),
          )
        : FilledButton.tonalIcon(
            onPressed: onWatch,
            icon: const Icon(Symbols.play_arrow_rounded, fill: 1),
            label: Text(switch (resume) {
              final episode? => t.reel.card.resume(episode: episode),
              null => t.reel.card.watch,
            }, maxLines: 1),
          );
    final save = IconButton(
      tooltip: saved ? t.reel.card.saved : t.reel.card.save,
      isSelected: saved,
      onPressed: onSave,
      icon: const Icon(Symbols.bookmark_add_rounded),
      selectedIcon: const Icon(Symbols.bookmark_added_rounded, fill: 1),
    );
    final more = IconButton(tooltip: t.reel.card.more, onPressed: onMore, icon: const Icon(Symbols.more_vert_rounded));
    Widget oneRow() => Row(
      children: [
        Expanded(child: details),
        const SizedBox(width: 8),
        Expanded(child: watch),
        const SizedBox(width: 4),
        save,
        more,
      ],
    );
    if (!pane) return oneRow();
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 360) return oneRow();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 8),
                Expanded(child: watch),
              ],
            ),
            const SizedBox(height: 4),
            // The icons' own padding lines them up with the buttons' edge.
            Transform.translate(
              offset: const Offset(-8, 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [save, more]),
            ),
          ],
        );
      },
    );
  }
}

/// Up next in the two-pane layout (V2-30): the next few cards of the deck,
/// each a row that takes the feed to it. The list doesn't scroll (a drag on
/// it pages the feed); rows that don't fit are clipped.
class _UpNext extends StatelessWidget {
  const _UpNext({required this.cards, required this.onTap});

  /// How many cards ahead are shown.
  static const rows = 3;

  final List<(int, ReelSlot)> cards;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final spacing = ForkSpacing.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: spacing.titleGap * 2),
        Text(t.reel.card.upNext, style: spacing.titleStyle(context)),
        SizedBox(height: spacing.titleGap),
        Flexible(
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final (page, slot) in cards)
                _UpNextRow(key: ValueKey(slot.card!.id), slot: slot, onTap: () => onTap(page)),
            ],
          ),
        ),
      ],
    );
  }
}

class _UpNextRow extends StatelessWidget {
  const _UpNextRow({super.key, required this.slot, required this.onTap});

  final ReelSlot slot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = slot.card!;
    final item = slot.item;
    final radius = BorderRadius.circular(theme.extension<MonoTokens>()?.radiusSm ?? 8);
    final blank = ColoredBox(color: theme.colorScheme.surfaceContainerHighest);
    return Pressable(
      longPress: false,
      borderRadius: radius,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: radius,
                  child: SizedBox(
                    width: 96,
                    height: 54,
                    child: item == null
                        ? blank
                        : OptimizedMediaImage(
                            client: context.tryGetMediaClientWithFallback(serverIdOrNull(card.best.serverId)),
                            imagePath: item.artPath ?? item.thumbPath,
                            // The tile it is shown in (plan V2-05).
                            width: 96,
                            height: 54,
                            fit: BoxFit.cover,
                            imageType: ImageType.art,
                            onImageProvider: (provider) => ReelArt.track(provider, card: card.id),
                            placeholder: (_, _) => blank,
                            errorWidget: (_, _, _) => blank,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.title.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      ReelMetadataLine(item: item, year: card.best.year, fontSize: 12),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the title is about, in two lines at most, on a card with no clip
/// to tell you (an AI card) and on an anime opening, which is a song
/// (plan D19); never on a trailer. The daily build's hook first, else the
/// tagline, else the summary's first sentence ([ReelPremise.line]), under
/// the app's spoiler setting. It fades in once the card has resolved.
class _Premise extends StatelessWidget {
  const _Premise({required this.slot});

  final ReelSlot slot;

  bool get _shows => slot.isAiCard || slot.clip?.source.origin == ClipOrigin.animeTheme;

  @override
  Widget build(BuildContext context) {
    if (!_shows) return const SizedBox.shrink();
    final hide = SettingsService.instanceOrNull?.listenable(SettingsService.hideSpoilers);
    if (hide == null) return _line(context, hideSpoilers: false);
    return ValueListenableBuilder<bool>(
      valueListenable: hide,
      builder: (context, hideSpoilers, _) => _line(context, hideSpoilers: hideSpoilers),
    );
  }

  Widget _line(BuildContext context, {required bool hideSpoilers}) {
    final card = slot.card!;
    final item = slot.item;
    final text = ReelPremise.line(
      hook: card.hook,
      tagline: item?.tagline ?? card.best.tagline,
      summary: item?.summary ?? card.best.summary,
      hideSpoilers: hideSpoilers,
      unwatchedEpisode: item?.shouldHideSpoiler ?? false,
    );
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ForkEntrance(
      key: ValueKey('premise:${card.id}'),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
        ),
      ),
    );
  }
}

/// Animates [child]'s size changes from the bottom-left at the theme's
/// normal duration and standard curve. With reduced effects or animations
/// off the size changes at once (an [AnimatedSize] at zero length re-dirties
/// itself mid-layout, so it is left out then).
class _Grow extends StatelessWidget {
  const _Grow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final normal = Theme.of(context).extension<MonoTokens>()?.normal ?? const Duration(milliseconds: 200);
    final duration = ForkMotion.reduceMotion(context) ? Duration.zero : DevicePerformance.reducedDuration(normal);
    if (duration == Duration.zero) return child;
    return AnimatedSize(duration: duration, curve: MonoMotion.standard, alignment: Alignment.bottomLeft, child: child);
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
          backgroundColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}
