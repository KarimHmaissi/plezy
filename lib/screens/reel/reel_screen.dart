import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../focus/dpad_select_long_press_controller.dart';
import '../../focus/transport_keys.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/navigation_tabs.dart';
import '../../mixins/tab_visibility_aware.dart';
import '../../providers/companion_remote_provider.dart';
import '../../services/reel/clip_player.dart';
import '../../services/reel/reel_controller.dart';
import '../../utils/platform_detector.dart';
import 'reel_card_view.dart';
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

  /// Opens the Reel tab, on [deck] when given: closes pages above the shell
  /// first so the tab is what shows.
  /// The Reel screen that is showing, for On TV mode's commands.
  static ReelScreenState? _live;

  /// Memory pressure (main.dart): the showing Reel steps down its ladder.
  static void trimMemory({bool severe = false}) {
    final c = _live?._controller;
    if (c != null && c.active) unawaited(c.trimMemory(severe: severe));
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
  final PageController _pages = PageController();
  bool _sheetOpen = false;

  bool get _isTv => PlatformDetector.isTV();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReelScreen.requestedDeck.addListener(_takeRequest);
    _takeRequest();
  }

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
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    _focus.dispose();
    _longPress.dispose();
    _pages.dispose();
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
      return c;
    });
  }

  void _onChanged() {
    if (!mounted) return;
    final c = _controller;
    if (c != null && !_isTv && _pages.hasClients && _pages.page?.round() != c.index) {
      _pages.jumpToPage(c.index);
    }
    setState(() {});
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
    final dir = data['dir'];
    final deckDir = data['deckDir'];
    if (dir is int && dir != 0) unawaited(c.step(dir.sign));
    if (deckDir is int && deckDir != 0) unawaited(c.switchDeck(deckDir.sign));
  }

  void _remoteAction(String action) {
    final c = _controller;
    if (c == null || !_shown) return;
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
    unawaited(_start());
  }

  @override
  void onTabHidden() {
    _shown = false;
    ReelScreen.showing.value = false;
    unawaited(_controller?.suspend());
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
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    }
  }

  Future<void> _watch({bool onTv = false}) async {
    final c = _controller;
    if (c == null) return;
    ReelScreen.showing.value = false;
    final ok = await c.watch(onTv: onTv);
    // Back from the player: the shell's didPopNext shows the tab again,
    // which restarts the card (onTabShown). Casting never left the Reel.
    if (mounted && _shown && (onTv || !ok)) ReelScreen.showing.value = true;
  }

  /// Fold: On TV mode, offered while connected to a TV as its remote.
  VoidCallback? _remoteMode() {
    final remote = context.read<CompanionRemoteProvider?>();
    if (remote == null || !remote.isRemote || !remote.isConnected) return null;
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
      unawaited(c.step(1));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(c.step(-1));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(c.switchDeck(1));
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(c.switchDeck(-1));
    } else if (key == LogicalKeyboardKey.mediaFastForward) {
      unawaited(c.clips.seekBy(const Duration(seconds: 10)));
    } else if (key == LogicalKeyboardKey.mediaRewind) {
      unawaited(c.clips.seekBy(const Duration(seconds: -10)));
    } else if (key == LogicalKeyboardKey.contextMenu) {
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
    return Focus(
      focusNode: _focus,
      autofocus: false,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: Colors.transparent,
        child: c == null ? const ReelCurtain(label: 'The Reel') : (_isTv ? _tv(c) : _phone(c)),
      ),
    );
  }

  Widget _tv(ReelController c) => Stack(
    fit: StackFit.expand,
    children: [
      ReelCardView(controller: c, slot: c.current, tv: true, onReplay: c.replay),
      ReelDeckStrip(controller: c),
      ReelToast(controller: c),
    ],
  );

  Widget _phone(ReelController c) {
    final list = c.cards;
    final count = list == null ? 1 : list.length + 1;
    return Stack(
      fit: StackFit.expand,
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            // The native surface can't slide with the page: hide it while a
            // card is dragged; the next clip shows when the page settles.
            if (n is ScrollStartNotification && n.dragDetails != null) unawaited(c.clips.setVisible(false));
            if (n is ScrollEndNotification) unawaited(c.clips.setVisible(true));
            return false;
          },
          child: PageView.builder(
            controller: _pages,
            scrollDirection: Axis.vertical,
            itemCount: count,
            onPageChanged: (i) => unawaited(c.step(i - c.index)),
            itemBuilder: (context, i) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(c.clips.muted ? c.setMuted(false) : c.togglePause()),
              onDoubleTap: () {
                HapticFeedback.mediumImpact();
                unawaited(c.save());
              },
              onLongPress: () => unawaited(_openSheet()),
              onHorizontalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                if (v.abs() > 300) unawaited(c.switchDeck(v < 0 ? 1 : -1));
              },
              child: ReelCardView(
                controller: c,
                slot: c.slotAt(i),
                tv: false,
                onReplay: c.replay,
                onWatch: () => unawaited(_watch(onTv: true)),
                onSave: () => unawaited(c.save()),
                onRemote: _remoteMode(),
              ),
            ),
          ),
        ),
        ReelDeckChips(controller: c),
        ReelDeckStrip(controller: c),
        ReelToast(controller: c),
      ],
    );
  }
}
