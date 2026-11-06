import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../customisation/customisation_store.dart';
import '../customisation/mirror_store.dart';
import '../memory_trim_policy.dart';
import '../settings_service.dart' show ReelCellular, SettingsService;
import 'clip_player.dart';
import 'clip_resolver.dart';
import 'reel_data_budget.dart';
import 'reel_deck_prefs.dart';
import 'reel_decks.dart';
import 'reel_library.dart';
import 'reel_pool.dart';
import 'reel_store.dart';

/// Metadata and art for a card (one cheap read per card built), through the
/// app's server seam.
abstract interface class ReelMedia {
  Future<MediaItem?> item(String serverId, String ratingKey);

  /// A display-size image URL for [path] on [serverId].
  String? imageUrl(String serverId, String? path, {required int width});
}

/// What the app does when the Reel hands a title over to real playback,
/// which reports normally. Returns false when it couldn't (e.g. the TV
/// isn't reachable for Watch on TV).
typedef ReelWatch = Future<bool> Function(MediaItem item, {required bool onTv});

/// Adds a title to the Plex watchlist (Save's mirror).
typedef ReelWatchlist = Future<bool> Function(MediaItem item);

enum ReelSlotKind { card, poolEnd, empty, loading }

/// A card as the views draw it.
class ReelSlot {
  const ReelSlot._(this.kind, {this.card, this.item, this.clip, this.resolved = false});

  const ReelSlot.loading() : this._(ReelSlotKind.loading);
  const ReelSlot.poolEnd() : this._(ReelSlotKind.poolEnd);
  const ReelSlot.empty() : this._(ReelSlotKind.empty);

  final ReelSlotKind kind;
  final ReelCardData? card;
  final MediaItem? item;
  final ResolvedClip? clip;

  /// The clip ladder ran (a null [clip] then means an AI card).
  final bool resolved;

  bool get isAiCard => resolved && clip == null;
}

