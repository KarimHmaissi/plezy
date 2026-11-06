import 'dart:async';
import 'dart:io' show Platform;

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
import '../../services/memory_trim_policy.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_controller.dart';
import '../../services/reel/reel_perf.dart';
import '../../services/reel/reel_store.dart';
import '../../services/reel/reel_volume.dart';
import '../../services/settings_service.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../settings/reel_settings_screen.dart';
import '../../services/reel/feed_players.dart';
import 'reel_card_view.dart';
import 'reel_debug_overlay.dart';
import 'reel_feed_view.dart';
import 'reel_intro.dart';
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

  @override
  State<ReelScreen> createState() => ReelScreenState();
}

class ReelScreenState extends State<ReelScreen> with WidgetsBindingObserver, TabVisibilityAware, FocusableTab {
  ReelController? _controller;
  Future<ReelController>? _creating;
  bool _shown = false;
  String? _pendingDeck;
  String? _pendingCard;
  final FocusNode _focus = FocusNode(debugLabel: 'reel');
  final DpadSelectLongPressController _longPress = DpadSelectLongPressController();
  bool _sheetOpen = false;

  /// The first-run intro (V2-55), until it is dismissed on this device.
  /// While it shows, the session is built but not started: nothing plays,
  /// nothing is recorded, and no card slot is taken.
  bool _introUnseen = !(SettingsService.instanceOrNull?.read(SettingsService.reelIntroSeen) ?? true);
  bool get _intro => _introUnseen && !ReelScreen._introDeferred;

  /// Phone: the feed's players (the TV plays on the native clip core).
  late final ReelFeedPlayers _players = ReelFeedPlayers(
    onLooped: (_) => _controller?.clipEnded(),
    onStarted: (id) => _controller?.clipStarted(id),
    onFailed: (id) => _controller?.clipFailed(id),
  );

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
    final card = ReelScreen._requestedCard;
    ReelScreen._requestedCard = null;
    ReelScreen.requestedDeck.value = null;
    if (deck.isNotEmpty) {
      unawaited(openDeck(deck, groupKey: card));
    } else if (_introUnseen && _shown) {
      // An On TV open may have just deferred the intro: start what it held.
      unawaited(_start());
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
    if (_shown) unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(ReelScreen._live, this)) ReelScreen._live = null;
    ReelScreen.requestedDeck.removeListener(_takeRequest);
    ReelScreen.showing.value = false;
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

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Opens a deck (deep link `plezy://reel?deck=…`, Reel it, On TV mode),
  /// on the card for [groupKey] when given and in the deck.
  Future<void> openDeck(String deckId, {String? groupKey}) async {
    _pendingDeck = deckId;
    _pendingCard = groupKey;
    if (_shown) await _start();
  }

  ReelController? get controller => _controller;

  Future<void> _start() async {
    final c = await _ensure();
    // Under the intro the session is ready but waits; a requested deck is
    // kept for when it ends.
    if (!mounted || !_shown || _intro) return;
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
    if (c == null || !_shown || _intro) return;
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
    if (c == null || !_shown || _intro) return;
    unawaited(switch (action) {
      'watch' => _watch(),
      'save' => c.save(),
      'notForMe' => c.notForMe(),
      'pause' => c.togglePause(),
      'replay' => c.replay(),
      'spoiled' => c.spoiledMe(),
      'seenIt' => c.seenIt(),
      'details' => c.openDetails(),
      'mute' => c.setMuted(!c.clips.muted),
      'volumeUp' => _louder(c, 1),
      'volumeDown' => _louder(c, -1),
      _ => Future<void>.value(),
    });
  }

  /// On TV mode's volume buttons: the Reel's own level ([ReelVolume]). Up
  /// while muted brings the sound back too.
  Future<void> _louder(ReelController c, int dir) async {
    ReelVolume.adjust(dir);
    if (dir > 0 && c.clips.muted) await c.setMuted(false);
  }

  @override
  void onTabShown() {
    ReelScreen._live = this;
    _shown = true;
    ReelScreen.showing.value = true;
    _perf.attachFrames();
    unawaited(_start());
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
      unawaited(_start());
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

  /// Fold: connected to a TV as its remote. Watched from build, so On TV
  /// mode and Watch on TV come and go with the connection.
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
    if (c == null || _sheetOpen) return;
    _sheetOpen = true;
    // Fold, while Watch goes to the TV: "Watch here" plays it on the phone.
    final watchHere = !_isTv && _connected(context.read<CompanionRemoteProvider?>());
    final action = await showReelSheet(context, c, isTv: _isTv, watchHere: watchHere);
    _sheetOpen = false;
    if (!mounted) return;
    switch (action) {
      case ReelSheetAction.watchHere:
        await _watch();
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
      case ReelSheetAction.settings:
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReelSettingsScreen()));
      case ReelSheetAction.arrangeDecks:
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => reelDecksScreenFor(c)));
      case ReelSheetAction.deck:
        break;
      case null:
        break;
    }
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_intro) return _introKey(event);
    final c = _controller;
    if (c == null) return KeyEventResult.ignored;
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
    return Focus(
      focusNode: _focus,
      autofocus: false,
      onKeyEvent: _onKey,
      child: _intro
          ? ReelIntro(tv: _isTv, onStart: _endIntro)
          : ColoredBox(
              color: Colors.transparent,
              child: c == null
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
                    ),
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
    final onTv = _connectedToTv(context);
    return ReelFeedView(
      controller: c,
      players: _players,
      watchOnTv: onTv,
      onWatch: () => unawaited(_watch(onTv: onTv)),
      onSheet: () => unawaited(_openSheet()),
      onDecks: () => unawaited(showReelDeckPicker(context, c)),
      onRemote: onTv ? _remoteMode : null,
    );
  }
}
