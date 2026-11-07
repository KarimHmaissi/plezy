import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../focus/dpad_navigator.dart';
import '../../focus/dpad_select_long_press_controller.dart';
import '../../focus/transport_keys.dart';
import '../../media/media_item.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/navigation_tabs.dart';
import '../../mixins/tab_visibility_aware.dart';
import '../../providers/companion_remote_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/memory_trim_policy.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_art.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/reel/reel_library.dart';
import '../../services/reel/reel_developer.dart';
import '../../services/reel/reel_perf.dart';
import '../../services/reel/reel_sound.dart';
import '../../services/reel/reel_store.dart';
import '../../services/reel/reel_volume.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../theme/mono_theme.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../settings/reel_settings_screen.dart';
import '../../services/reel/feed_players.dart';
import '../../services/reel/feed_youtube_webview.dart';
import '../video_player/wakelock_controller.dart';
import 'reel_card_view.dart';
import 'reel_debug_overlay.dart';
import 'reel_feed_view.dart';
import 'reel_held_step.dart';
import 'reel_keys.dart';
import 'reel_lean_back.dart';
import 'reel_intro.dart';
import 'reel_remote_view.dart';
import 'reel_sheet.dart';
import 'reel_sound_badge.dart';
import 'reel_stuck.dart';

/// Fork: The Reel. A full-screen feed of trailers and anime openings from
/// the servers, one title per card, grouped into decks like channels.
/// Opening it is the one place video plays unasked; it pauses and releases
/// its player whenever the tab is hidden, a page covers it, or the app goes
/// to the background.
class ReelScreen extends StatefulWidget {
  const ReelScreen({super.key, required this.create, this.offline = false});

  /// Builds the session from the app's services (`ReelApp.controller`).
  final Future<ReelController> Function(BuildContext context) create;

  /// The app is offline (no server reachable). The tab stays, with a
  /// message in place of the feed; nothing plays or resolves until it is
  /// back online.
  final bool offline;

  /// Whether the Reel is the visible tab: the shell goes see-through so the
  /// native video surface behind Flutter shows.
  static final ValueNotifier<bool> showing = ValueNotifier(false);

  /// A deck asked for from outside the tab (deep link, Reel it, the Fold),
  /// taken by the screen when it next shows.
  static final ValueNotifier<String?> requestedDeck = ValueNotifier(null);

  /// The phone feed is immersive (V2-31): its controls and the system bars
  /// are hidden, and Back brings them back, so the shell's Back must not
  /// also step to Home.
  static final ValueNotifier<bool> immersive = ValueNotifier(false);

  /// The title the Fold was on when it asked for [requestedDeck] (its
  /// `groupKey`), so the TV opens on that card.
  static String? _requestedCard;

  /// The Reel screen that is showing, for On TV mode's commands.
  static ReelScreenState? _live;

  /// The showing Reel's session (the measure-day probe reads its card).
  static ReelController? get liveController => _live?._controller;

  /// The system's memory pressure (main.dart): the showing Reel steps down
  /// its ladder.
  static void trimMemory() {
    final c = _live?._controller;
    if (c != null && c.active) unawaited(c.trimMemory());
  }

  /// One RSS watchdog tier (main.dart): halved is level 1, cleared level 2.
  static void trimForWatchdog(WatchdogTrim trim) {
    final c = _live?._controller;
    if (c != null && c.active) unawaited(c.trimForWatchdog(trim));
  }

  /// On TV mode (host side): `reelStep` from the phone.
  static void remoteStep(Map<String, dynamic> data) => _live?._remoteStep(data);

  /// On TV mode (host side): `reelAction` from the phone.
  static void remoteAction(String action) => _live?._remoteAction(action);

  /// Whether the Reel is offered at all: Android only (its clip core is
  /// ExoPlayer), and not turned off with Show the Reel tab on its settings
  /// page. Off hides it everywhere, like Explore's own toggle: the tab, the
  /// rail item and Reel it.
  static bool get enabled =>
      Platform.isAndroid && (SettingsService.instanceOrNull?.read(SettingsService.showReelTab) ?? true);

  /// Opens the Reel tab, on [deck] when given: closes pages above the shell
  /// first so the tab is what shows. Does nothing while the Reel is turned
  /// off ([enabled]). [fromRemote]: the Fold's On TV mode asked for it, so
  /// the first-run intro waits (see [_introDeferred]). [groupKey]: the
  /// title to open [deck] on, when this device's list of it has it.
  static void open(BuildContext context, {String? deck, String? groupKey, bool fromRemote = false}) {
    if (!enabled) return;
    if (fromRemote) _introDeferred = true;
    if (deck != null) _requestedCard = groupKey;
    requestedDeck.value = deck ?? requestedDeck.value ?? '';
    Navigator.of(context).popUntil((r) => r.isFirst);
    MainTabSwitcher.select?.call(NavigationTabId.reel);
  }

  /// Set once the Fold's On TV mode has opened the Reel: the phone is
  /// driving it and can't press OK on the TV, so the first-run intro waits
  /// until the next launch rather than hold the TV's Reel back.
  static bool _introDeferred = false;

  @visibleForTesting
  static set debugIntroDeferred(bool value) => _introDeferred = value;

  /// Widget tests: the phone feed's players, in place of the plugin's (which
  /// can't open a clip in a test, so every clip there fails).
  @visibleForTesting
  static FeedVideo Function(Uri uri)? debugFeedVideo;