/// The Reel's session: decks, the card cursor, resolving two cards ahead and
/// preloading one, the signals, and the hand-over to real playback. The
/// views (TV, phone, Fold remote) only call these methods.
class ReelController extends ChangeNotifier {
  ReelController({
    required this.decks,
    required this.resolver,
    required this.clips,
    required this.store,
    required this.media,
    required this.onWatch,
    required this.addToWatchlist,
    this.onSaved,
    this.reachesTvNow,
    this.deckFor,
    this.onOpen,
    this.externalClips = false,
    this.memoryRestored,
    this.settingsChanged,
    this.cellular,
    this.metered,
    this.linkChanged,
    Listenable? deckPrefsChanged,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       deckPrefsChanged = deckPrefsChanged ?? Listenable.merge([ReelStore.deckPrefsChanged, Customisation.changed]) {
    clips.phase.addListener(_onPhase);
    memoryRestored?.addListener(_onMemoryRestored);
    settingsChanged?.addListener(_onSettingsChanged);
    _wasMetered = metered?.call() ?? false;
    linkChanged?.addListener(_onLinkChanged);
    this.deckPrefsChanged.addListener(_onDeckPrefsChanged);
    decks.forEach(_watchDeck);
  }

  final List<ReelDeck> decks;
  final ClipResolver resolver;
  final ClipPlayer clips;
  final ReelStore store;
  final ReelMedia media;
  final ReelWatch onWatch;
  final ReelWatchlist addToWatchlist;

  /// After a Save: seats the Home row the first time (ReelApp).
  final Future<void> Function()? onSaved;

  /// Whether a Save lands on the TV's Home now: this is the TV, or a phone
  /// writing to (or catching up with) a connected TV. False for a phone on
  /// its own data with no TV connected: the pick reaches the TV when it next
  /// connects. Null means now.
  final bool Function()? reachesTvNow;

  /// Opens the title's own page (the app's detail screen).
  final Future<void> Function(MediaItem item)? onOpen;

  /// Phone: the feed plays each card in its own page ([ReelFeedPlayers]),
  /// so the controller keeps the cursor, resolving and signals but never
  /// drives [clips]. It also never skips past a clip-less card: in a feed
  /// you swipe through, a card that jumps away under your thumb is worse
  /// than a still.
  final bool externalClips;

  /// Fires when the app's memory policy puts its caches back to the device
  /// tier (`MemoryTrimPolicy.restores`): the only thing that brings the
  /// degrade ladder back to 0.
  final Listenable? memoryRestored;

  /// Fires when one of the Reel's settings changes (its settings page,
  /// V2-46). The Reel reads its prefs where it uses them, so a change only
  /// has to reach the views: the controller tells its listeners, and the
  /// next card, clip end or key press follows the new choice without a
  /// restart.
  final Listenable? settingsChanged;

  void _onSettingsChanged() {
    if (_disposed) return;
    appLogger.d('Reel: a setting changed; the views take it up now');
    notifyListeners();
  }

  /// The Reel on mobile data (V2-53, `reel_cellular`). Null reads the
  /// pref's default.
  final ReelCellular Function()? cellular;

  /// Whether the link is cellular only (`OfflineModeProvider.isCellularOnly`).
  /// Null reads as Wi-Fi.
  final bool Function()? metered;

  /// Fires when the link may have changed (the app's connectivity
  /// provider). The views re-sync only when [metered] really moved.
  final Listenable? linkChanged;
  bool _wasMetered = false;

  /// What the Reel may spend on this link now ([ReelDataBudget]): the phone
  /// feed's player window, the clip/still choice and the preload follow it.
  /// Reading it also notes the link the views last acted on, so a change
  /// the link listener missed is still caught at its next tick.
  ReelDataBudget get dataBudget {
    final onCellular = _wasMetered = metered?.call() ?? false;
    return ReelDataBudget.of(cellular?.call() ?? SettingsService.reelCellular.resolvedDefault, metered: onCellular);
  }

  void _onLinkChanged() {
    if (_disposed) return;
    final now = metered?.call() ?? false;
    if (now == _wasMetered) return;
    _wasMetered = now;
    appLogger.i('Reel: ${now ? 'mobile data' : 'off mobile data'}, $dataBudget');
    notifyListeners();
  }

  /// Fires when the deck prefs change (a picker or the Decks screen on this
  /// device, or the other device's arrangement arriving): the pickers and
  /// the deck cycle follow at once.
  final Listenable deckPrefsChanged;

  /// The synced deck arrangement (V2-52), read on the first start.
  ReelDeckPrefs get deckPrefs => _prefs;
  ReelDeckPrefs _prefs = ReelDeckPrefs.none;
  Future<void>? _prefsRead;

  Future<void> _readPrefs() async {
    try {
      final read = await store.deckPrefs();
      if (_disposed || read == _prefs) return;
      _prefs = read;
      notifyListeners();
    } catch (e) {
      appLogger.d('Reel: deck prefs unavailable', error: e);
    }
  }

  void _onDeckPrefsChanged() {
    if (_disposed) return;
    _prefsRead = _readPrefs();
  }

  /// The decks the pickers and → / ← offer, in the user's order: hidden ones
  /// left out, except the deck playing (a link may have opened it).
  List<ReelDeck> get shownDecks => _prefs.shown(decks, _idOf, keep: deck.id);

  static String _idOf(ReelDeck d) => d.id;

  /// Whether [id] is hidden from the pickers and the deck cycle.
  bool isHidden(String id) => _prefs.hidden.contains(id);

  /// The deck → (next deck) goes to, or null with nothing else to show.
  ReelDeck? get nextDeck {
    final shown = shownDecks;
    if (shown.length < 2) return null;
    return shown[(shown.indexOf(deck) + 1) % shown.length];
  }

  /// Moves [id] [by] places among the shown decks (a large negative [by]
  /// pins it to the top).
  Future<void> moveDeck(String id, int by) => _arrange(
    'moveDeck',
    _prefs.moved(known: [for (final d in decks) d.id], among: [for (final d in shownDecks) d.id], id: id, by: by),
  );

  /// Hides [id] from the pickers and the deck cycle, or shows it again. The
  /// last shown deck can't be hidden. Hiding the deck that is playing keeps
  /// it on screen until the next deck change.
  Future<void> hideDeck(String id, {required bool hide}) async {
    if (hide && !_prefs.canHide([for (final d in decks) d.id], id)) return;
    await _arrange('hideDeck', _prefs.withHidden(id, hide: hide));
  }

  Future<void> _arrange(String name, ReelDeckPrefs next) => _act(name, () async {
    await _prefsRead;
    final was = _prefs;
    if (next == was) return;
    _prefs = next;
    notifyListeners();
    try {
      await store.writeDeckPrefs(next, was: was);
    } catch (e) {
      // Not kept: the pickers go back to what is stored.
      if (identical(_prefs, next)) _prefs = was;
      notifyListeners();
      if (e is MirrorReadOnlyException) rethrow;
      appLogger.w('Reel: $name not kept', error: e);
    }
  });

  /// Builds a deck asked for by id that isn't in [decks] yet (an answer
  /// saved after the Reel opened); it joins the end of [decks].
  final Future<ReelDeck?> Function(String id)? deckFor;

  Future<int> _deckIndex(String id) async {
    final i = decks.indexWhere((d) => d.id == id);
    if (i >= 0) return i;
    final made = await deckFor?.call(id).catchError((Object _) => null);
    if (made == null) return -1;
    decks.add(made);
    _watchDeck(made);
    return decks.length - 1;
  }

  /// Listeners on each deck's [ReelDeck.rebuilt], removed on dispose.
  final Map<ReelDeck, VoidCallback> _rebuiltListeners = {};

  void _watchDeck(ReelDeck d) {
    final rebuilt = d.rebuilt;
    if (rebuilt == null || _rebuiltListeners.containsKey(d)) return;
    void listener() => unawaited(_onRebuilt(d));
    _rebuiltListeners[d] = listener;
    rebuilt.addListener(listener);
  }

  final DateTime Function() _clock;

  int _deck = 0;
  final Map<String, List<ReelCardData>> _cards = {};
  final Map<String, int> _cursor = {};
  final Map<String, Future<List<ReelCardData>>> _loading = {};

  /// The day ([ReelPool.dayKey]) each deck's list was loaded on.
  final Map<String, String> _loadedOn = {};
  final Map<String, ResolvedClip?> _clip = {};
  final Set<String> _resolved = {};
  final Map<String, MediaItem?> _item = {};
  final Map<String, Future<void>> _resolving = {};
  bool _active = false;
  bool _firstClip = true;
  bool _clipEnded = false;

  /// The card on screen, and when its clip showed a first frame (the
  /// fatigue clock); null until then. A still (AI) card is seen whole the
  /// moment it is shown.
  String? _cardShown;
  DateTime? _cardSince;

  /// The card's clip failed: how it was left says nothing about the title.
  bool _cardFailed = false;

  /// TV: the clip the card handed to [clips], so a first frame or error
  /// from the outgoing clip (still fading out) isn't taken for this card's.
  String? _cardClip;
  ClipPhase _lastPhase = ClipPhase.idle;

  /// Phone: a parked player can start the moment the feed moves, before
  /// [_show] has the card on screen.
  ({String id, DateTime at})? _feedStarted;
  int _sinceAiCard = 99;
  int _generation = 0;

  /// The deck name shown for 1.5 s after a deck change.
  final ValueNotifier<String?> deckStrip = ValueNotifier(null);
  Timer? _stripTimer;

  /// One-line confirmations ([savedOnTv]).
  final ValueNotifier<String?> toast = ValueNotifier(null);
  Timer? _toastTimer;

  /// Fires on every card change, for On TV mode's `reelState`.
  final ValueNotifier<int> cardChanged = ValueNotifier(0);

  ReelDeck get deck => decks[_deck];
  int get deckIndex => _deck;
  List<ReelCardData>? get cards => _cards[deck.id];
  int get index => _cursor[deck.id] ?? 0;
  bool get active => _active;

  ReelSlot slotAt(int i) {
    final list = cards;
    if (list == null) return const ReelSlot.loading();
    if (list.isEmpty) return const ReelSlot.empty();
    if (i >= list.length) return const ReelSlot.poolEnd();
    final c = list[i];
    return ReelSlot._(
      ReelSlotKind.card,
      card: c,
      item: _item[c.id],
      clip: _clip[c.id],
      resolved: _resolved.contains(c.id),
    );
  }

  ReelSlot get current => slotAt(index);

  /// The next three cards, for the Fold remote.
  List<ReelSlot> get upNext => [for (var i = index + 1; i <= index + 3; i++) slotAt(i)];

  /// Opens the Reel (or comes back to it): loads the deck and plays. The
  /// first start opens [deckId] when given, else the start deck
  /// ([ReelDeckPrefs.start]); later starts keep the deck that was playing.
  Future<void> start({String? deckId}) async {
    _active = true;
    // The degrade ladder carries over: coming back from Watch or another tab
    // says nothing about memory. Only the policy's restore resets it.
    await (_prefsRead ??= _readPrefs());
    if (deckId != null) {
      final i = await _deckIndex(deckId);
      if (i >= 0) _deck = i;
    } else if (!_started) {
      final i = await _startIndex();
      if (i >= 0) _deck = i;
    }
    _started = true;
    _remember();
    // A warm controller on a new day: daily decks (For You) load again, so
    // today's pool (or yesterday's remainder while it builds) replaces the
    // list kept from an earlier day.
    final today = _today();
    for (final d in decks) {
      if (d.daily && _cards.containsKey(d.id) && _loadedOn[d.id] != today) {
        _cards.remove(d.id);
        _cursor.remove(d.id);
      }
    }
    await _ensureDeck(deck);
    if (!_active) return;
    await _show();
  }

  bool _started = false;

  /// The start deck when it is shown: For You, or the deck this device was
  /// last on. Else the first shown deck. -1 leaves the cursor where it is.
  Future<int> _startIndex() async {
    String? want = ReelDeckPrefs.forYouId;
    if (_prefs.start == ReelStartDeck.last) {
      try {
        want = await store.lastDeck();
      } catch (_) {
        want = null;
      }
    }
    if (want != null && !_prefs.hidden.contains(want)) {
      // A last deck may be an answer saved after the list was built.
      final i = _prefs.start == ReelStartDeck.last ? await _deckIndex(want) : decks.indexWhere((d) => d.id == want);
      if (i >= 0) return i;
    }
    final shown = _prefs.shown(decks, _idOf);
    return shown.isEmpty ? -1 : decks.indexOf(shown.first);
  }

  /// The deck id this device last wrote as its last deck.
  String? _remembered;

  /// Keeps the deck playing as this device's last deck (per device, not
  /// synced), for the "Where I left off" start.
  void _remember() {
    if (decks.isEmpty) return;
    final id = deck.id;
    if (id == _remembered) return;
    _remembered = id;
    unawaited(
      store.rememberDeck(id).catchError((Object e) {
        appLogger.d('Reel: last deck not kept', error: e);
      }),
    );
  }

  /// Tab hidden, Home pressed or the app paused: stop and release the
  /// player (it is rebuilt on the next start).
  Future<void> suspend() async {
    _active = false;
    _generation++;
    await _leaveCard();
    await clips.release();
    _firstClip = true;
    notifyListeners();
  }

  Future<List<ReelCardData>> _ensureDeck(ReelDeck d) async {
    final have = _cards[d.id];
    if (have != null) return have;
    final f = _loading[d.id] ??= () async {
      _loadedOn[d.id] = _today();
      try {
        final sw = Stopwatch()..start();
        final raw = await d.load();
        final loadMs = sw.elapsedMilliseconds;
        final loaded = await finishDeck(d, raw, store: store, hasClip: (_) => true);
        appLogger.i(
          '[ReelDeck] ${d.id}: ${loaded.length} cards (load ${loadMs}ms, rules ${sw.elapsedMilliseconds - loadMs}ms)',
        );
        _cards[d.id] = loaded;
        return loaded;
      } catch (e) {
        appLogger.w('Reel: deck ${d.id} failed to load', error: e);
        _cards[d.id] = const [];
        return const <ReelCardData>[];
      } finally {
        unawaited(_loading.remove(d.id));
        notifyListeners();
      }
    }();
    return f;
  }

  String _today() => ReelPool.dayKey(_clock());

  /// A fresh build of [d] landed after its list was loaded. On screen, the
  /// cards up to and including the one showing stay put and the new list
  /// follows them (titles already there are left out), so the cursor and
  /// the phone's page index don't move. A deck that isn't on screen just
  /// takes the new list from its start. A deck not loaded yet reads the new
  /// build when it loads.
  Future<void> _onRebuilt(ReelDeck d) async {
    if (_disposed) return;
    final pending = _loading[d.id];
    if (pending != null) await pending;
    if (_disposed || !_cards.containsKey(d.id)) return;
    final List<ReelCardData> fresh;
    try {
      fresh = await finishDeck(d, await d.load(), store: store, hasClip: (_) => true);
    } catch (e) {
      appLogger.w('Reel: deck ${d.id} rebuild failed to load', error: e);
      return;
    }
    if (_disposed || fresh.isEmpty) return;
    _loadedOn[d.id] = _today();
    final old = _cards[d.id] ?? const <ReelCardData>[];
    if (!identical(deck, d)) {
      _cards[d.id] = fresh;
      _cursor.remove(d.id);
      appLogger.i('[ReelDeck] ${d.id}: rebuilt, ${fresh.length} cards');
      notifyListeners();
      return;
    }
    final at = index;
    final keep = old.take(at + 1).toList();
    final kept = {for (final c in keep) c.id};
    final list = [
      ...keep,
      for (final c in fresh)
        if (!kept.contains(c.id)) c,
    ];
    _cards[d.id] = list;
    appLogger.i('[ReelDeck] ${d.id}: rebuilt, ${list.length} cards (new after card ${keep.length})');
    if (at >= old.length) {
      // It was at the end of the deck (or the deck was empty): the first new
      // card comes on screen.
      if (_active) return _show();
      notifyListeners();
      return;
    }
    notifyListeners();
    if (_active) _prepareAhead(list, 1, _generation);
  }

  /// Next / previous card.
  ///
  /// The target is computed and committed before any await, under the
  /// generation counter, so a held D-pad's repeats coalesce: each one moves
  /// the cursor on from where the last left it, and only the card the
  /// cursor lands on is resolved and opened. Cards passed over were never on
  /// screen, so they record nothing.
  Future<void> step(int dir) async {
    final list = cards;
    if (list == null) return;
    final to = (index + dir).clamp(0, list.length);
    if (to == index) return;
    _cursor[deck.id] = to;
    final gen = ++_generation;
    await _leaveCard();
    // A later step moved the cursor on while this one was leaving: that
    // step shows the card it lands on.
    if (gen != _generation) return;
    await _show(direction: dir);
  }

  /// Next / previous shown deck (wraps), with the deck strip. A hidden
  /// deck opened by a link is left for its shown neighbour.
  Future<void> switchDeck(int dir) async {
    final shown = shownDecks;
    if (shown.length < 2) return;
    var at = (shown.indexOf(deck) + dir) % shown.length;
    if (at < 0) at += shown.length;
    final to = decks.indexOf(shown[at]);
    await _leaveCard();
    _deck = to;
    _remember();
    _showStrip();
    notifyListeners();
    await _ensureDeck(deck);
    await _show();
  }

  Future<void> openDeck(String id) async {
    final i = await _deckIndex(id);
    if (i < 0 || i == _deck) return;
    await _leaveCard();
    _deck = i;
    _remember();
    _showStrip();
    await _ensureDeck(deck);
    await _show();
  }

  void _showStrip() {
    if (_disposed) return;
    deckStrip.value = deck.name;
    _stripTimer?.cancel();
    _stripTimer = Timer(const Duration(milliseconds: 1500), () => deckStrip.value = null);
  }

  void _say(String text) {
    if (_disposed) return;
    toast.value = text;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 3), () => toast.value = null);
  }

