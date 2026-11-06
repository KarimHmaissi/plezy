import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../customisation/mirror_store.dart';
import '../memory_trim_policy.dart';
import 'clip_player.dart';
import 'clip_resolver.dart';
import 'reel_decks.dart';
import 'reel_library.dart';
import 'reel_playback_profile.dart';
import 'reel_pool.dart';
import 'reel_prefetcher.dart';
import 'reel_store.dart';

/// Metadata and art for a card, through the app's server seam.
abstract interface class ReelMedia {
  /// The card's art and text: cache-first, else one lean read (plan V2-03).
  /// Null when there is nothing to show; throws when it couldn't be read.
  Future<MediaItem?> item(String serverId, String ratingKey);

  /// The full, network-first read Watch hands to real playback.
  Future<MediaItem?> fullItem(String serverId, String ratingKey);

  /// A display-size image URL for [path] on [serverId].
  String? imageUrl(String serverId, String? path, {required int width});
}

/// What the app does when the Reel hands a title over to real playback,
/// which reports normally. Returns false when it couldn't (e.g. the TV
/// isn't reachable for Watch on TV).
typedef ReelWatch = Future<bool> Function(MediaItem item, {required bool onTv});

/// Adds a title to the Plex watchlist (Save's mirror).
typedef ReelWatchlist = Future<bool> Function(MediaItem item);

/// Decodes a card's art into the image cache before it shows, with exactly
/// the providers the view will build for it ([clip]: the card has a clip,
/// which on the TV picks the lighter art). Set by the view on screen, which
/// knows its own frame; completes when the art has decoded or failed.
typedef ReelArtPrecache = Future<void> Function(ReelCardData card, MediaItem item, {required bool clip});

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