  /// Back after longer than this away (a long standby): the Reel starts
  /// afresh, as a tab hidden and shown again does, rather than resuming a
  /// clip core and connections that may have died meanwhile.
  static const Duration longAway = Duration(minutes: 30);

  /// The longest building the session may take before the screen says it
  /// couldn't open, with Retry. A build that lands later is still taken.
  static const Duration createLimit = Duration(seconds: 30);

  /// The wall clock the away time is read from (tests).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @override
  State<ReelScreen> createState() => ReelScreenState();
}

class ReelScreenState extends State<ReelScreen> with WidgetsBindingObserver, TabVisibilityAware, FocusableTab {
  ReelController? _controller;

  /// The session build in flight, and when it began. Each start waits on
  /// it bounded by what is left of [ReelScreen.createLimit], so no start
  /// (after a suspend, a resume or a retry) waits on it for good; once it
  /// is that old, the next start builds afresh, and the old build, should
  /// it ever land, is let go.
  ({Future<ReelController> made, DateTime at})? _building;

  /// When the app last left the foreground (any state but resumed), until
  /// it is back ([ReelScreen.longAway]).
  DateTime? _awaySince;

  /// TV: OK pressed to retry a stuck card; its key up is this screen's too.
  bool _retryKeyDown = false;

  /// The last attempt to build the session failed: a message with Retry
  /// shows instead of a curtain that never lifts.
  bool _createFailed = false;

  /// TV: the clip was paused (not released) for an `inactive` app, and
  /// plays on when the app is resumed.
  bool _heldInactive = false;

  /// TV: that pause, which may still be on its way when the app is resumed.
  Future<void> _holding = Future<void>.value();
  bool _shown = false;
  String? _pendingDeck;
  String? _pendingCard;
  final FocusNode _focus = FocusNode(debugLabel: 'reel');
  final DpadSelectLongPressController _longPress = DpadSelectLongPressController();
  bool _sheetOpen = false;

  /// TV: ↑ / ↓ with a held key's repeats coalesced into one landing (V2-66).
  late final ReelHeldStep _held = ReelHeldStep(cursor: () => ReelHeldStep.cursorOf(_controller), step: _stepBy);

  /// TV: quiet mode, the hint rule and the pause feedback (V2-28).
  final ReelLeanBack _leanBack = ReelLeanBack();

  /// Watch handed over to the player: coming back is the same session
  /// (unless the app went away meanwhile: [didChangeAppLifecycleState]).
  bool _toWatch = false;

  /// A page the Reel opened itself (Watch, Details, its settings, Arrange
  /// decks) is covering it: coming back is the same visit, so the TV's sound
  /// stays as the viewer left it instead of starting muted again (unless
  /// the app went away meanwhile).
  bool _ownPage = false;

  /// How the next visit's sound starts, settled in [_visit] and taken by
  /// the controller in [_start] before its first card plays. It is kept
  /// while the build runs, so a build that lands after the screen gave up
  /// on it ([ReelScreen.createLimit]), or the one Retry makes, still starts
  /// the way the visit settled. [_release] keeps it too: a build that lands
  /// while the app is away still starts the session, and the resume that
  /// follows finds it playing and settles no sound of its own. The next
  /// visit settles it afresh ([_visit]).
  bool? _visitMuted;

  /// TV: bumped each time the viewer turns the sound on, for the badge's
  /// "Sound on" ([ReelSoundBadge]).
  final ValueNotifier<int> _soundOn = ValueNotifier(0);

  /// The first-run intro (V2-55), until it is dismissed on this device.
  /// While it shows, the session is built but not started: nothing plays,
  /// nothing is recorded, and no card slot is taken.
  bool _introUnseen = !(SettingsService.instanceOrNull?.read(SettingsService.reelIntroSeen) ?? true);
  bool get _intro => _introUnseen && !ReelScreen._introDeferred;

  /// Phone: the feed's players (the TV plays on the native clip core).
  /// They take audio focus unless the sound pref says to mix (V2-22), and
  /// hold the screen on only while a card really plays. A clip plays as
  /// often as the clip-end pref says, then holds (V2-47).
  late final ReelFeedPlayers _players = ReelFeedPlayers(
    // A TMDB trailer plays in YouTube's player page (V2-63), the rest in
    // native players.
    create: (uri) =>
        ReelScreen.debugFeedVideo?.call(uri) ??
        youTubeFeedVideoFor(uri) ??
        PluginFeedVideo(uri, mixWithOthers: ReelSound.mixWithOthers(_startSoundPref)),
    plays: () => ReelController.clipEndPref().plays,
    keepAwake: _awake.setEnabled,
    onLooped: (_) => _controller?.clipEnded(),
    onStarted: (id) => _controller?.clipStarted(id),
    onFailed: (id) => unawaited(_controller?.clipFailed(id)),
    onLeft: (id) => _controller?.clipLeft(id),
  );

  /// Phone: the screen held on while a card plays (V2-22).
  final WakelockController _awake = WakelockController();

  /// This device's sound pref: the TV's own (start muted) or the phone's
  /// (with sound), unless changed on the Reel's settings page.
  ReelStartSound get _startSoundPref {
    final pref = _isTv ? SettingsService.reelTvStartSound : SettingsService.reelStartSound;
    return SettingsService.instanceOrNull?.read(pref) ?? pref.resolvedDefault;
  }

  bool get _isTv => PlatformDetector.isTV();

  /// The debug overlay's tape (V2-07): records only under kDebugMode or
  /// with the hidden developer setting on ([ReelDeveloper], V2-62).
  final ReelPerf _perf = ReelPerf.instance;
  Listenable? _overlayPref;
  ReelFeedProbe? _feedProbe;