  /// Resolves (metadata + clip) a card once; the views redraw when it lands.
  Future<void> _resolve(ReelCardData c) => _resolving[c.id] ??= () async {
    try {
      final (item, clip) = await (
        media.item(c.best.serverId, c.best.ratingKey).catchError((Object _) => null),
        resolver.resolve(c.title),
      ).wait;
      _item[c.id] = item;
      _clip[c.id] = clip;
    } catch (e) {
      appLogger.d('Reel: card resolve failed', error: e);
      _clip[c.id] = null;
    } finally {
      _resolved.add(c.id);
      notifyListeners();
    }
  }();

  Future<void> _show({int direction = 1}) async {
    if (_disposed) return;
    final gen = ++_generation;
    notifyListeners();
    cardChanged.value++;
    final list = cards;
    if (list == null || index >= list.length) {
      if (!externalClips) await clips.pause();
      return;
    }
    final c = list[index];
    await _resolve(c);
    if (gen != _generation || !_active) return;
    // An AI card only with room (at most 1 in 6); otherwise the title waits
    // for another day and the feed moves on.
    if (!externalClips &&
        _clip[c.id] == null &&
        _sinceAiCard < 6 &&
        index + direction >= 0 &&
        index + direction <= list.length) {
      _cursor[deck.id] = index + (direction == 0 ? 1 : direction);
      return _show(direction: direction == 0 ? 1 : direction);
    }
    final clip = _clip[c.id];
    _cardShown = c.id;
    _cardSince = clip == null ? _clock() : null;
    _cardFailed = false;
    _cardClip = null;
    _clipEnded = false;
    if (externalClips) {
      // The feed plays it ([clipStarted]); only the two ahead need resolving.
      final started = _feedStarted;
      _feedStarted = null;
      if (clip != null && started?.id == c.id) _cardSince = started!.at;
    } else if (clip == null) {
      _sinceAiCard = 0;
      await clips.pause();
    } else if (memoryLevel >= 2 || !dataBudget.clips) {
      // Low memory, or Stills only on mobile data: the backdrop as a still,
      // no clip core (and no clock).
      _sinceAiCard++;
    } else {
      _sinceAiCard++;
      _cardClip = clip.source.uri;
      await clips.play(clip.source, first: _firstClip);
      _firstClip = false;
    }
    _prepareAhead(list, direction, gen);
  }