/// The Reel's session: decks, the card cursor, the prefetch window around the
/// card on screen ([ReelPrefetcher]) and the next card's preload, the
/// signals, and the hand-over to real playback. The views (TV, phone, Fold
/// remote) only call these methods.
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
    this.onActive,
    DateTime Function()? clock,
    ReelPrefetcher? prefetcher,
  }) : _clock = clock ?? DateTime.now,
       _prefetch = prefetcher ?? ReelPrefetcher() {
    clips.phase.addListener(_onPhase);
    memoryRestored?.addListener(_onMemoryRestored);
    resolver.profile?.addListener(_onProfile);
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

  /// Told each time the Reel starts playing or stops ([start], [suspend]),
  /// and once more on [dispose] while it was still active, so whatever
  /// stepped aside for it (the brain's indexer) is always given back.
  final void Function(bool active)? onActive;

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

  /// The one queue for the cards around the one on screen (plan V2-11).
  final ReelPrefetcher _prefetch;

  @visibleForTesting
  ReelPrefetcher get prefetcher => _prefetch;

  /// Warms the next two cards' art (plan V2-13); null while no view is
  /// there to build it.
  ReelArtPrecache? artPrecache;

  /// Cards whose art is warm (`id/clip`), so a card is precached once per
  /// visit. Forgotten on suspend and under memory pressure, which evict it.
  final Set<String> _artWarm = {};

  /// Bumped each time the queue is cleared (Watch, suspend, a deck change,
  /// memory pressure), so an art task already running but still waiting on
  /// its card's clip and text fetches nothing after it.
  int _cleared = 0;

  void _clearPrefetch() {
    _cleared++;
    _prefetch.clear();
  }

  /// The direction of travel (1 down the deck, -1 back up it): which way the
  /// prefetch window and the preload lean.
  int _direction = 1;

  int _deck = 0;
  final Map<String, List<ReelCardData>> _cards = {};
  final Map<String, int> _cursor = {};
  final Map<String, Future<List<ReelCardData>>> _loading = {};

  /// The day ([ReelPool.dayKey]) each deck's list was loaded on.
  final Map<String, String> _loadedOn = {};
  final Map<String, ResolvedClip?> _clip = {};
  final Set<String> _resolved = {};
  final Map<String, MediaItem> _item = {};
  final Map<String, Future<void>> _resolving = {};

  /// Metadata reads in flight. Only an item that landed is kept: a failed
  /// or empty read is asked again the next time the card is needed.
  final Map<String, Future<void>> _itemLoading = {};

  /// Cards whose clip answer was unknown (a server offline, a failed read):
  /// looked up again when the Reel comes back, never cached as a miss.
  final Set<String> _unknown = {};

  /// Per card, the assets that failed to play this session, and the cards
  /// already looked up again after a failure (once each).
  final Map<String, Set<String>> _excluded = {};
  final Set<String> _retried = {};
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

  void _setActive(bool on) {
    if (_active == on) return;
    _active = on;
    try {
      onActive?.call(on);
    } catch (e) {
      appLogger.w('Reel: active hook failed', error: e);
    }
  }

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

  /// Opens the Reel (or comes back to it): loads the deck and plays.
  Future<void> start({String? deckId}) async {
    if (!_active) _comeBack();
    _setActive(true);
    // The degrade ladder carries over: coming back from Watch or another tab
    // says nothing about memory. Only the policy's restore resets it.
    if (deckId != null) {
      final i = await _deckIndex(deckId);
      if (i >= 0) _deck = i;
    }
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

  /// Coming back (first open, resume or tab show): servers that weren't
  /// connected are waited for again, and cards whose answer was unknown
  /// are looked up again when next needed.
  void _comeBack() {
    resolver.resumed();
    for (final id in _unknown) {
      unawaited(_resolving.remove(id));
      _resolved.remove(id);
      _clip.remove(id);
    }
    _unknown.clear();
  }

  /// Tab hidden, Home pressed or the app paused: stop and release the
  /// player (it is rebuilt on the next start).
  Future<void> suspend() async {
    _setActive(false);
    _generation++;
    _clearPrefetch();
    _prefetch.release();
    // The view evicts the Reel's art on suspend: warm it again next visit.
    _artWarm.clear();
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
        // One AnimeThemes batch for the deck's anime shows (plan V2-12);
        // the first card waits for it rather than asking on its own.
        unawaited(resolver.warm([for (final c in loaded) c.title]));
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
    // The new build's anime shows, in one batch (titles already answered
    // are skipped).
    unawaited(resolver.warm([for (final c in fresh) c.title]));
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
    if (_active) {
      _plan(list, _generation);
      _preloadNext(list, _generation);
    }
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

  /// Next / previous deck (wraps), with the deck strip.
  Future<void> switchDeck(int dir) async {
    if (decks.length < 2) return;
    _clearPrefetch();
    await _leaveCard();
    _deck = (_deck + dir) % decks.length;
    if (_deck < 0) _deck += decks.length;
    _showStrip();
    notifyListeners();
    await _ensureDeck(deck);
    await _show();
  }

  Future<void> openDeck(String id) async {
    final i = await _deckIndex(id);
    if (i < 0 || i == _deck) return;
    _clearPrefetch();
    await _leaveCard();
    _deck = i;
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

  /// Resolves a card's clip once. Its art and text are a separate prefetch
  /// stage ([_loadItem]) that never holds the clip (plan V2-03); the views
  /// redraw as each lands.
  Future<void> _resolve(ReelCardData c) => _resolving[c.id] ??= _resolveClip(c);

  Future<void> _resolveClip(ReelCardData c) async {
    try {
      final found = await resolver.lookup(c.title, exclude: _excluded[c.id] ?? const {});
      _clip[c.id] = found.clip;
      found.answer == ClipAnswer.unknown ? _unknown.add(c.id) : _unknown.remove(c.id);
    } catch (e) {
      appLogger.d('Reel: card resolve failed', error: e);
      _clip[c.id] = null;
      _unknown.add(c.id);
    } finally {
      _resolved.add(c.id);
      notifyListeners();
    }
  }

  /// The card's art and text. Kept once they land; a failed or empty read
  /// is never memoised.
  Future<void> _loadItem(ReelCardData c) {
    if (_item.containsKey(c.id)) return Future<void>.value();
    final pending = _itemLoading[c.id];
    if (pending != null) return pending;
    final read = _readItem(c);
    _itemLoading[c.id] = read;
    unawaited(
      read.whenComplete(() {
        if (identical(_itemLoading[c.id], read)) _itemLoading.remove(c.id);
      }),
    );
    return read;
  }

  Future<void> _readItem(ReelCardData c) async {
    try {
      final item = await media.item(c.best.serverId, c.best.ratingKey);
      if (item == null || _disposed) return;
      _item[c.id] = item;
      notifyListeners();
    } catch (e) {
      appLogger.d('Reel: card metadata read failed (${e.runtimeType})');
    }
  }

  Future<void> _show({int direction = 1}) async {
    if (_disposed) return;
    final gen = ++_generation;
    _direction = direction < 0 ? -1 : 1;
    notifyListeners();
    cardChanged.value++;
    final list = cards;
    if (list == null || index >= list.length) {
      _prefetch.release();
      if (list != null) _plan(list, gen);
      if (!externalClips) await clips.pause();
      return;
    }
    final c = list[index];
    // The card's own clip and art start at once; on the TV the cards around
    // it wait until its clip shows a frame (or turns out to be a still).
    if (!externalClips) _prefetch.hold();
    _plan(list, gen);
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
    } else if (memoryLevel >= 2) {
      // Low memory: the backdrop as a still, no clip core (and no clock).
      _sinceAiCard++;
    } else {
      _sinceAiCard++;
      _cardClip = clip.source.uri;
      await clips.play(clip.source, first: _firstClip);
      _firstClip = false;
    }
    _syncHold();
    _preloadNext(list, gen);
  }

  /// Hands the prefetcher the window around the card on screen, nearest
  /// first (0, +1, -1, +2 in the direction of travel), each card's clip
  /// before its art and text, and for +1 and +2 their art decoded last
  /// (plan V2-13). On a metered or offline link, or under memory pressure,
  /// only the card on screen and the next; under memory pressure no art is
  /// decoded ahead.
  void _plan(List<ReelCardData> list, int gen) {
    if (_disposed || gen != _generation) return;
    final lean = memoryLevel >= 1 || resolver.playback.link != ReelLink.unmetered;
    final tasks = <ReelPrefetchTask>[];
    for (final offset in lean ? ReelPrefetcher.leanOffsets : ReelPrefetcher.offsets) {
      final j = index + offset * _direction;
      if (j < 0 || j >= list.length) continue;
      final c = list[j];
      if (!_resolved.contains(c.id)) {
        tasks.add(
          ReelPrefetchTask(
            cardId: c.id,
            offset: offset,
            stage: ReelPrefetchStage.resolve,
            lane: ReelPrefetcher.laneFor(c.title),
            run: () => _resolve(c),
          ),
        );
      }
      if (!_item.containsKey(c.id)) {
        tasks.add(
          ReelPrefetchTask(
            cardId: c.id,
            offset: offset,
            stage: ReelPrefetchStage.metadata,
            lane: c.best.serverId,
            run: () => _loadItem(c),
          ),
        );
      }
      if (offset > 0 && memoryLevel == 0 && artPrecache != null && !_artIsWarm(c)) {
        tasks.add(
          ReelPrefetchTask(
            cardId: c.id,
            offset: offset,
            stage: ReelPrefetchStage.art,
            lane: ReelPrefetcher.artLaneOf(c.best.serverId),
            run: () => _warmArt(c),
          ),
        );
      }
    }
    _prefetch.schedule(gen, tasks);
  }

  /// Whether [c]'s art is warm for the clip answer it has now (an unresolved
  /// card isn't).
  bool _artIsWarm(ReelCardData c) => _resolved.contains(c.id) && _artWarm.contains(_artKey(c));

  String _artKey(ReelCardData c) => '${c.id}/${_clip[c.id] != null}';

  /// The art stage: once the card's clip answer and text are in (the TV's
  /// art depends on both), its art is decoded at the size its view shows
  /// it. Skipped when either is missing, under memory pressure, or once the
  /// queue was cleared (Watch, suspend) or the Reel has gone.
  Future<void> _warmArt(ReelCardData c) async {
    final cleared = _cleared;
    await _prefetch.done(ReelPrefetcher.keyOf(c.id, ReelPrefetchStage.resolve));
    await _prefetch.done(ReelPrefetcher.keyOf(c.id, ReelPrefetchStage.metadata));
    final precache = artPrecache;
    final item = _item[c.id];
    if (_disposed ||
        !_active ||
        cleared != _cleared ||
        memoryLevel != 0 ||
        precache == null ||
        item == null ||
        !_resolved.contains(c.id)) {
      return;
    }
    final key = _artKey(c);
    if (!_artWarm.add(key)) return;
    try {
      await precache(c, item, clip: _clip[c.id] != null);
    } catch (e) {
      _artWarm.remove(key);
      appLogger.d('Reel: art precache failed (${e.runtimeType})');
    }
  }

  /// TV: the next card in the direction of travel is preloaded on the clip
  /// core once the queue has resolved it (unless its server is slow:
  /// [ClipSource.preloadable]).
  void _preloadNext(List<ReelCardData> list, int gen) {
    final ahead = index + _direction;
    if (externalClips || memoryLevel != 0 || ahead < 0 || ahead >= list.length) return;
    final next = list[ahead];
    unawaited(
      _prefetch.done(ReelPrefetcher.keyOf(next.id, ReelPrefetchStage.resolve)).then((_) {
        if (gen != _generation || !_active || memoryLevel != 0 || !_resolved.contains(next.id)) return;
        unawaited(clips.preload(_clip[next.id]?.source));
      }),
    );
  }

  /// TV: the lookahead goes on once the card on screen's clip shows its
  /// first frame, fails, or isn't played (a still).
  void _syncHold() {
    final opening =
        !externalClips &&
        memoryLevel < 2 &&
        _cardShown != null &&
        _cardClip != null &&
        _cardSince == null &&
        !_cardFailed;
    if (!opening) _prefetch.release();
  }

  /// TV: the clock starts on this card's first frame (the core moves from
  /// loading to playing only then; a resume from pause doesn't count).
  void _onPhase() {
    final now = clips.phase.value, was = _lastPhase;
    _lastPhase = now;
    final uri = _cardClip;
    if (externalClips || _cardShown == null || uri == null || clips.current?.uri != uri) return;
    if (now == ClipPhase.failed) {
      unawaited(clipFailed(_cardShown!));
    } else if (was == ClipPhase.loading && now == ClipPhase.playing && _cardSince == null && !_cardFailed) {
      _cardSince = _clock();
      _syncHold();
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

  /// [cardId]'s clip failed to open or broke mid-play (the phone feed's
  /// player, or the TV's clip core). How the card is left then says nothing
  /// about the title. Its cached answer is cleared and it is looked up once
  /// more without the failed asset: the next rung plays, or an AI card.
  Future<void> clipFailed(String cardId) async {
    if (cardId != _cardShown) return;
    _cardFailed = true;
    _syncHold();
    final failed = _clip[cardId];
    final c = cards?.where((x) => x.id == cardId).firstOrNull;
    if (c == null || failed == null || !_retried.add(cardId)) return;
    appLogger.i('Reel: a clip failed to play; looking for another');
    (_excluded[cardId] ??= {}).add(failed.assetId);
    await resolver.forget(c.title);
    unawaited(_resolving.remove(cardId));
    _resolved.remove(cardId);
    _clip.remove(cardId);
    notifyListeners();
    await _resolve(c);
    if (_disposed || !_active || _cardShown != cardId) return;
    final clip = _clip[cardId];
    if (clip == null) {
      // An AI card now: a still, seen whole from here; still neutral.
      if (!externalClips) {
        _sinceAiCard = 0;
        await clips.pause();
      }
      return;
    }
    // The new clip's first frame starts the clock.
    _cardFailed = false;
    _cardSince = null;
    if (externalClips || memoryLevel >= 2) return;
    _cardClip = clip.source.uri;
    _prefetch.hold();
    await clips.play(clip.source, first: _firstClip);
    _firstClip = false;
    _syncHold();
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
    // No Reel prefetch competes with the hand-over, or follows it.
    _clearPrefetch();
    // Watch keeps its full read (file checks, streams): the card's own
    // item may be a lean row. The card's item stands in only when that read
    // fails.
    final item = await media.fullItem(c.best.serverId, c.best.ratingKey).catchError((Object _) => null) ?? s.item;
    if (item == null) {
      // Nothing to hand over: the Reel stays, and so does its window.
      final list = cards;
      if (list != null && _active) _plan(list, _generation);
      return false;
    }
    await store.record(c.id, onTv ? ReelAction.watchOnTv : ReelAction.watch, deck: deck.id);
    if (!onTv) {
      // A card change still on its way stops here: real playback is next.
      _generation++;
      _prefetch.release();
      _cardShown = null;
      await clips.release();
      _firstClip = true;
    }
    final ok = await onWatch(item, onTv: onTv);
    // Watch on TV hands over and the phone's Reel stays: its window comes
    // back, so the next card is still resolved before the swipe.
    if (onTv && _active && !_disposed) {
      final list = cards;
      if (list != null) _plan(list, _generation);
    }
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
    // The queue narrows to the card on screen and the next, and no art is
    // decoded ahead; art warmed so far may be trimmed, so it is forgotten.
    _clearPrefetch();
    _artWarm.clear();
    final list = cards;
    if (list != null) _plan(list, _generation);
    if (to == 1) {
      if (!externalClips) await clips.dropPreload();
    } else {
      await clips.release();
      _firstClip = true;
    }
    _syncHold();
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

  /// The playback profile changed (the Fold switched screens, the network
  /// changed, data saver was turned on): every resolved card except the one
  /// on screen picks its file again, so the next card plays at the new
  /// height. The card on screen keeps its file until it is shown again.
  void _onProfile() {
    if (_disposed) return;
    final onScreen = {?_cardShown, ?current.card?.id};
    var changed = false;
    for (final MapEntry(key: id, value: clip) in _clip.entries.toList()) {
      if (clip == null || onScreen.contains(id)) continue;
      final next = resolver.repick(clip);
      if (identical(next, clip)) continue;
      _clip[id] = next;
      changed = true;
    }
    appLogger.d('Reel: playback profile now ${resolver.playback}');
    if (changed) notifyListeners();
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
        for (final d in decks) {'id': d.id, 'name': d.name},
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
    _setActive(false);
    _generation++;
    clips.phase.removeListener(_onPhase);
    memoryRestored?.removeListener(_onMemoryRestored);
    resolver.profile?.removeListener(_onProfile);
    for (final MapEntry(key: d, value: l) in _rebuiltListeners.entries) {
      d.rebuilt?.removeListener(l);
    }
    _rebuiltListeners.clear();
    _prefetch.dispose();
    _stripTimer?.cancel();
    _toastTimer?.cancel();
    deckStrip.dispose();
    toast.dispose();
    cardChanged.dispose();
    unawaited(clips.release());
    super.dispose();
  }
}
