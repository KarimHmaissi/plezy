import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_navigator.dart';
import '../../focus/dpad_select_long_press_controller.dart';
import '../../focus/transport_keys.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/navigation_tabs.dart';
import '../../mixins/tab_visibility_aware.dart';
import '../../providers/companion_remote_provider.dart';
import '../../providers/offline_mode_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/memory_trim_policy.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/reel/reel_perf.dart';
import '../../services/reel/reel_sound.dart';
import '../../services/reel/reel_store.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_theme.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../services/reel/feed_players.dart';
import '../video_player/wakelock_controller.dart';
import 'reel_card_view.dart';
import 'reel_debug_overlay.dart';
import 'reel_feed_view.dart';
import 'reel_remote_view.dart';
import 'reel_sheet.dart';

/// Fork: The Reel. A full-screen feed of trailers and anime openings from
/// the servers, one title per card, grouped into decks like channels.
/// Opening it is the one place video plays unasked; it pauses and releases
/// its player whenever the tab is hidden, a page covers it, or the app goes
/// to the background.
class ReelScreen extends StatefulWidget {
  const ReelScreen({super.key, required this.create});

  /// Builds the session from the app's services (`ReelApp.controller`).
  final Future<ReelController> Function(BuildContext context) create;

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

  /// Opens the Reel tab, on [deck] when given: closes pages above the shell
  /// first so the tab is what shows.
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

  static void open(BuildContext context, {String? deck}) {
    requestedDeck.value = deck ?? requestedDeck.value ?? '';
    Navigator.of(context).popUntil((r) => r.isFirst);
    MainTabSwitcher.select?.call(NavigationTabId.reel);
  }

  @override
  State<ReelScreen> createState() => ReelScreenState();
}

class ReelScreenState extends State<ReelScreen> with WidgetsBindingObserver, TabVisibilityAware, FocusableTab {
  ReelController? _controller;
  Future<ReelController>? _creating;
  bool _shown = false;
  String? _pendingDeck;
  final FocusNode _focus = FocusNode(debugLabel: 'reel');
  final DpadSelectLongPressController _longPress = DpadSelectLongPressController();
  bool _sheetOpen = false;

  /// Phone: the feed's players (the TV plays on the native clip core).
  /// They take audio focus unless the sound pref says to mix (V2-22), and
  /// hold the screen on only while a card really plays. A clip plays as
  /// often as the clip-end pref says, then holds (V2-47).
  late final ReelFeedPlayers _players = ReelFeedPlayers(
    create: (uri) => PluginFeedVideo(uri, mixWithOthers: ReelSound.mixWithOthers(_startSoundPref)),
    plays: () => ReelController.clipEndPref().plays,
    keepAwake: _awake.setEnabled,
    onLooped: (_) => _controller?.clipEnded(),
    onStarted: (id) => _controller?.clipStarted(id),
    onFailed: (id) => _controller?.clipFailed(id),
    onLeft: (id) => _controller?.clipLeft(id),
  );

  /// Phone: the screen held on while a card plays (V2-22).
  final WakelockController _awake = WakelockController();

  ReelStartSound get _startSoundPref =>
      SettingsService.instanceOrNull?.read(SettingsService.reelStartSound) ?? ReelStartSound.sound;

  bool get _isTv => PlatformDetector.isTV();