  /// Two ahead: resolve; one ahead (in the swipe direction): preload.
  void _prepareAhead(List<ReelCardData> list, int direction, int gen) {
    for (var k = 1; k <= 2; k++) {
      final j = index + k * (direction < 0 ? -1 : 1);
      if (j >= 0 && j < list.length) unawaited(_resolve(list[j]));
    }
    final ahead = index + (direction < 0 ? -1 : 1);
    if (!externalClips && memoryLevel == 0 && dataBudget.clips && ahead >= 0 && ahead < list.length) {
      final next = list[ahead];
      unawaited(
        _resolve(next).then((_) {
          if (gen == _generation && _active) unawaited(clips.preload(_clip[next.id]?.source));
        }),
      );
    }
  }

  /// TV: the clock starts on this card's first frame (the core moves from
  /// loading to playing only then; a resume from pause doesn't count).
  void _onPhase() {
    final now = clips.phase.value, was = _lastPhase;
    _lastPhase = now;
    final uri = _cardClip;
    if (externalClips || _cardShown == null || uri == null || clips.current?.uri != uri) return;
    if (now == ClipPhase.failed) {
      _cardFailed = true;
    } else if (was == ClipPhase.loading && now == ClipPhase.playing && _cardSince == null && !_cardFailed) {
      _cardSince = _clock();
    }
  }