  /// TV: what OK does (D12, V2-50). Followed live, so the hint line and the
  /// next press change with the setting.
  ValueNotifier<ReelOkAction>? _okPref;
  ReelOkAction get _okAction => _okPref?.value ?? ReelOkAction.watch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReelScreen.requestedDeck.addListener(_takeRequest);
    _takeRequest();
    _bindPerf();
    _okPref = SettingsService.instanceOrNull?.listenable(SettingsService.reelOkAction)?..addListener(_onChanged);
  }

  void _bindPerf() {
    _overlayPref = SettingsService.instanceOrNull?.listenableOfAll(ReelDeveloper.prefs)?..addListener(_onOverlayPref);
    _onOverlayPref();
    _perf.ring ??= (read: ReelStore.instance.cached, write: ReelStore.instance.cache);
    _perf.liveDecoders = _liveDecoders;
    if (!_isTv) {
      _feedProbe = ReelFeedProbe(
        _players,
        _perf,
        deckId: () => _controller?.deck.id,
        origin: () => _controller?.current.clip?.source.origin.name,
      );
    }
  }

  void _onOverlayPref() {
    final on = ReelDeveloper.on();
    _perf.overlay.value = on;
    _perf.recording = kDebugMode || on;
  }

  /// TV: the clip core holds the decoder; phone: each player with a picture.
  int _liveDecoders() => _isTv
      ? (_controller?.clips.engine == null ? 0 : 1)
      : _players.held.where((id) => _players.videoFor(id) != null).length;

  void _takeRequest() {
    final deck = ReelScreen.requestedDeck.value;
    if (deck == null) return;
    final card = ReelScreen._requestedCard;
    ReelScreen._requestedCard = null;
    ReelScreen.requestedDeck.value = null;
    if (deck.isNotEmpty) {
      unawaited(openDeck(deck, groupKey: card));
    } else if (_introUnseen && _shown) {
      // An On TV open may have just deferred the intro: start what it held.
      if (!_intro) _beginLeanBack();
      unawaited(_visit('request'));
    }
    if (_introUnseen && mounted) setState(() {});
  }

  /// The intro's Start (OK on the TV): never shown again on this device,
  /// and the Reel starts on the deck it would have.
  void _endIntro() {
    if (!_introUnseen) return;
    setState(() => _introUnseen = false);
    unawaited(SettingsService.instanceOrNull?.write(SettingsService.reelIntroSeen, true));
    _focus.requestFocus();
    if (!_shown) return;
    // The session starts now, so the TV's hint rule counts it from here
    // (V2-28), and its sound is settled first (V2-22).
    _beginLeanBack();
    unawaited(_visit('intro'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(ReelScreen._live, this)) ReelScreen._live = null;
    ReelScreen.requestedDeck.removeListener(_takeRequest);
    ReelScreen.showing.value = false;
    ReelScreen.immersive.value = false;
    _overlayPref?.removeListener(_onOverlayPref);
    _okPref?.removeListener(_onChanged);
    _feedProbe?.dispose();
    _perf.detachFrames();
    _perf.cancel();
    if (_perf.liveDecoders == _liveDecoders) _perf.liveDecoders = null;
    _controller?.removeListener(_onChanged);
    _controller?.toast.removeListener(_onToast);
    _controller?.clips.phase.removeListener(_onPhase);
    _leanBack.dispose();
    _soundOn.dispose();
    _controller?.dispose();
    _focus.dispose();
    _longPress.dispose();
    _held.dispose();
    _players.dispose();
    super.dispose();
  }

  Future<ReelController> _ensure() {
    final c = _controller;
    if (c != null) return Future.value(c);
    final now = ReelScreen.clock();
    var b = _building;
    if (b == null || now.difference(b.at) >= ReelScreen.createLimit) {
      late final Future<ReelController> made;
      made = widget
          .create(context)
          .then(
            (c) {
              if (identical(_building?.made, made)) _building = null;
              return _adopt(c);
            },
            onError: (Object e, StackTrace s) {
              // A failed build is not kept: the next start (Retry, the tab shown
              // again, the app resumed) tries again.
              if (identical(_building?.made, made)) _building = null;
              Error.throwWithStackTrace(e, s);
            },
          );
      b = _building = (made: made, at: now);
    }
    final bounded = b.made.timeout(ReelScreen.createLimit - now.difference(b.at));
    unawaited(
      bounded.then<void>(
        (_) {},
        onError: (Object e) {
          appLogger.w('[ReelLife] the Reel could not open', error: e);
          if (mounted && _controller == null) setState(() => _createFailed = true);
        },
      ),
    );
    return bounded;
  }

  /// A session build landed: it is the screen's, unless the screen has gone
  /// or another build landed first (then it is let go). One that lands
  /// after the screen gave up on it starts the visit it was built for.
  ReelController _adopt(ReelController c) {
    final have = _controller;
    if (!mounted || have != null) {
      if (!identical(have, c)) c.dispose();
      return have ?? c;
    }
    final late = _createFailed;
    setState(() {
      _controller = c..addListener(_onChanged);
      _createFailed = false;
    });
    c.toast.addListener(_onToast);
    // The Reel's art stays within its image-cache budget around the cards
    // the controller keeps (plan §6); [_release] turns the budget off.
    c.artWindow = ReelArt.keep;
    // TV: the next two cards' spotlight art is warmed ahead (plan V2-13);
    // the phone feed registers its own, sized to its pages.
    if (_isTv) {
      c.artPrecache = _precacheTvArt;
      c.clips.phase.addListener(_onPhase);
      _onPhase();
    }
    if (late && _shown) unawaited(_start());
    return c;
  }

  /// Retry after a failed open.
  void _retry() {
    if (mounted) unawaited(_start());
  }

  @override
  void didUpdateWidget(ReelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.offline == widget.offline || !_shown) return;
    appLogger.i('[ReelLife] ${widget.offline ? 'offline: suspended' : 'back online'}');
    if (widget.offline) {
      _release();
    } else {
      // The feed was let go: its sound settles again, as on any visit.
      unawaited(_visit('online'));
    }
  }

  /// Stops the card, lets go of every decoder (rebuilt on the next start)
  /// and of the Reel's art (plan V2-05), so its cards don't stay in the
  /// image cache that Home's artwork shares.
  void _release() {
    _heldInactive = false;
    _held.cancel();
    unawaited(_controller?.suspend());
    unawaited(_players.releaseAll());
    ReelArt.evict();
  }

  /// Starts the Reel afresh, as a tab hidden and shown again does: every
  /// player is let go, nothing still in flight is joined, and the session
  /// starts again on its deck and card. The stuck card's retry, and a
  /// resume after [ReelScreen.longAway].
  void _restart(String why) {
    if (!_shown || widget.offline || _intro) return;
    appLogger.i('[ReelLife] starting afresh ($why)');
    _release();
    unawaited(_visit('restart: $why'));
  }

  Future<void> _precacheTvArt(ReelCardData card, MediaItem item, {required bool clip}) async {
    if (!mounted) return;
    await ReelCardView.precacheArt(context, card, item, clip: clip);
  }

  /// Confirmations ("On the TV tonight") as the app's own snackbar.
  void _onToast() {
    final text = _controller?.toast.value;
    if (mounted && text != null) showAppSnackBar(context, text);
  }

  /// TV only: the card view is drawn from here. The phone feed listens to
  /// the controller itself and each page to its own card (V2-02), so a
  /// swipe doesn't rebuild the whole screen on top of that.
  void _onChanged() {
    if (mounted && _isTv) setState(() {});
  }

  /// TV: only a playing clip lets the card go quiet.
  void _onPhase() => _leanBack.playing = _controller?.clips.phase.value == ClipPhase.playing;

  /// TV: a new visit counts towards the hint rule; back from Watch is the
  /// same visit.
  void _beginLeanBack() {
    if (!_isTv) return;
    if (_toWatch) {
      _toWatch = false;
      _leanBack.begin();
    } else {
      _leanBack.begin(session: ReelLeanBack.countSession(SettingsService.instanceOrNull));
    }
    _onPhase();
  }

  /// TV: play / pause from a key or the phone, with the player's centre
  /// disc once it lands on the card's own clip.
  Future<void> _transport(ReelController c, TransportCommand command) async {
    await switch (command) {
      TransportCommand.play => c.clips.resume(),
      TransportCommand.pause => c.clips.pause(),
      TransportCommand.toggle => c.togglePause(),
    };
    if (!mounted || !_isTv) return;
    final clip = c.current.clip?.source;
    final phase = c.clips.phase.value;
    if (clip == null || c.clips.current != clip) return;
    if (phase == ClipPhase.paused || phase == ClipPhase.playing) {
      _leanBack.pulse(paused: phase == ClipPhase.paused);
    }
  }

  /// Opens a deck (deep link `plezy://reel?deck=…`, Reel it, On TV mode),
  /// on the card for [groupKey] when given and in the deck.
  ///
  /// A Reel that isn't playing (let go while the app was away) starts a new
  /// visit here, its sound settled as on any; one that is playing only
  /// changes deck, and its sound stays as it is.
  Future<void> openDeck(String deckId, {String? groupKey}) async {
    _pendingDeck = deckId;
    _pendingCard = groupKey;
    if (!_shown) return;
    if (_controller?.active ?? false) return _start();
    await _visit('link');
  }

  ReelController? get controller => _controller;

  /// The visit's sound ([_visitMuted]) is handed to the controller before
  /// its first card plays.
  Future<void> _start() async {
    if (widget.offline) return;
    // Any new attempt (Retry, the tab shown again, back online, resumed)
    // shows the curtain while it builds.
    if (_createFailed && mounted) setState(() => _createFailed = false);
    final ReelController c;
    try {
      c = await _ensure();
    } catch (_) {
      return; // shown as a message with Retry (_ensure)
    }
    // Under the intro the session is ready but waits; a requested deck is
    // kept for when it ends.
    if (!mounted || !_shown || widget.offline || _intro) return;
    final muted = _visitMuted;
    if (muted != null) {
      _visitMuted = null;
      appLogger.d('[ReelLife] the visit starts ${muted ? 'muted' : 'with sound'}');
      await c.setMuted(muted, remember: false);
    }
    if (!mounted || !_shown) return;
    final deck = _pendingDeck, card = _pendingCard;
    _pendingDeck = null;
    _pendingCard = null;
    if (deck != null && c.active) {
      await c.openAt(deck, card);
    } else {
      await c.start(deckId: deck, groupKey: card);
    }
  }

  void _remoteStep(Map<String, dynamic> data) {
    final c = _controller;
    if (c == null || !_shown || widget.offline || _intro) return;
    // Someone at the phone: Lean back keeps rolling (V2-47).
    c.noteInput();
    _held.land();
    _leanBack.poke();
    final dir = data['dir'];
    final deckDir = data['deckDir'];
    if (dir is int && dir != 0) {
      _perf.begin(ReelPerfTrigger.remote);
      unawaited(c.step(dir.sign));
    }
    if (deckDir is int && deckDir != 0) {
      // On Tonight's picks, sideways chooses a pick, as the D-pad does.
      if (c.current.kind == ReelSlotKind.decide) {
        c.movePick(deckDir.sign);
        return;
      }
      _perf.begin(ReelPerfTrigger.deck);
      unawaited(c.switchDeck(deckDir.sign));
    }
  }

  void _remoteAction(String action) {
    final c = _controller;
    if (c == null || !_shown || widget.offline || _intro) return;
    c.noteInput();
    _leanBack.poke();
    // Tonight's picks: a poster tapped on the Fold.
    if (action.startsWith('pick:')) {
      final i = int.tryParse(action.substring(5));
      if (i != null) c.selectPick(i);
      return;
    }
    unawaited(switch (action) {
      'watch' => _watch(),
      'save' => c.save(),
      'notForMe' => c.notForMe(),
      'pause' => _transport(c, TransportCommand.toggle),
      'replay' => c.replay(),
      'spoiled' => c.spoiledMe(),
      'seenIt' => c.seenIt(),
      'details' => _openOwn(c.openDetails),
      'mute' => c.clips.muted ? _turnSoundOn(c, 'remote') : _mute(c, 'remote'),
      'volumeUp' => _louder(c, 1),
      'volumeDown' => _louder(c, -1),
      _ => Future<void>.value(),
    });
  }

  /// On TV mode's volume buttons: the Reel's own level ([ReelVolume]). Up
  /// while muted brings the sound back too.
  Future<void> _louder(ReelController c, int dir) async {
    ReelVolume.adjust(dir);
    if (dir > 0 && c.clips.muted) await _turnSoundOn(c, 'remote');
  }

  /// The viewer turns the sound on ([source]: `key` for ≡ on the TV,
  /// `remote` for On TV mode, `sheet`): kept for the next card (and, with
  /// "With sound", the next launch), rising from silence (ClipPlayer), and
  /// the TV's badge says "Sound on".
  Future<void> _turnSoundOn(ReelController c, String source) async {
    appLogger.i('[ReelSound] sound on (source=$source, level=${ReelVolume.level.value})');
    _soundOn.value++;
    await c.setMuted(false);
  }

  Future<void> _mute(ReelController c, String source) async {
    appLogger.i('[ReelSound] muted (source=$source)');
    await c.setMuted(true);
  }

  /// Opens a page of the Reel's own over it ([open] awaits its route): Back
  /// from it is the same visit ([_ownPage]). The tab shown again takes the
  /// mark; one still hidden when [open] returns keeps it for that, and
  /// nothing opened (no item) drops it.
  Future<void> _openOwn(Future<void> Function() open) async {
    _ownPage = true;
    try {
      await open();
    } finally {
      if (_shown) _ownPage = false;
    }
  }

  @override
  void onTabShown() {
    ReelScreen._live = this;
    _shown = true;
    ReelScreen.showing.value = true;
    _perf.attachFrames();
    // Back from Watch (or another page the Reel opened) is the same visit.
    final back = _toWatch || _ownPage;
    _ownPage = false;
    // Under the first-run intro nothing has started yet ([_endIntro]).
    if (!_intro) _beginLeanBack();
    unawaited(_visit(back ? 'back' : 'tab'));
  }

  /// A visit starts ([why]: the tab shown, which an app launch onto the
  /// Reel and a `plezy://reel` link are too; the app resumed after the
  /// Reel was let go, a Shield woken from standby among them; back online;
  /// the intro ended; started afresh; or `back` from a page the Reel
  /// opened): its sound is settled before any card plays.
  Future<void> _visit(String why) async {
    if (widget.offline) return _start();
    if (_isTv) {
      final screenReader = MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
      final saved = SettingsService.instanceOrNull?.read(SettingsService.reelMuted) ?? false;
      final pref = _startSoundPref;
      final start = ReelSound.tvVisitStart(
        pref: pref,
        saved: saved,
        screenReader: screenReader,
        backFromPage: why == 'back',
      );
      _visitMuted = start.muted;
      final muted = start.muted ?? _controller?.clips.muted;
      appLogger.i('[ReelSound] visit start ($why): ${muted == true ? 'muted' : 'sound on'} because ${start.why}');
      return _start();
    }
    // Phone: only from a feed that was let go. A resume that never paused
    // (the shade pulled down) keeps the sound as it is, and the feed's own
    // clip must not count as other audio. Offline nothing is built (V2-60).
    if (_players.current == null) {
      final muted = await _startSound(why);
      if (muted == null) return;
      _visitMuted = muted;
    }
    await _start();
  }

  /// Phone (V2-22): a visit starts muted when the mute was kept, while the
  /// connected TV is playing, with a screen reader on (V2-54), or, with
  /// "Muted if other audio is playing", while another app's audio plays.
  /// Only the kept mute is saved; the others hold for this visit. The players take it here; the controller
  /// takes it in [_start], once it is built (a failed build shows Retry
  /// there). Null: the visit ended while it looked.
  Future<bool?> _startSound(String visit) async {
    final screenReader = MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    final remote = context.read<CompanionRemoteProvider?>();
    final tvPlaying =
        remote != null && remote.isRemote && remote.isConnected && ReelSound.tvPlaying(remote.nowPlaying.value);
    final saved = SettingsService.instanceOrNull?.read(SettingsService.reelMuted) ?? false;
    final pref = _startSoundPref;
    final otherAudio =
        !saved && !tvPlaying && pref == ReelStartSound.mutedIfOtherAudio && await ReelSound.otherAudioPlaying();
    if (!mounted || !_shown) return null;
    final muted =
        screenReader || ReelSound.startMuted(saved: saved, pref: pref, tvPlaying: tvPlaying, otherAudio: otherAudio);
    final why = ReelSound.phoneWhy(
      muted: muted,
      pref: pref,
      saved: saved,
      screenReader: screenReader,
      tvPlaying: tvPlaying,
    );
    appLogger.i('[ReelSound] visit start ($visit): ${muted ? 'muted' : 'sound on'} because $why');
    await _players.setMuted(muted);
    return muted;
  }

  @override
  void onTabHidden() {
    _shown = false;
    ReelScreen.showing.value = false;
    _perf.detachFrames();
    _leanBack.end();
    _release();
  }

  @override
  void focusActiveTabIfReady() {
    if (mounted) _focus.requestFocus();
  }

  /// Android sends `inactive` on `Activity.onPause` (or without window
  /// focus), then `hidden` and `paused` on `onStop`
  /// (https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html).
  /// Each state is logged so a device session can see which ones the TV's
  /// screensaver sends.
  ///
  /// Back after [ReelScreen.longAway] or more (a long standby), the Reel
  /// starts afresh instead of resuming in place.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    appLogger.i(
      '[ReelLife] app ${state.name} (shown=$_shown, phase=${c?.clips.phase.value.name ?? 'none'}, tv=$_isTv)',
    );
    Duration? away;
    if (state == AppLifecycleState.resumed) {
      final since = _awaySince;
      _awaySince = null;
      if (since != null) away = ReelScreen.clock().difference(since);
    } else {
      _awaySince ??= ReelScreen.clock();
    }
    if (!_shown) {
      // A page the Reel opened covers it (Watch, Details), and the app goes
      // away (Home, standby) or comes back after a long time: Back to the
      // Reel is then a new visit, which the TV starts muted, not the one the
      // viewer left with its sound on.
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached ||
          (away != null && away >= ReelScreen.longAway)) {
        _toWatch = false;
        _ownPage = false;
      }
      return;
    }
    if (away != null && away >= ReelScreen.longAway) {
      _restart('back after ${away.inMinutes} min');
      return;
    }
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _release();
      case AppLifecycleState.inactive:
        // TV: pause without releasing, so a screensaver or an overlay that
        // only takes focus costs no cold open when it goes.
        if (_isTv) unawaited(_holdForInactive(c));
      case AppLifecycleState.resumed:
        final held = _heldInactive;
        _heldInactive = false;
        // Nothing was let go (only the focus went: the shade, an overlay, a
        // screensaver): the card goes on as it was. Starting it again would
        // open its clip afresh over the viewer's own pause, and the phone
        // would wait on a first frame its player had already shown.
        if (c != null && c.active) {
          if (held) unawaited(_playOnAfterHold(c));
          return;
        }
        unawaited(_visit('resumed'));
    }
  }

  Future<void> _holdForInactive(ReelController? c) async {
    if (c == null || !c.active || _heldInactive) return;
    final phase = c.clips.phase.value;
    if (phase != ClipPhase.playing && phase != ClipPhase.loading) return;
    _heldInactive = true;
    await (_holding = c.clips.pause());
  }

  /// TV, back from `inactive`: the clip held for it plays on once that pause
  /// has landed, unless something else moved it meanwhile.
  Future<void> _playOnAfterHold(ReelController c) async {
    await _holding;
    if (!mounted || !_shown || !c.active || c.clips.phase.value != ClipPhase.paused) return;
    await c.clips.resume();
  }

  Future<void> _watch({bool onTv = false}) async {
    final c = _controller;
    if (c == null) return;
    ReelScreen.showing.value = false;
    // Two decoders never run at once: the feed lets go before real playback.
    if (!onTv) await _players.releaseAll();
    _toWatch = !onTv;
    final ok = await c.watch(onTv: onTv);
    if (!ok) _toWatch = false;
    // Back from the player: the shell's didPopNext shows the tab again,
    // which restarts the card (onTabShown). Casting never left the Reel.
    if (mounted && _shown && (onTv || !ok)) ReelScreen.showing.value = true;
  }

  /// Fold: connected to a TV as its remote. Read with `select` from build,
  /// so On TV mode and Watch on TV come and go with the connection now that
  /// controller changes no longer rebuild this screen.
  bool _connectedToTv(BuildContext context) => context.select<CompanionRemoteProvider?, bool>(_connected);

  static bool _connected(CompanionRemoteProvider? r) => r != null && r.isRemote && r.isConnected;

  /// Fold: On TV mode, opened on the deck and the card the phone is on.
  void _remoteMode() {
    final c = _controller;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReelRemoteView(deck: c?.deck.id, groupKey: c?.current.card?.title.groupKey),
        ),
      ),
    );
  }

  Future<void> _openSheet() async {
    final c = _controller;
    // Tonight's picks and a deck's intro card have no card to act on.
    final kind = c?.current.kind;
    if (c == null || _sheetOpen || kind == ReelSlotKind.decide || kind == ReelSlotKind.intro) return;
    _sheetOpen = true;
    // Fold, while Watch goes to the TV: "Watch here" plays it on the phone.
    final watchHere = !_isTv && _connected(context.read<CompanionRemoteProvider?>());
    final action = await showReelSheet(context, c, isTv: _isTv, okAction: _okAction, watchHere: watchHere);
    _sheetOpen = false;
    if (!mounted) return;
    // The sheet took the keys: closing it counts as one.
    _leanBack.poke();
    switch (action) {
      case ReelSheetAction.watchHere:
        await _watch();
      case ReelSheetAction.save:
        await c.save();
      case ReelSheetAction.moreLike:
        // The call takes a while; the snackbar says so and the sheet's focus
        // comes back at once.
        unawaited(c.moreLikeThis());
      case ReelSheetAction.watch:
        await _watch();
      case ReelSheetAction.notForMe:
        await c.notForMe();
      case ReelSheetAction.spoiled:
        await c.spoiledMe();
      case ReelSheetAction.seenIt:
        await c.seenIt();
      case ReelSheetAction.details:
        await _openOwn(c.openDetails);
      case ReelSheetAction.sound:
        await (c.clips.muted ? _turnSoundOn(c, 'sheet') : _mute(c, 'sheet'));
      case ReelSheetAction.settings:
        await _openOwn(
          () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReelSettingsScreen())),
        );
      case ReelSheetAction.arrangeDecks:
        await _openOwn(
          () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => reelDecksScreenFor(c))),
        );
      case ReelSheetAction.deck:
        break;
      case null:
        break;
    }
    _focus.requestFocus();
  }

  /// ↑ / ↓: [count] cards at once, in the same turn, so the controller
  /// opens only the card the cursor lands on.
  ///
  /// `[ReelTTFF] key=`: from this step to the landed card's first frame
  /// (V2-01). A held key lands on its key up, so it times from the release
  /// that picked the card.
  void _stepBy(int dir, int count) {
    final c = _controller;
    if (c == null) return;
    _perf.begin(ReelPerfTrigger.key);
    c.clips.markKey(Stopwatch()..start());
    for (var k = 0; k < count; k++) {
      unawaited(c.step(dir));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_intro) return _introKey(event);
    final c = _controller;
    if (c == null || widget.offline) {
      // TV: OK on the failed-open message is its Retry.
      if (c == null && _createFailed && !widget.offline && event.logicalKey.isSelectKey) {
        if (event is KeyDownEvent) _retry();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // Any key is someone there: Lean back's idle stop counts from it (V2-47).
    if (event is KeyDownEvent || event is KeyRepeatEvent) c.noteInput();
    if (_isTv) {
      final retry = _stuckKey(c, event);
      if (retry != null) return retry;
      // V2-50: the remote's and the CEC bridge's codes, for the device
      // session (recorded only with the overlay's tape on).
      if (event is KeyDownEvent && _perf.recording) appLogger.d(reelKeyLogLine(event));
      // V2-28: any key brings the quiet card's chrome back, and still does
      // what it does.
      if (event is KeyDownEvent || event is KeyRepeatEvent) _leanBack.poke();
      final held = _held.handle(event);
      if (held != null) return held;
    }
    final sel = _longPress.handleKeyEvent(
      event,
      isOwnerActive: () => _shown && !_sheetOpen,
      onShortPress: () =>
          unawaited(switch (reelOkTarget(phase: c.clips.phase.value, kind: c.current.kind, okAction: _okAction)) {
            ReelOkTarget.replay => c.replay(),
            ReelOkTarget.nextDeck => c.switchDeck(1),
            ReelOkTarget.retry => c.retryDeck(),
            ReelOkTarget.watch => _watch(),
            ReelOkTarget.details => _openOwn(c.openDetails),
            ReelOkTarget.start => c.step(1),
          }),
      onLongPress: () => unawaited(_openSheet()),
    );
    if (sel != KeyEventResult.ignored) return sel;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final transport = classifyTransportKey(key);
    if (transport != null) {
      unawaited(_transport(c, transport));
      return KeyEventResult.handled;
    }
    // V2-50: every skip key seeks within the clip, every track key moves a
    // card; FF asks for More like this where it is offered (V2-39). A held
    // track key moves one card, and a held FF asks once.
    if (reelMediaKey(key, moreLike: c.canMoreLike) case (:final action, :final dir)) {
      switch (action) {
        case ReelMediaKeyAction.seek:
          unawaited(c.clips.seekBy(reelSeekStep * dir));
        case ReelMediaKeyAction.step:
          if (event is KeyDownEvent) _stepBy(dir, 1);
        case ReelMediaKeyAction.moreLike:
          if (event is KeyDownEvent) unawaited(c.moreLikeThis());
      }
      return KeyEventResult.handled;
    }
    // The phone's arrows (a keyboard) step on every press and repeat.
    if (key == LogicalKeyboardKey.arrowDown) {
      _stepBy(1, 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _stepBy(-1, 1);
    } else if ((key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowLeft) &&
        c.current.kind == ReelSlotKind.decide) {
      // Tonight's picks: left and right choose; ↓ goes on, then → decks.
      c.movePick(key == LogicalKeyboardKey.arrowRight ? 1 : -1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _perf.begin(ReelPerfTrigger.deck);
      c.clips.markKey(Stopwatch()..start(), trigger: 'deck');
      unawaited(c.switchDeck(1));
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _perf.begin(ReelPerfTrigger.deck);
      c.clips.markKey(Stopwatch()..start(), trigger: 'deck');
      unawaited(c.switchDeck(-1));
    } else if (key.isContextMenuKey) {
      // TV: ≡ on a muted card turns the sound on (the badge says so); with
      // the sound on it opens the sheet, as hold OK always does. A held ≡
      // acts once.
      if (event is KeyDownEvent) {
        unawaited(_isTv && c.clips.muted ? _turnSoundOn(c, 'key') : _openSheet());
      }
    } else {
      // Back and everything else go on to the shell (Back → the rail).
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// TV, on a stuck card ([ReelController.stuck]): OK starts afresh, and ↓
  /// goes on to the next card (or starts afresh when the deck never loaded,
  /// so there is no next card). The OK's key up is swallowed with it. Null:
  /// the key goes on as usual.
  KeyEventResult? _stuckKey(ReelController c, KeyEvent event) {
    final key = event.logicalKey;
    if (_retryKeyDown && key.isSelectKey) {
      if (event is KeyUpEvent) _retryKeyDown = false;
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      // A fresh press: the last one's key up never came here.
      _retryKeyDown = false;
    }
    if (c.stuck.value == null || event is! KeyDownEvent || _sheetOpen) return null;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!key.isSelectKey && !(down && c.cards == null)) return null;
    _retryKeyDown = key.isSelectKey;
    _restart('retry');
    return KeyEventResult.handled;
  }

  /// TV keys under the intro: a fresh OK press starts the Reel (on the
  /// press, so the release of the OK that opened the tab can't), the
  /// d-pad stays here, and Back goes on to the shell.
  KeyEventResult _introKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key.isSelectKey) {
      if (event is KeyDownEvent) _endIntro();
      return KeyEventResult.handled;
    }
    return key.isDpadDirection ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final Widget body = widget.offline
        ? ReelMessage(
            icon: Symbols.cloud_off_rounded,
            title: t.reel.status.offlineTitle,
            body: t.reel.status.offlineBody,
          )
        : c == null
        ? (_createFailed
              ? _failed()
              : _isTv
              ? const ReelTvSkeleton()
              : const ReelCurtain())
        : Stack(
            fit: StackFit.expand,
            children: [
              _isTv ? _tv(c) : _phone(c),
              // The stuck-card watchdog's notice and retry.
              ReelStuckLayer(controller: c, tv: _isTv, onRetry: () => _restart('retry')),
              ValueListenableBuilder<bool>(
                valueListenable: _perf.overlay,
                builder: (context, on, _) => on ? _debugOverlay(c) : const SizedBox.shrink(),
              ),
            ],
          );
    // The first-run intro (V2-55) stands in for the feed; offline says so
    // first.
    final content = _intro && !widget.offline ? ReelIntro(tv: _isTv, onStart: _endIntro) : body;
    return Focus(
      focusNode: _focus,
      autofocus: false,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: Colors.transparent,
        // V2-24: the phone feed, its loading curtain and the intro included,
        // is always dark.
        child: _isTv
            ? content
            : ReelFeedTheme(
                palette: context.select<ThemeProvider?, MonoPalette?>((t) => t?.activePalette),
                child: content,
              ),
      ),
    );
  }

  /// The session could not be built: say so, with Retry.
  Widget _failed() => ReelMessage(
    icon: Symbols.error_outline_rounded,
    title: t.reel.status.openFailedTitle,
    body: _isTv ? t.reel.status.openFailedBodyTv : t.reel.status.openFailedBodyPhone,
    action: FilledButton.tonalIcon(
      onPressed: _retry,
      icon: const Icon(Symbols.refresh_rounded),
      label: Text(t.reel.status.retry),
    ),
  );

  /// V2-07: the debug overlay; on the TV it follows the clip core, which is
  /// rebuilt after every release.
  Widget _debugOverlay(ReelController c) {
    if (!_isTv) return ReelDebugOverlay(perf: _perf, tv: false);
    return ValueListenableBuilder<ClipPhase>(
      valueListenable: c.clips.phase,
      builder: (context, _, _) => ReelDebugOverlay(perf: _perf, tv: true, player: c.clips.engine?.player),
    );
  }

  /// While ↑ / ↓ is held the card view shows where the hold has got to
  /// (its title and artwork over the clip still playing); the clip opens
  /// once the key comes up.
  Widget _tv(ReelController c) => Stack(
    fit: StackFit.expand,
    children: [
      ValueListenableBuilder<int?>(
        valueListenable: _held.preview,
        builder: (context, to, _) => ReelCardView(
          controller: c,
          slot: to == null ? c.current : c.slotAt(to),
          tv: true,
          onReplay: c.replay,
          leanBack: _leanBack,
          okAction: _okAction,
          onWatch: () => unawaited(_watch()),
        ),
      ),
      ReelPauseFeedback(controller: c, leanBack: _leanBack),
      // The sound at a glance: every TV visit starts muted.
      ReelSoundBadge(controller: c, soundOn: _soundOn),
      ReelDeckStrip(controller: c),
    ],
  );

  Widget _phone(ReelController c) {
    final onTv = _connectedToTv(context);
    return ReelFeedView(
      controller: c,
      players: _players,
      watchOnTv: onTv,
      onWatch: () => unawaited(_watch(onTv: onTv)),
      onSheet: () => unawaited(_openSheet()),
      onDecks: () => unawaited(showReelDeckPicker(context, c)),
      onRemote: onTv ? _remoteMode : null,
      // V2-65: a Fold screen switch is timed to the picture moving again.
      onResize: () => _feedProbe?.screenChanged(),
      // V2-31: Back in the immersive feed is the feed's, not the shell's.
      onImmersive: (on) => ReelScreen.immersive.value = on,
    );
  }
}