  /// The debug overlay's tape (V2-07): records only under kDebugMode or
  /// with the hidden developer setting on.
  final ReelPerf _perf = ReelPerf.instance;
  ValueNotifier<bool>? _overlayPref;
  ReelFeedProbe? _feedProbe;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReelScreen.requestedDeck.addListener(_takeRequest);
    _takeRequest();
    _bindPerf();
  }

  void _bindPerf() {
    _overlayPref = SettingsService.instanceOrNull?.listenable(SettingsService.reelDebugOverlay)
      ?..addListener(_onOverlayPref);
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
    final on = _overlayPref?.value ?? false;
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
    ReelScreen.requestedDeck.value = null;
    if (deck.isNotEmpty) unawaited(openDeck(deck));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(ReelScreen._live, this)) ReelScreen._live = null;
    ReelScreen.requestedDeck.removeListener(_takeRequest);
    ReelScreen.showing.value = false;
    ReelScreen.immersive.value = false;
    _overlayPref?.removeListener(_onOverlayPref);
    _feedProbe?.dispose();
    _perf.detachFrames();
    _perf.cancel();
    if (_perf.liveDecoders == _liveDecoders) _perf.liveDecoders = null;
    _controller?.removeListener(_onChanged);
    _controller?.toast.removeListener(_onToast);
    _controller?.dispose();
    _focus.dispose();
    _longPress.dispose();
    _players.dispose();
    super.dispose();
  }

  Future<ReelController> _ensure() {
    final c = _controller;
    if (c != null) return Future.value(c);
    return _creating ??= widget.create(context).then((c) {
      if (!mounted) {
        c.dispose();
        return c;
      }
      setState(() => _controller = c..addListener(_onChanged));
      c.toast.addListener(_onToast);
      return c;
    });
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

  /// Opens a deck (deep link `plezy://reel?deck=…`, Reel it, On TV mode).
  Future<void> openDeck(String deckId) async {
    _pendingDeck = deckId;
    if (_shown) await _start();
  }

  ReelController? get controller => _controller;

  Future<void> _start() async {
    final c = await _ensure();
    if (!mounted || !_shown) return;
    final deck = _pendingDeck;
    _pendingDeck = null;
    if (deck != null && c.active) {
      await c.openDeck(deck);
    } else {
      await c.start(deckId: deck);
    }
  }

  void _remoteStep(Map<String, dynamic> data) {
    final c = _controller;
    if (c == null || !_shown) return;
    // Someone at the phone: Lean back keeps rolling (V2-47).
    c.noteInput();
    final dir = data['dir'];
    final deckDir = data['deckDir'];
    if (dir is int && dir != 0) {
      _perf.begin(ReelPerfTrigger.remote);
      unawaited(c.step(dir.sign));
    }
    if (deckDir is int && deckDir != 0) {
      _perf.begin(ReelPerfTrigger.deck);
      unawaited(c.switchDeck(deckDir.sign));
    }
  }

  void _remoteAction(String action) {
    final c = _controller;
    if (c == null || !_shown) return;
    c.noteInput();
    unawaited(switch (action) {
      'watch' => _watch(),
      'save' => c.save(),
      'notForMe' => c.notForMe(),
      'pause' => c.togglePause(),
      'replay' => c.replay(),
      _ => Future<void>.value(),
    });
  }

  @override
  void onTabShown() {
    ReelScreen._live = this;
    _shown = true;
    ReelScreen.showing.value = true;
    _perf.attachFrames();
    unawaited(_visit());
  }

  /// A visit starts (the tab shown, the app back, Back from the player):
  /// the phone settles how its sound starts before any card plays.
  Future<void> _visit() async {
    // Only from a feed that was let go: a resume that never paused (the
    // shade pulled down) keeps the sound as it is, and the feed's own clip
    // must not count as other audio.
    if (!_isTv && _players.current == null) await _startSound();
    await _start();
  }

  /// Phone (V2-22): a visit starts muted when the mute was kept, while the
  /// connected TV is playing, or, with "Muted if other audio is playing",
  /// while another app's audio plays. Only the kept mute is saved; the
  /// others hold for this visit.
  Future<void> _startSound() async {
    final remote = context.read<CompanionRemoteProvider?>();
    final tvPlaying =
        remote != null && remote.isRemote && remote.isConnected && ReelSound.tvPlaying(remote.nowPlaying.value);
    final saved = SettingsService.instanceOrNull?.read(SettingsService.reelMuted) ?? false;
    final pref = _startSoundPref;
    final otherAudio =
        !saved && !tvPlaying && pref == ReelStartSound.mutedIfOtherAudio && await ReelSound.otherAudioPlaying();
    if (!mounted || !_shown) return;
    final muted = ReelSound.startMuted(saved: saved, pref: pref, tvPlaying: tvPlaying, otherAudio: otherAudio);
    await _players.setMuted(muted);
    final c = await _ensure();
    if (mounted) await c.setMuted(muted, remember: false);
  }

  @override
  void onTabHidden() {
    _shown = false;
    ReelScreen.showing.value = false;
    _perf.detachFrames();
    unawaited(_controller?.suspend());
    unawaited(_players.releaseAll());
  }

  @override
  void focusActiveTabIfReady() {
    if (mounted) _focus.requestFocus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_shown) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      unawaited(_controller?.suspend());
      unawaited(_players.releaseAll());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_visit());
    }
  }

  Future<void> _watch({bool onTv = false}) async {
    final c = _controller;
    if (c == null) return;
    ReelScreen.showing.value = false;
    // Two decoders never run at once: the feed lets go before real playback.
    if (!onTv) await _players.releaseAll();
    final ok = await c.watch(onTv: onTv);
    // Back from the player: the shell's didPopNext shows the tab again,
    // which restarts the card (onTabShown). Casting never left the Reel.
    if (mounted && _shown && (onTv || !ok)) ReelScreen.showing.value = true;
  }

  /// Fold: On TV mode, offered while connected to a TV as its remote. Read
  /// with `select` so connecting or dropping the TV redraws the feed's
  /// buttons now that controller changes no longer rebuild this screen.
  VoidCallback? _remoteMode() {
    final connected = context.select<CompanionRemoteProvider?, bool>((r) => r != null && r.isRemote && r.isConnected);
    if (!connected) return null;
    return () => unawaited(
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReelRemoteView(deck: _controller?.deck.id))),
    );
  }

  Future<void> _openSheet() async {
    final c = _controller;
    if (c == null || _sheetOpen) return;
    _sheetOpen = true;
    final action = await showReelSheet(context, c, isTv: _isTv);
    _sheetOpen = false;
    if (!mounted) return;
    switch (action) {
      case ReelSheetAction.save:
        await c.save();
      case ReelSheetAction.notForMe:
        await c.notForMe();
      case ReelSheetAction.spoiled:
        await c.spoiledMe();
      case ReelSheetAction.seenIt:
        await c.seenIt();
      case ReelSheetAction.details:
        await c.openDetails();
      case ReelSheetAction.deck:
        break;
      case null:
        break;
    }
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final c = _controller;
    if (c == null) return KeyEventResult.ignored;
    // Any key is someone there: Lean back's idle stop counts from it (V2-47).
    if (event is KeyDownEvent || event is KeyRepeatEvent) c.noteInput();
    final sel = _longPress.handleKeyEvent(
      event,
      isOwnerActive: () => _shown && !_sheetOpen,
      onShortPress: () {
        if (c.clips.phase.value == ClipPhase.held) {
          unawaited(c.replay());
        } else if (c.current.kind == ReelSlotKind.poolEnd) {
          unawaited(c.switchDeck(1));
        } else {
          unawaited(_watch());
        }
      },
      onLongPress: () => unawaited(_openSheet()),
    );
    if (sel != KeyEventResult.ignored) return sel;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final transport = classifyTransportKey(key);
    if (transport != null) {
      unawaited(switch (transport) {
        TransportCommand.play => c.clips.resume(),
        TransportCommand.pause => c.clips.pause(),
        TransportCommand.toggle => c.togglePause(),
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _perf.begin(ReelPerfTrigger.key);
      unawaited(c.step(1));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _perf.begin(ReelPerfTrigger.key);
      unawaited(c.step(-1));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _perf.begin(ReelPerfTrigger.deck);
      unawaited(c.switchDeck(1));
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _perf.begin(ReelPerfTrigger.deck);
      unawaited(c.switchDeck(-1));
    } else if (key == LogicalKeyboardKey.mediaFastForward) {
      unawaited(c.clips.seekBy(const Duration(seconds: 10)));
    } else if (key == LogicalKeyboardKey.mediaRewind) {
      unawaited(c.clips.seekBy(const Duration(seconds: -10)));
    } else if (key.isContextMenuKey) {
      unawaited(_openSheet());
    } else {
      // Back and everything else go on to the shell (Back → the rail).
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final Widget body = c == null
        ? const ReelCurtain()
        : Stack(
            fit: StackFit.expand,
            children: [
              _isTv ? _tv(c) : _phone(c),
              ValueListenableBuilder<bool>(
                valueListenable: _perf.overlay,
                builder: (context, on, _) => on ? _debugOverlay(c) : const SizedBox.shrink(),
              ),
            ],
          );
    return Focus(
      focusNode: _focus,
      autofocus: false,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: Colors.transparent,
        // V2-24: the phone feed, its loading curtain included, is always dark.
        child: _isTv
            ? body
            : ReelFeedTheme(palette: context.select<ThemeProvider, MonoPalette>((t) => t.activePalette), child: body),
      ),
    );
  }

  /// V2-07: the debug overlay; on the TV it follows the clip core, which is
  /// rebuilt after every release.
  Widget _debugOverlay(ReelController c) {
    if (!_isTv) return ReelDebugOverlay(perf: _perf, tv: false);
    return ValueListenableBuilder<ClipPhase>(
      valueListenable: c.clips.phase,
      builder: (context, _, _) => ReelDebugOverlay(perf: _perf, tv: true, player: c.clips.engine?.player),
    );
  }

  Widget _tv(ReelController c) => Stack(
    fit: StackFit.expand,
    children: [
      ReelCardView(controller: c, slot: c.current, tv: true, onReplay: c.replay),
      ReelDeckStrip(controller: c),
    ],
  );

  Widget _phone(ReelController c) {
    final remote = _remoteMode();
    final onTv = remote != null;
    return ReelFeedView(
      controller: c,
      players: _players,
      watchOnTv: onTv,
      onWatch: () => unawaited(_watch(onTv: onTv)),
      onSheet: () => unawaited(_openSheet()),
      onDecks: () => unawaited(showReelDeckPicker(context, c)),
      onRemote: remote,
      // V2-65: a Fold screen switch is timed to the picture moving again.
      onResize: () => _feedProbe?.screenChanged(),
      // V2-31: Back in the immersive feed is the feed's, not the shell's.
      onImmersive: (on) => ReelScreen.immersive.value = on,
      // V2-08: on mobile data with no Wi-Fi the feed parks only the next card.
      metered: context.select<OfflineModeProvider?, bool>((p) => p?.isCellularOnly ?? false),
    );
  }
}