  /// Phone feed: [cardId]'s player is playing (its position has moved).
  void clipStarted(String cardId) {
    if (!externalClips) return;
    if (cardId != _cardShown) {
      _feedStarted = (id: cardId, at: _clock());
    } else if (_cardSince == null && !_cardFailed) {
      _cardSince = _clock();
    }
  }

  /// Phone feed: [cardId]'s player failed to open or broke mid-play.
  void clipFailed(String cardId) {
    if (externalClips && cardId == _cardShown) _cardFailed = true;
  }

  /// Records how the card was left, timed from its first frame: a quick
  /// skip (<2 s) adds fatigue; 8 s or more is a sample; scrolling past in
  /// between records nothing. Left before the first frame, or after the
  /// clip failed, is a neutral [ReelAction.unplayed].
  Future<void> _leaveCard() async {
    final id = _cardShown, since = _cardSince, failed = _cardFailed;
    _cardShown = null;
    _cardSince = null;
    _cardFailed = false;
    _cardClip = null;
    _feedStarted = null;
    if (id == null) return;
    final deckId = deck.id;
    if (since == null || failed) {
      await store.record(id, ReelAction.unplayed, deck: deckId);
      return;
    }
    final secs = _clock().difference(since).inMilliseconds / 1000;
    if (clips.phase.value == ClipPhase.held || _clipEnded) {
      await store.record(id, ReelAction.toEnd, deck: deckId, seconds: secs.round());
    } else if (secs < 2) {
      await store.record(id, ReelAction.quickSkip, deck: deckId);
    } else if (secs >= 8) {
      await store.record(id, ReelAction.sampled, deck: deckId, seconds: secs.round());
    }
  }

  // ---- actions ----

  /// OK = Watch: pause, show the loading curtain, await the clip core's
  /// dispose, then hand over to real playback (which reports normally).
  Future<bool> watch({bool onTv = false}) async {
    final s = current;
    final c = s.card;
    if (c == null) return false;
    final item = s.item ?? await media.item(c.best.serverId, c.best.ratingKey);
    if (item == null) return false;
    await store.record(c.id, onTv ? ReelAction.watchOnTv : ReelAction.watch, deck: deck.id);
    if (!onTv) {
      _cardShown = null;
      await clips.release();
      _firstClip = true;
    }
    final ok = await onWatch(item, onTv: onTv);
    // The TV couldn't be reached: keep the pick instead, and say where it
    // went (or that it couldn't be kept).
    if (!ok && onTv) await save();
    return ok;
  }

  /// Confirmations that say where a Save went.
  static const String savedOnTv = 'On the TV tonight';
  static const String savedForLater = 'Saved, on the TV next time you connect';
  static const String notConnected = "Couldn't save: not connected to the TV";

  /// Runs a card action that writes the synced Reel data. A phone mirroring
  /// a TV it has lost can't write ([MirrorReadOnlyException]): say so and
  /// leave the card as it was, rather than fail silently. Only the action's
  /// name is logged, never the title.
  Future<void> _act(String name, Future<void> Function() fn) async {
    try {
      await fn();
    } on MirrorReadOnlyException {
      appLogger.w('Reel: $name not kept, not connected to the TV');
      _say(notConnected);
    }
  }

  /// One Save: waits on the TV's Home for 3 days and goes to the Plex
  /// watchlist so it's never lost.
  Future<void> save() => _act('save', () async {
    final s = current;
    final c = s.card;
    if (c == null) return;
    await store.savePick(
      ReelPick(
        titleId: c.id,
        groupKey: c.title.groupKey,
        serverId: c.best.serverId,
        ratingKey: c.best.ratingKey,
        title: c.title.title,
        at: _clock().toUtc(),
        deck: deck.id,
      ),
    );
    await store.record(c.id, ReelAction.save, deck: deck.id);
    unawaited(_mirrorToWatchlist(s.item, c));
    final seat = onSaved;
    if (seat != null) unawaited(seat().catchError((Object _) {}));
    _say((reachesTvNow?.call() ?? true) ? savedOnTv : savedForLater);
  });

  /// Save's watchlist mirror. A card saved before its metadata landed
  /// resolves the item first, as [watch] does, so the mirror isn't skipped.
  Future<void> _mirrorToWatchlist(MediaItem? known, ReelCardData c) async {
    try {
      final item = known ?? await media.item(c.best.serverId, c.best.ratingKey);
      if (item != null) await addToWatchlist(item);
    } catch (_) {
      // The pick is kept either way; the mirror is best effort.
    }
  }

  /// Not for me: the title rests 90 days (never a ban) and the feed moves on.
  Future<void> notForMe() => _act('notForMe', () async {
    final c = current.card;
    if (c == null) return;
    await store.notForMe(c.id);
    await store.record(c.id, ReelAction.notForMe, deck: deck.id);
    _cardShown = null;
    _drop(c);
    await _show();
  });

  /// Spoiled me: bans this asset for good and drops to the next rung.
  Future<void> spoiledMe() => _act('spoiledMe', () async {
    final s = current;
    final c = s.card, clip = s.clip;
    if (c == null || clip == null) return;
    await store.spoiled(c.id, clip.assetId);
    await store.record(c.id, ReelAction.spoiled, deck: deck.id);
    await store.cache('src:${c.title.groupKey}', '');
    unawaited(_resolving.remove(c.id));
    _resolved.remove(c.id);
    _clip.remove(c.id);
    _cardShown = null;
    await _show();
  });

  /// Seen it: a fact, so permanent (and the title leaves unseen-only decks).
  Future<void> seenIt() => _act('seenIt', () async {
    final c = current.card;
    if (c == null) return;
    await store.markFact(c.id, 'seen');
    await store.record(c.id, ReelAction.seenIt, deck: deck.id);
    if (!deck.keepsSeen) {
      _cardShown = null;
      _drop(c);
      await _show();
    }
  });

  void _drop(ReelCardData c) {
    for (final e in _cards.entries) {
      if (e.value.any((x) => x.id == c.id)) _cards[e.key] = [...e.value]..removeWhere((x) => x.id == c.id);
    }
  }

  /// Phone feed: the current card's clip played through once.
  void clipEnded() => _clipEnded = true;

  /// The title's own page.
  Future<void> openDetails() async {
    final s = current;
    final c = s.card;
    final open = onOpen;
    if (c == null || open == null) return;
    final item = s.item ?? await media.item(c.best.serverId, c.best.ratingKey);
    if (item == null) return;
    await store.record(c.id, ReelAction.details, deck: deck.id);
    await open(item);
  }

  Future<void> togglePause() => clips.togglePause();
  Future<void> replay() async {
    final c = current.card;
    if (c != null) await store.record(c.id, ReelAction.replay, deck: deck.id);
    await clips.replay();
  }

  Future<void> setMuted(bool muted) async {
    final c = current.card;
    if (!muted && c != null) await store.record(c.id, ReelAction.unmute, deck: deck.id);
    await clips.setMuted(muted);
    notifyListeners();
  }

  /// How hard the system has asked for memory back (the degrade ladder):
  /// 1 keeps only the card on screen (TV: the preload is dropped; phone: the
  /// feed shrinks to the on-screen player), 2 releases every clip player
  /// and shows stills. It holds across visits until the memory policy
  /// restores ([memoryRestored]).
  int memoryLevel = 0;

  /// The system's memory-pressure callback: one step down the ladder.
  Future<void> trimMemory() => _trimTo(memoryLevel + 1);

  /// One RSS watchdog tick ([MemoryTrimPolicy.onWatchdogTick]). From API 34
  /// a foreground app gets no RUNNING_* trim levels, so on the phone this is
  /// the ladder's main way down: a halved image cache is level 1, a cleared
  /// one level 2.
  Future<void> trimForWatchdog(WatchdogTrim trim) => switch (trim) {
    WatchdogTrim.none => Future<void>.value(),
    WatchdogTrim.halved => _trimTo(1),
    WatchdogTrim.cleared => _trimTo(2),
  };

  /// Steps down to [level]; the ladder never climbs back here.
  Future<void> _trimTo(int level) async {
    final to = level.clamp(0, 2);
    if (to <= memoryLevel) return;
    memoryLevel = to;
    appLogger.w('Reel: memory pressure, level $memoryLevel');
    if (to == 1) {
      if (!externalClips) await clips.dropPreload();
    } else {
      await clips.release();
      _firstClip = true;
    }
    // The phone feed re-syncs its players to the new level.
    notifyListeners();
  }

  /// The policy is back at the device tier: clips and the preload come back
  /// from the next card on (the card on screen keeps its still).
  void _onMemoryRestored() {
    if (memoryLevel == 0 || _disposed) return;
    appLogger.i('Reel: memory restored, ladder back to 0 from $memoryLevel');
    memoryLevel = 0;
    notifyListeners();
  }

  /// The On TV state the TV broadcasts on every card change: what the
  /// Fold's On TV mode shows (`reelState`). Image paths only: the
  /// phone loads them through its own server connection.
  Map<String, Object?> remoteState() {
    final s = current;
    final c = s.card;
    Map<String, Object?>? card(ReelSlot x) => x.card == null
        ? null
        : {
            'id': x.card!.id,
            'title': x.card!.title.title,
            'year': x.card!.best.year,
            'server': x.card!.best.serverId,
            'art': x.item?.artPath,
            'thumb': x.item?.thumbPath,
          };
    return {
      'active': _active,
      'deck': deck.id,
      'deckName': deck.name,
      'decks': [
        for (final d in shownDecks) {'id': d.id, 'name': d.name},
      ],
      'index': index,
      'groupKey': c?.title.groupKey,
      'card': card(s),
      'next': [for (final n in upNext) ?card(n)],
      'playing': clips.phase.value == ClipPhase.playing,
      'poolEnd': s.kind == ReelSlotKind.poolEnd,
    };
  }

  bool _disposed = false;

  /// Resolves and loads finish in the background; one that lands after the
  /// screen went away is dropped.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _generation++;
    clips.phase.removeListener(_onPhase);
    memoryRestored?.removeListener(_onMemoryRestored);
    settingsChanged?.removeListener(_onSettingsChanged);
    linkChanged?.removeListener(_onLinkChanged);
    deckPrefsChanged.removeListener(_onDeckPrefsChanged);
    for (final MapEntry(key: d, value: l) in _rebuiltListeners.entries) {
      d.rebuilt?.removeListener(l);
    }
    _rebuiltListeners.clear();
    _stripTimer?.cancel();
    _toastTimer?.cancel();
    deckStrip.dispose();
    toast.dispose();
    cardChanged.dispose();
    unawaited(clips.release());
    super.dispose();
  }
}
