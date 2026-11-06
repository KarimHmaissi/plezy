import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import '../customisation/customisation_store.dart';
import '../customisation/mirror_store.dart';
import '../memory_trim_policy.dart';
import '../settings_service.dart';
import 'clip_player.dart';
import 'clip_resolver.dart';
import 'reel_data_budget.dart';
import 'reel_decay.dart';
import 'reel_deck_prefs.dart';
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

/// A show's metadata and its next episode (the server's on-deck episode,
/// the one Watch plays) from the card's one metadata read.
typedef ReelItemWithNext = Future<({MediaItem? item, MediaItem? next})> Function(String serverId, String ratingKey);

/// More like this (V2-39): the cards chosen for titles like [seed], or null
/// when none could be found. [skip] are the cards already shown in this
/// deck this session.
typedef ReelMoreLike = Future<List<ReelCardData>?> Function(ReelCardData seed, {required Set<String> skip});

/// What a slot in a deck is: a title's card, the "Tonight's picks" decision
/// card (V2-38), the end of the deck, an empty deck, a deck still loading,
/// or one whose list couldn't be loaded ([failed], V2-27), which is not the
/// same as a deck with nothing in it.
enum ReelSlotKind { card, decide, poolEnd, empty, loading, failed }

/// One of Tonight's picks: a fresh Save and its metadata once read (null
/// until then, or when it couldn't be read).
class ReelDecidePick {
  const ReelDecidePick(this.pick, this.item);

  final ReelPick pick;
  final MediaItem? item;
}

/// How many times a clip plays before it holds (V2-47, D6): null loops it for
/// good. Next card plays it once; the feed or Lean back then moves on.
extension ReelClipEndPlays on ReelClipEnd {
  int? get plays => switch (this) {
    ReelClipEnd.loop => null,
    ReelClipEnd.twiceThenHold => 2,
    ReelClipEnd.nextCard => 1,
  };
}

/// A card as the views draw it.
class ReelSlot {
  const ReelSlot._(
    this.kind, {
    this.card,
    this.item,
    this.clip,
    this.next,
    this.resolved = false,
    this.itemMissed = false,
    this.picks = const [],
    this.pick = 0,
  });

  const ReelSlot.loading() : this._(ReelSlotKind.loading);
  const ReelSlot.poolEnd() : this._(ReelSlotKind.poolEnd);
  const ReelSlot.empty() : this._(ReelSlotKind.empty);
  const ReelSlot.failed() : this._(ReelSlotKind.failed);

  /// The decision card: [picks] newest first, [pick] the one OK watches.
  const ReelSlot.decide(List<ReelDecidePick> picks, int pick) : this._(ReelSlotKind.decide, picks: picks, pick: pick);

  final ReelSlotKind kind;

  /// The decision card's picks, and which one is chosen.
  final List<ReelDecidePick> picks;
  final int pick;

  /// The decision card's chosen pick; null on any other slot.
  ReelDecidePick? get chosen => kind == ReelSlotKind.decide && pick >= 0 && pick < picks.length ? picks[pick] : null;

  final ReelCardData? card;
  final MediaItem? item;
  final ResolvedClip? clip;

  /// A [ReelCardData.resume] card's next episode, once its metadata landed.
  final MediaItem? next;

  /// The clip ladder ran (a null [clip] then means an AI card).
  final bool resolved;

  /// The last metadata read came back empty or failed, and none is in
  /// flight: [item] is not on its way (the TV drops its skeleton). The clip
  /// no longer waits on the metadata (V2-03), so [resolved] says nothing
  /// about [item].
  final bool itemMissed;

  bool get isAiCard => resolved && clip == null;

  /// The episode Watch resumes, for its label: "E4", or "S2 E3" past
  /// season 1. Null when the card isn't a resume card or the episode isn't
  /// known (Watch then reads as usual).
  String? get resumeEpisode {
    final e = next;
    final n = e?.index;
    if (card?.resume != true || e == null || n == null) return null;
    final season = e.parentIndex;
    return season == null || season <= 1 ? t.reel.card.episode(n: n) : t.reel.card.seasonEpisode(season: season, n: n);
  }
}

/// How far a start or a card change has got: the `[ReelStart]` log line and
/// the stuck-card watchdog's `[ReelStuck] stage=` name it.
enum ReelStage {
  /// Nothing started, or suspended.
  idle,

  /// Reading the synced deck arrangement.
  prefs,

  /// Choosing the deck to open (a deck asked for by id may be built).
  deck,

  /// Loading the deck's list, and the fresh picks with it.
  load,

  /// Looking up the card's clip.
  resolve,

  /// The clip core is opening the card's clip (TV).
  open,

  /// Waiting on the clip's first frame (the TV's core, or the phone feed's
  /// player).
  frame,

  /// The clip showed its first frame.
  playing,

  /// Nothing more to wait for: a still (an AI card, Stills only, low
  /// memory), Tonight's picks, the end of the deck, an empty deck or one
  /// that failed to load (each says so itself).
  still,
}

/// A start or card change that showed neither a first frame nor a still
/// within [ReelController.stuckAfter]: the views show the card's art (or a
/// message) with a retry instead of a spinner that never ends.
@immutable
class ReelStuck {
  const ReelStuck({required this.stage, required this.generation, required this.after});

  /// Where it got to.
  final ReelStage stage;
  final int generation;

  /// How long since the start or step that armed the watchdog.
  final Duration after;
}

/// How long each wait on the way to a card may take. Nothing the Reel waits
/// on to start, change cards or open a clip waits for good: after a long
/// standby a stale server connection or a wedged read must end in a
/// failure the views can show, never in a spinner.
@immutable
class ReelTimeouts {
  const ReelTimeouts({
    this.store = const Duration(seconds: 5),
    this.build = const Duration(seconds: 20),
    this.deck = const Duration(seconds: 30),
    this.lookup = const Duration(seconds: 45),
    this.metadata = const Duration(seconds: 20),
    this.art = const Duration(seconds: 10),
  });

  /// Every wait the same (tests).
  const ReelTimeouts.all(Duration d) : store = d, build = d, deck = d, lookup = d, metadata = d, art = d;

  /// A read or write of the Reel's own data (prefs, picks, events).
  final Duration store;

  /// Building a deck asked for by id ([ReelController.deckFor]).
  final Duration build;

  /// A deck's list (For You's gather on a slow day included), and its rules.
  final Duration deck;

  /// A card's clip ladder: a server waited for after a wake (up to 20 s),
  /// then its extras and AnimeThemes.
  final Duration lookup;

  /// A card's art and text.
  final Duration metadata;

  /// Decoding a card's art ahead of it.
  final Duration art;
}

/// The deck strip after a deck change (V2-27): the deck now showing between
/// the ones ← and → go to. [previous] is null with fewer than three decks
/// (it would be [next] again), [next] with fewer than two.
@immutable
class ReelDeckStripState {
  const ReelDeckStripState({this.previous, required this.current, this.next});

  final ReelDeck? previous;
  final ReelDeck current;
  final ReelDeck? next;
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
    this.itemWithNext,
    this.moreLike,
    this.saveMuted,
    this.settingsChanged,
    this.cellular,
    this.metered,
    this.linkChanged,
    Listenable? deckPrefsChanged,
    ReelClipEnd Function()? clipEnd,
    DateTime Function()? clock,
    ReelPrefetcher? prefetcher,
  }) : _clock = clock ?? DateTime.now,
       _clipEnd = clipEnd ?? clipEndPref,
       _prefetch = prefetcher ?? ReelPrefetcher(),
       deckPrefsChanged = deckPrefsChanged ?? Listenable.merge([ReelStore.deckPrefsChanged, Customisation.changed]) {
    clips.phase.addListener(_onPhase);
    clips.onScreen.addListener(_onClipOnScreen);
    memoryRestored?.addListener(_onMemoryRestored);
    resolver.profile?.addListener(_onProfile);
    ReelStore.picksChanged.addListener(_onPicksChanged);
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

  /// Told each time the Reel starts playing or stops ([start], [suspend]),
  /// and once more on [dispose] while it was still active, so whatever
  /// stepped aside for it (the brain's indexer) is always given back.
  final void Function(bool active)? onActive;

  /// A [ReelCardData.resume] card's metadata read: the item and its next
  /// episode in one request. Null: such cards read [ReelMedia.item].
  final ReelItemWithNext? itemWithNext;

  /// More like this (V2-39): finds the cards to insert after the current
  /// one. Null: the action isn't offered.
  final ReelMoreLike? moreLike;

  /// Keeps the mute across launches (V2-22); the saved value is handed to
  /// [clips] when it is built. Null: [SettingsService.reelMuted], the one
  /// pref both the TV and the phone feed start from.
  final Future<void> Function(bool muted)? saveMuted;

  static Future<void> _saveMutedPref(bool muted) async =>
      SettingsService.instanceOrNull?.write(SettingsService.reelMuted, muted);

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
  /// The views read this, so reading it also notes the link they last acted
  /// on, and a change the link listener missed is still caught at its next
  /// tick. The controller's own reads ([_budget]) note nothing, so they
  /// never swallow a change the views have yet to hear of.
  ReelDataBudget get dataBudget {
    _wasMetered = metered?.call() ?? false;
    return _budget;
  }

  ReelDataBudget get _budget => ReelDataBudget.of(
    cellular?.call() ?? SettingsService.reelCellular.resolvedDefault,
    metered: metered?.call() ?? false,
  );

  void _onLinkChanged() {
    if (_disposed) return;
    final now = metered?.call() ?? false;
    if (now == _wasMetered) return;
    _wasMetered = now;
    appLogger.i('Reel: ${now ? 'mobile data' : 'off mobile data'}, $_budget');
    // Stills only: the phone feed lets its players go now, so the card on
    // screen is a still and waits on no first frame (the TV's clip plays
    // on until the next card).
    if (externalClips && !_budget.clips && _cardShown != null) _settle(_generation, playing: false);
    notifyListeners();
  }

  /// Fires when the deck prefs change (a picker or the Decks screen on this
  /// device, or the other device's arrangement arriving): the pickers and
  /// the deck cycle follow at once.
  final Listenable deckPrefsChanged;

  /// The synced deck arrangement (V2-52), read on the first start.
  ReelDeckPrefs get deckPrefs => _prefs;
  ReelDeckPrefs _prefs = ReelDeckPrefs.none;

  /// The prefs read in flight, or the last one that landed. A read that
  /// failed or timed out isn't kept (the next start asks again), and one
  /// still in flight at a suspend is dropped, never joined.
  Future<void>? _prefsRead;
  bool _prefsPending = false;

  /// How long each wait on the way to a card may take.
  @visibleForTesting
  ReelTimeouts timeouts = const ReelTimeouts();

  Future<void> _ensurePrefs() {
    final have = _prefsRead;
    if (have != null) return have;
    final done = Completer<void>();
    _prefsRead = done.future;
    _prefsPending = true;
    done.complete(_readPrefs(done.future));
    return done.future;
  }

  Future<void> _readPrefs(Future<void> self) async {
    try {
      final read = await store.deckPrefs().timeout(timeouts.store);
      if (identical(_prefsRead, self)) _prefsPending = false;
      if (_disposed || read == _prefs) return;
      _prefs = read;
      notifyListeners();
    } catch (e) {
      appLogger.d('Reel: deck prefs unavailable', error: e);
      if (identical(_prefsRead, self)) {
        _prefsRead = null;
        _prefsPending = false;
      }
    }
  }

  void _onDeckPrefsChanged() {
    if (_disposed) return;
    _prefsRead = null;
    unawaited(_ensurePrefs());
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
    final build = deckFor;
    if (build == null) return -1;
    ReelDeck? made;
    try {
      made = await build(id).timeout(timeouts.build);
    } catch (e) {
      appLogger.d('Reel: a deck asked for could not be built (${e.runtimeType})');
    }
    if (made == null) return -1;
    // Built by another call meanwhile.
    final again = decks.indexWhere((d) => d.id == id);
    if (again >= 0) return again;
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

  /// Told the cards whose art the Reel keeps in the image cache on each step,
  /// nearest first (its window, the card on screen first), so the art
  /// budget (`ReelArt.keep`, plan §6) trims around them; null while no view
  /// is there to build art.
  void Function(List<String> cards)? artWindow;

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

  /// The clip-end pref, read when a clip ends so a change applies at once.
  final ReelClipEnd Function() _clipEnd;

  /// What a clip does when it ends (V2-47): the device's pref.
  ReelClipEnd get clipEnd => _clipEnd();

  /// The device's clip-end pref ([SettingsService.reelClipEnd]).
  static ReelClipEnd clipEndPref() =>
      SettingsService.instanceOrNull?.read(SettingsService.reelClipEnd) ?? ReelClipEnd.twiceThenHold;

  /// Lean back (V2-47) stops moving on after this long with no real input,
  /// so a Reel left playing to an empty room holds its card and lets the
  /// screen sleep.
  static const leanBackIdle = Duration(minutes: 30);

  /// The last real input: a key, a touch, a command from the phone, or the
  /// Reel opening. A card moving on by itself is not input.
  DateTime? _lastInput;

  /// The view saw real input ([leanBackIdle]).
  void noteInput() => _lastInput = _clock();

  /// Whether Next card may still move on by itself: there was real input in
  /// the last [leanBackIdle].
  bool get mayRollOn {
    final at = _lastInput;
    return at != null && _clock().difference(at) < leanBackIdle;
  }

  int _deck = 0;
  final Map<String, List<ReelCardData>> _cards = {};
  final Map<String, int> _cursor = {};
  final Map<String, Future<List<ReelCardData>>> _loading = {};

  /// The day ([ReelPool.dayKey]) each deck's list was loaded on.
  final Map<String, String> _loadedOn = {};

  /// Decks whose last load threw: they show a failure, not an empty deck,
  /// and load again on the next visit or on [retryDeck].
  final Set<String> _failed = {};
  final Map<String, ResolvedClip?> _clip = {};
  final Set<String> _resolved = {};
  final Map<String, MediaItem> _item = {};
  final Map<String, MediaItem?> _next = {};
  final Map<String, Future<void>> _resolving = {};

  /// Metadata reads in flight. Only an item that landed is kept: a failed
  /// or empty read is asked again the next time the card is needed.
  final Map<String, Future<void>> _itemLoading = {};

  /// Cards whose last metadata read came back empty or failed, until the
  /// next read starts ([ReelSlot.itemMissed]).
  final Set<String> _itemMissed = {};

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

  // ---- start stages and the stuck-card watchdog ----

  /// How far the latest start or card change has got.
  ReelStage get stage => _stage;
  ReelStage _stage = ReelStage.idle;

  /// Starts so far (the log's `#n`), and the start in flight: a newer start
  /// or a suspend supersedes it, so it stops at its next step.
  int _starts = 0;
  int _startRun = 0;

  /// The latest start whose card hasn't settled yet (its first frame or a
  /// still), so the settle is logged against it; a card change drops it.
  ({int no, int gen, DateTime at})? _startOpen;

  /// How long a start or a card change may go with neither a first frame
  /// nor a still before it counts as stuck ([stuck]); null never times out.
  static const Duration defaultStuckAfter = Duration(seconds: 8);

  @visibleForTesting
  Duration? stuckAfter = defaultStuckAfter;

  /// Set when the watchdog ran out ([ReelStuck]), cleared by the next start,
  /// card change or settle. The views then show the card's art (or a
  /// message) with a retry.
  final ValueNotifier<ReelStuck?> stuck = ValueNotifier(null);
  Timer? _stuckTimer;
  DateTime? _armedAt;

  /// A start or card change began: the watchdog is timed from now.
  void _arm() {
    if (_disposed) return;
    _stuckTimer?.cancel();
    stuck.value = null;
    final after = stuckAfter;
    _armedAt = _clock();
    _stuckTimer = after == null ? null : Timer(after, _onStuck);
  }

  void _disarm() {
    _stuckTimer?.cancel();
    _stuckTimer = null;
    if (!_disposed) stuck.value = null;
  }

  /// The card of generation [gen] showed a first frame ([playing]) or a
  /// still: nothing is stuck. A later card change has its own watchdog.
  void _settle(int gen, {required bool playing}) {
    if (_disposed || gen != _generation) return;
    _stage = playing ? ReelStage.playing : ReelStage.still;
    _disarm();
    final open = _startOpen;
    if (open != null && open.gen == gen) {
      _startOpen = null;
      appLogger.i('[ReelStart] #${open.no} settled stage=${_stage.name} gen=$gen ${_since(open.at)}ms');
    }
  }

  int _since(DateTime at) => _clock().difference(at).inMilliseconds;

  void _onStuck() {
    _stuckTimer = null;
    if (_disposed || !_active) return;
    final at = _armedAt;
    final after = at == null ? Duration.zero : _clock().difference(at);
    appLogger.w(
      '[ReelStuck] stage=${_stage.name} gen=$_generation after=${after.inMilliseconds}ms slot=${current.kind.name}',
    );
    stuck.value = ReelStuck(stage: _stage, generation: _generation, after: after);
  }

  /// The deck strip: up from a deck change until [stripHold] after the
  /// new deck's first card shows (V2-27), so a slow deck keeps its name.
  final ValueNotifier<ReelDeckStripState?> deckStrip = ValueNotifier(null);
  Timer? _stripTimer;

  /// A strip is up and its deck hasn't shown yet: the hold starts then.
  bool _stripPending = false;

  /// [_generation] when the strip went up: only a [_show] started after it
  /// is the new deck's, so a card from the deck before that was still
  /// opening when the deck changed never starts the hold.
  int _stripSince = 0;

  /// How long the strip stays once the deck is on screen.
  static const Duration defaultStripHold = Duration(milliseconds: 1500);

  @visibleForTesting
  Duration stripHold = defaultStripHold;

  /// One-line confirmations ([savedOnTv]).
  final ValueNotifier<String?> toast = ValueNotifier(null);
  Timer? _toastTimer;

  /// Fires on every card change, for On TV mode's `reelState`.
  final ValueNotifier<int> cardChanged = ValueNotifier(0);

  ReelDeck get deck => decks[_deck];
  int get deckIndex => _deck;
  List<ReelCardData>? get cards => _cards[deck.id];

  /// The cursor as a card index into [cards] ([cards].length: the end of
  /// the deck). On the decision card it is the card after it.
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

  // ---- Tonight's picks (V2-38) ----

  /// Saves in a session before the decision card comes up next.
  static const int decideAfterSaves = 2;

  /// The fresh Saves (newest first, at most [ReelPick.maxShown]) as last
  /// read: at start, after each Save and when the decision card shows.
  List<ReelPick> _picks = const [];
  final Map<String, MediaItem?> _pickItem = {};
  final Map<String, Future<void>> _pickReading = {};
  int _saves = 0;
  int _pickAt = 0;

  /// Where the decision card sits once placed: in [deck], before the card
  /// [before] (null: after the last card). Unplaced, it waits at the end of
  /// every deck while there are fresh picks. It comes up at most once a
  /// session: once seen it stays where it was (so the phone's pages hold)
  /// and is never placed again.
  ({String deck, String? before})? _decide;
  bool _decideSeen = false;

  /// The day the decision card's session began: a warm controller (the TV
  /// keeps one for days) starts a new one on its first start of a new day,
  /// so the card isn't spent for good after its first showing.
  String? _decideDay;

  /// Decks whose cursor is on the decision card.
  final Set<String> _onDecide = {};

  /// Where the decision card sits in [list] (deck [deckId]) as a page:
  /// before the card at that index. Null when it isn't in that deck.
  int? _decideAt(String deckId, List<ReelCardData> list) {
    if (list.isEmpty) return null;
    final d = _decide;
    if (d == null) return _decideSeen || _picks.isEmpty ? null : list.length;
    if (d.deck != deckId || (!_decideSeen && _picks.isEmpty)) return null;
    final before = d.before;
    if (before == null) return list.length;
    final j = list.indexWhere((c) => c.id == before);
    return j < 0 ? null : j;
  }

  bool get _onDecideNow {
    final list = cards;
    return list != null && _onDecide.contains(deck.id) && _decideAt(deck.id, list) == index;
  }

  /// The cursor as a page: the card index, counting the decision card when
  /// it sits at or before the cursor. The phone's PageView index.
  int get page {
    final list = cards;
    if (list == null) return 0;
    final at = _decideAt(deck.id, list);
    final i = index;
    if (at == null || i < at) return i;
    return _onDecideNow ? at : i + 1;
  }

  /// How many pages the deck has: its cards, the decision card when it is
  /// in this deck, and the end of the deck.
  int get slotCount {
    final list = cards;
    if (list == null || list.isEmpty) return 1;
    return list.length + 1 + (_decideAt(deck.id, list) == null ? 0 : 1);
  }

  /// Moves the cursor to page [p].
  void _seek(int p) {
    final list = cards;
    if (list == null) return;
    final at = _decideAt(deck.id, list);
    if (at != null && p == at) {
      _cursor[deck.id] = at;
      _onDecide.add(deck.id);
      return;
    }
    _onDecide.remove(deck.id);
    _cursor[deck.id] = at != null && p > at ? p - 1 : p;
  }

  ReelSlot _decideSlot() {
    final picks = [for (final p in _picks) ReelDecidePick(p, _pickItem[p.titleId])];
    return ReelSlot.decide(picks, picks.isEmpty ? 0 : _pickAt.clamp(0, picks.length - 1));
  }

  /// The slot on page [p] (see [page]).
  ReelSlot slotAt(int p) {
    final list = cards;
    if (list == null) return _failed.contains(deck.id) ? const ReelSlot.failed() : const ReelSlot.loading();
    if (list.isEmpty) return const ReelSlot.empty();
    var i = p;
    final at = _decideAt(deck.id, list);
    if (at != null) {
      if (p == at) return _decideSlot();
      if (p > at) i = p - 1;
    }
    if (i >= list.length) return const ReelSlot.poolEnd();
    final c = list[i];
    return ReelSlot._(
      ReelSlotKind.card,
      card: c,
      item: _item[c.id],
      clip: _clip[c.id],
      next: _next[c.id],
      resolved: _resolved.contains(c.id),
      itemMissed: _itemMissed.contains(c.id),
    );
  }

  ReelSlot get current => slotAt(page);

  /// The next three slots, for the Fold remote.
  List<ReelSlot> get upNext {
    final p = page;
    return [for (var i = p + 1; i <= p + 3; i++) slotAt(i)];
  }

  /// Opens the Reel (or comes back to it): loads the deck and plays. The
  /// first start opens [deckId] when given, else the start deck
  /// ([ReelDeckPrefs.start]); later starts keep the deck that was playing.
  /// With [groupKey] (On TV mode), [deckId] opens on that title's card when
  /// its list has it, as [openAt].
  ///
  /// Every wait on the way is bounded ([timeouts]), each start logs the
  /// stage it reached (`[ReelStart]`), and the stuck-card watchdog
  /// ([stuck]) is armed from here.
  Future<void> start({String? deckId, String? groupKey}) async {
    final run = ++_startRun, no = ++_starts, at = _clock();
    _startOpen = null;
    _stage = ReelStage.prefs;
    appLogger.i('[ReelStart] #$no begin gen=$_generation${_active ? ' active' : ''}');
    _arm();
    var outcome = 'threw';
    try {
      outcome = await _startFrom(run, deckId: deckId, groupKey: groupKey);
    } finally {
      final settled = _stage == ReelStage.playing || _stage == ReelStage.still;
      appLogger.i('[ReelStart] #$no $outcome stage=${_stage.name} gen=$_generation ${_since(at)}ms');
      if (outcome == 'shown' && !settled) _startOpen = (no: no, gen: _generation, at: at);
    }
  }

  /// [start]'s steps; what became of it, for the log.
  Future<String> _startFrom(int run, {String? deckId, String? groupKey}) async {
    bool superseded() => _disposed || run != _startRun;
    final leaving = _suspending;
    if (leaving != null) {
      try {
        await leaving;
      } catch (e) {
        appLogger.d('Reel: the last suspend failed', error: e);
      }
      if (superseded()) return 'superseded';
    }
    if (!_active) _comeBack();
    _setActive(true);
    // Opening the Reel (or coming back to it) is someone there.
    noteInput();
    // The picks are synced: the other device may have saved since.
    unawaited(_loadSaved());
    // The degrade ladder carries over: coming back from Watch or another tab
    // says nothing about memory. Only the policy's restore resets it.
    await _ensurePrefs();
    if (superseded()) return 'superseded';
    _stage = ReelStage.deck;
    if (deckId != null) {
      final i = await _deckIndex(deckId);
      if (i >= 0) _deck = i;
    } else if (!_started) {
      final i = await _startIndex();
      if (i >= 0) _deck = i;
    }
    if (superseded()) return 'superseded';
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
        _onDecide.remove(d.id);
      }
    }
    if (_decideDay != today) {
      _decideDay = today;
      _decide = null;
      _decideSeen = false;
      _saves = 0;
      _pickAt = 0;
      _onDecide.clear();
    }
    _stage = ReelStage.load;
    final (list, _) = await (_ensureDeck(deck), _refreshPicks()).wait;
    if (!_active || superseded()) return 'superseded';
    if (deckId != null && deck.id == deckId) _seekTitle(list, groupKey);
    await _show();
    return 'shown';
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

  /// Reads the fresh Saves again (the other device may have saved too).
  Future<void> _refreshPicks() async {
    try {
      _picks = await store.freshPicks().timeout(timeouts.store);
    } catch (e) {
      appLogger.d('Reel: picks unavailable', error: e);
    }
  }

  /// The picks' metadata (at most [ReelPick.maxShown] reads, each once),
  /// read as the decision card comes near; the views redraw as each lands.
  void _readPicks() {
    for (final p in _picks) {
      if (_pickItem.containsKey(p.titleId)) continue;
      _pickReading[p.titleId] ??= () async {
        MediaItem? item;
        try {
          item = await media.item(p.serverId, p.ratingKey).timeout(timeouts.metadata);
        } catch (e) {
          appLogger.d('Reel: pick metadata unavailable', error: e);
        }
        _pickItem[p.titleId] = item;
        notifyListeners();
      }();
    }
  }

  bool _started = false;

  /// The start deck when it is shown: For You, or the deck this device was
  /// last on. Else the first shown deck. -1 leaves the cursor where it is.
  Future<int> _startIndex() async {
    String? want = ReelDeckPrefs.forYouId;
    if (_prefs.start == ReelStartDeck.last) {
      try {
        want = await store.lastDeck().timeout(timeouts.store);
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
  ///
  /// Nothing waited on is kept across it ([_forgetPending]), so the next
  /// start (a tab shown again, a resume, a retry) asks afresh instead of
  /// joining a read that may never come back.
  Future<void> suspend() {
    final f = _suspend();
    _suspending = f;
    unawaited(
      f.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (identical(_suspending, f)) _suspending = null;
      }),
    );
    return f;
  }

  /// The suspend still letting go of the card and the clip core: the next
  /// start waits for it (each of its steps is bounded), so the core it
  /// releases is never the one the start has just opened.
  Future<void>? _suspending;

  Future<void> _suspend() async {
    _setActive(false);
    _generation++;
    // A start still on its way stops at its next step.
    _startRun++;
    _startOpen = null;
    _stage = ReelStage.idle;
    _disarm();
    _forgetPending();
    _clearPrefetch();
    _prefetch.release();
    // The view evicts the Reel's art on suspend: warm it again next visit.
    _artWarm.clear();
    _hideStrip();
    await _leaveCard();
    await clips.release();
    _firstClip = true;
    notifyListeners();
  }

  /// What a suspend leaves behind: no read still in flight (or one that
  /// failed) is joined by the next start. A dropped read that lands later
  /// keeps what it found only where nothing newer has (a deck's list, a
  /// card's item); its failure, and a dropped lookup's answer, are let go.
  void _forgetPending() {
    _loading.clear();
    _resolving.removeWhere((id, _) => !_resolved.contains(id));
    _itemLoading.clear();
    _pickReading.removeWhere((id, _) => !_pickItem.containsKey(id));
    if (_prefsPending) {
      _prefsRead = null;
      _prefsPending = false;
    }
  }

  Future<List<ReelCardData>> _ensureDeck(ReelDeck d) {
    final have = _cards[d.id];
    if (have != null) return Future.value(have);
    final pending = _loading[d.id];
    if (pending != null) return pending;
    // Registered before the load starts, so the load can tell whether it is
    // still the one asked for when it lands.
    final done = Completer<List<ReelCardData>>();
    _loading[d.id] = done.future;
    done.complete(_loadDeck(d, done.future));
    return done.future;
  }

  Future<List<ReelCardData>> _loadDeck(ReelDeck d, Future<List<ReelCardData>> self) async {
    bool current() => identical(_loading[d.id], self);
    _loadedOn[d.id] = _today();
    // Trying again: the deck reads as loading (the skeleton) meanwhile.
    if (_failed.remove(d.id)) notifyListeners();
    try {
      final sw = Stopwatch()..start();
      final raw = await d.load().timeout(timeouts.deck);
      final loadMs = sw.elapsedMilliseconds;
      final loaded = await _finish(d, raw).timeout(timeouts.deck);
      appLogger.i(
        '[ReelDeck] ${d.id}: ${loaded.length} cards (load ${loadMs}ms, rules ${sw.elapsedMilliseconds - loadMs}ms)',
      );
      // The first list to land is the deck's (a load a suspend dropped
      // included); a later one never swaps the list under the cursor.
      final kept = _cards[d.id];
      if (kept != null) return kept;
      _cards[d.id] = loaded;
      // One AnimeThemes batch for the deck's anime shows (plan V2-12);
      // the first card waits for it rather than asking on its own.
      unawaited(resolver.warm([for (final c in loaded) c.title]));
      return loaded;
    } catch (e) {
      // Not kept as an empty list: the deck says it failed, and loads
      // again next time it is asked for. A load a suspend dropped says
      // nothing about the deck: the next start's own load does.
      appLogger.w('Reel: deck ${d.id} failed to load', error: e);
      if (current()) _failed.add(d.id);
      return const <ReelCardData>[];
    } finally {
      if (current()) unawaited(_loading.remove(d.id));
      notifyListeners();
    }
  }

  String _today() => ReelPool.dayKey(_clock());

  /// [finishDeck] with what is known of each card's clip: a cached miss is
  /// an AI card, so the 1-in-6 spacing applies to it; a card not resolved
  /// yet is assumed to have a clip (it resolves on demand, two cards ahead,
  /// never the whole deck at once).
  Future<List<ReelCardData>> _finish(ReelDeck d, List<ReelCardData> raw) async {
    var misses = const <String>{};
    if (!d.raw) {
      try {
        misses = await resolver.knownMisses([for (final c in raw) c.title]).timeout(timeouts.store);
      } catch (e) {
        appLogger.d('Reel: cached clip answers unavailable', error: e);
      }
    }
    return finishDeck(d, raw, store: store, hasClip: (c) => !misses.contains(c.title.groupKey));
  }

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
      fresh = await _finish(d, await d.load());
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
      _onDecide.remove(d.id);
      _anchorDecide(d.id, fresh, orBefore: null);
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
    final dc = _decide;
    if (dc != null && dc.deck == d.id && dc.before == null && _decideSeen && keep.length == old.length) {
      // The decision card was the end of the deck: it stays after the cards
      // it followed, and the new ones come after it.
      if (list.length > old.length) _decide = (deck: d.id, before: list[old.length].id);
    } else {
      _anchorDecide(d.id, list, orBefore: at + 1 < list.length ? list[at + 1].id : null);
    }
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

  /// The decision card placed in [deckId] before a card no longer in
  /// [list] moves before [orBefore] (null: the end of the deck).
  void _anchorDecide(String deckId, List<ReelCardData> list, {required String? orBefore}) {
    final d = _decide;
    if (d == null || d.deck != deckId) return;
    final before = d.before;
    if (before == null || list.any((c) => c.id == before)) return;
    _decide = (deck: deckId, before: orBefore);
  }

  /// [c] leaves [deckId]'s [list]: a decision card placed before it moves
  /// before the card after it.
  void _unanchor(String deckId, List<ReelCardData> list, String id) {
    final d = _decide;
    if (d == null || d.deck != deckId || d.before != id) return;
    final j = list.indexWhere((c) => c.id == id);
    _decide = (deck: deckId, before: j >= 0 && j + 1 < list.length ? list[j + 1].id : null);
  }

  /// Next / previous card.
  ///
  /// The target is computed and committed before any await, under the
  /// generation counter, so a held D-pad's repeats coalesce: each one moves
  /// the cursor on from where the last left it, and only the card the
  /// cursor lands on is resolved and opened. Cards passed over were never on
  /// screen, so they record nothing.
  ///
  /// [skipAi] passes over every AI card (Lean back, V2-47): a still has no
  /// end to move on from, so the channel would stop on it.
  Future<void> step(int dir, {bool skipAi = false}) async {
    if (cards == null) return;
    final from = page;
    final to = (from + dir).clamp(0, slotCount - 1);
    if (to == from) return;
    _seek(to);
    final gen = ++_generation;
    _arm();
    await _leaveCard();
    // A later step moved the cursor on while this one was leaving: that
    // step shows the card it lands on.
    if (gen != _generation) return;
    await _show(direction: dir, skipAi: skipAi);
  }

  /// Next / previous shown deck (wraps), with the deck strip. A hidden
  /// deck opened by a link is left for its shown neighbour.
  ///
  /// Like [step], it bumps the generation first, so a card of the old deck
  /// still resolving never plays once the deck has changed.
  ///
  /// A press while an earlier one is still leaving its card counts on from
  /// the deck that press is heading to, so two quick presses move two decks
  /// on; the later press then shows its deck and the earlier one stops.
  Future<void> switchDeck(int dir) async {
    final shown = shownDecks;
    if (shown.length < 2) return;
    var at = (shown.indexOf(_deckHeading ?? deck) + dir) % shown.length;
    if (at < 0) at += shown.length;
    final to = decks.indexOf(shown[at]);
    final run = ++_switchRun;
    _deckHeading = decks[to];
    _generation++;
    _arm();
    _clearPrefetch();
    await _leaveCard();
    if (run != _switchRun) return;
    _deckHeading = null;
    _deck = to;
    _remember();
    _showStrip();
    _stage = ReelStage.load;
    notifyListeners();
    await _ensureDeck(deck);
    await _show();
  }

  /// The deck the latest [switchDeck] is heading to while it leaves its
  /// card; null once it has arrived.
  ReelDeck? _deckHeading;

  /// Counts [switchDeck] presses: an earlier press still leaving its card
  /// stops once a later one has started.
  int _switchRun = 0;

  Future<void> openDeck(String id) => openAt(id);

  /// Opens deck [id] on the card for [groupKey] (On TV mode: the TV opens
  /// on the card the Fold was showing). A title that isn't in this device's
  /// list of the deck, or no [groupKey], leaves the deck on its own cursor.
  Future<void> openAt(String id, [String? groupKey]) async {
    final i = await _deckIndex(id);
    if (i < 0) return;
    if (i == _deck) {
      if (groupKey == null) return;
      final d = deck;
      final at = _indexOf(await _ensureDeck(d), groupKey);
      // A deck change while the list loaded wins.
      if (at == null || at == index || !identical(d, deck)) return;
      // As [step]: the cursor moves first, under the generation counter.
      _cursor[deck.id] = at;
      _onDecide.remove(deck.id);
      final gen = ++_generation;
      await _leaveCard();
      if (gen != _generation) return;
      await _show();
      return;
    }
    _generation++;
    _arm();
    _clearPrefetch();
    await _leaveCard();
    _deck = i;
    _remember();
    _showStrip();
    _stage = ReelStage.load;
    _seekTitle(await _ensureDeck(deck), groupKey);
    await _show();
  }

  /// OK on a deck that failed to load: load it again and show it.
  Future<void> retryDeck() async {
    final d = deck;
    if (!_failed.contains(d.id)) return;
    _arm();
    _stage = ReelStage.load;
    await _ensureDeck(d);
    if (!_active || !identical(deck, d)) return;
    await _show();
  }

  /// The card for [groupKey] in [list], or null.
  static int? _indexOf(List<ReelCardData> list, String? groupKey) {
    if (groupKey == null) return null;
    final at = list.indexWhere((c) => c.title.groupKey == groupKey);
    return at < 0 ? null : at;
  }

  /// Puts the deck playing on the card for [groupKey], when it has one.
  void _seekTitle(List<ReelCardData> list, String? groupKey) {
    final at = _indexOf(list, groupKey);
    if (at == null || !identical(list, cards)) return;
    _cursor[deck.id] = at;
    _onDecide.remove(deck.id);
  }

  /// Puts the strip up for the deck now selected. It stays while the deck
  /// loads; the hold starts when the deck shows ([_settleStrip]).
  void _showStrip() {
    if (_disposed) return;
    _stripTimer?.cancel();
    _stripTimer = null;
    _stripPending = true;
    _stripSince = _generation;
    // The neighbours → and ← go to: the shown decks, in the user's order.
    final shown = shownDecks;
    final n = shown.length;
    final at = shown.indexOf(deck);
    deckStrip.value = ReelDeckStripState(
      previous: n > 2 && at >= 0 ? shown[(at - 1 + n) % n] : null,
      current: deck,
      next: n > 1 && at >= 0 ? shown[(at + 1) % n] : null,
    );
  }

  /// The deck is on screen (its first card, an end or a failure): the strip
  /// goes [stripHold] from now. Only the latest [_show] counts, and only
  /// one started after the deck change, so a slow deck overtaken by another
  /// switch doesn't start the earlier one's hold, and neither does the old
  /// deck's card that was still opening when the deck changed.
  void _settleStrip(int gen) {
    if (_disposed || !_stripPending || gen != _generation || gen <= _stripSince) return;
    _stripPending = false;
    _stripTimer?.cancel();
    _stripTimer = Timer(stripHold, () {
      _stripTimer = null;
      if (!_disposed) deckStrip.value = null;
    });
  }

  void _hideStrip() {
    if (_disposed) return;
    _stripTimer?.cancel();
    _stripTimer = null;
    _stripPending = false;
    deckStrip.value = null;
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
  ///
  /// The lookup is bounded ([ReelTimeouts.lookup]): one that runs out is an
  /// unknown answer, looked up again when the Reel comes back. A lookup that
  /// was dropped meanwhile (a suspend, a failed clip, Spoiled me) writes
  /// nothing when it lands: the newer one answers.
  Future<void> _resolve(ReelCardData c) {
    final have = _resolving[c.id];
    if (have != null) return have;
    final done = Completer<void>();
    _resolving[c.id] = done.future;
    done.complete(_resolveClip(c, done.future));
    return done.future;
  }

  Future<void> _resolveClip(ReelCardData c, Future<void> self) async {
    ClipLookup? found;
    try {
      found = await resolver.lookup(c.title, exclude: _excluded[c.id] ?? const {}).timeout(timeouts.lookup);
    } catch (e) {
      appLogger.d('Reel: card resolve failed', error: e);
    }
    if (_disposed || !identical(_resolving[c.id], self)) return;
    _clip[c.id] = found?.clip;
    found == null || found.answer == ClipAnswer.unknown ? _unknown.add(c.id) : _unknown.remove(c.id);
    _resolved.add(c.id);
    notifyListeners();
  }

  /// The card's art and text. Kept once they land; a failed or empty read
  /// is never memoised.
  Future<void> _loadItem(ReelCardData c) {
    if (_item.containsKey(c.id)) return Future<void>.value();
    final pending = _itemLoading[c.id];
    if (pending != null) return pending;
    // Asked again: the item may be on its way after all.
    if (_itemMissed.remove(c.id) && !_disposed) notifyListeners();
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
    MediaItem? item;
    try {
      item = await _metadata(c).timeout(timeouts.metadata);
    } catch (e) {
      appLogger.d('Reel: card metadata read failed (${e.runtimeType})');
    }
    if (_disposed) return;
    if (item == null) {
      _itemMissed.add(c.id);
    } else {
      _item[c.id] = item;
    }
    notifyListeners();
  }

  /// A card's metadata; a resume card's next episode comes with it.
  Future<MediaItem?> _metadata(ReelCardData c) async {
    final withNext = itemWithNext;
    if (!c.resume || withNext == null) return media.item(c.best.serverId, c.best.ratingKey);
    final r = await withNext(c.best.serverId, c.best.ratingKey);
    _next[c.id] = r.next;
    return r.item;
  }

  Future<void> _show({int direction = 1, bool skipAi = false}) async {
    if (_disposed) return;
    final gen = ++_generation;
    _direction = direction < 0 ? -1 : 1;
    // Every card change has its own watchdog (an AI card skipped over
    // re-arms it for the card after).
    _arm();
    notifyListeners();
    cardChanged.value++;
    final list = cards;
    if (list != null && _onDecideNow) return _showDecide(list, gen);
    if (list == null || index >= list.length) {
      // The end, an empty deck or one that failed to load each say so; a
      // deck still loading is not settled.
      if (list != null || _failed.contains(deck.id)) {
        _settle(gen, playing: false);
      } else {
        _stage = ReelStage.load;
      }
      _prefetch.release();
      if (list != null) _plan(list, gen);
      if (!externalClips) await clips.pause();
      _settleStrip(gen);
      return;
    }
    final c = list[index];
    _stage = ReelStage.resolve;
    // The card's own clip and art start at once; on the TV the cards around
    // it wait until its clip shows a frame (or turns out to be a still).
    if (!externalClips) _prefetch.hold();
    _plan(list, gen);
    await _resolve(c);
    if (gen != _generation || !_active) return;
    // An AI card only with room (at most 1 in 6), and never in Lean back;
    // otherwise the title waits for another day and the feed moves on. The
    // phone holds them back before they come on screen instead
    // ([_holdBackAhead]).
    final skipTo = page + (direction == 0 ? 1 : direction);
    if (!externalClips &&
        _clip[c.id] == null &&
        (skipAi || _sinceAiCard < ReelDecay.aiCardEvery) &&
        skipTo >= 0 &&
        skipTo < slotCount) {
      _seek(skipTo);
      return _show(direction: direction == 0 ? 1 : direction, skipAi: skipAi);
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
      _sinceAiCard = clip == null ? 0 : _sinceAiCard + 1;
      // A still (an AI card, Stills only, low memory) or a clip already
      // playing settles it; otherwise the feed's player says when it plays.
      if (clip == null || _cardSince != null || !_budget.clips || memoryLevel >= 2) {
        _settle(gen, playing: clip != null && _cardSince != null);
      } else {
        _stage = ReelStage.frame;
      }
    } else if (clip == null) {
      _sinceAiCard = 0;
      _settle(gen, playing: false);
      await clips.pause();
    } else if (memoryLevel >= 2 || !_budget.clips) {
      // Low memory, or Stills only on mobile data: the backdrop as a still,
      // no clip core (and no clock).
      _sinceAiCard++;
      _settle(gen, playing: false);
      // The ladder released the core on its way to level 2; a link that
      // moved to mobile data mid-session hasn't, so the last clip and its
      // preload stop here.
      if (memoryLevel < 2) {
        await clips.release();
        _firstClip = true;
      }
    } else {
      _sinceAiCard++;
      _cardClip = clip.source.uri;
      _stage = ReelStage.open;
      await clips.play(clip.source, first: _firstClip);
      _firstClip = false;
      // Opened; the first frame settles it ([_onPhase]) unless it already has.
      if (gen == _generation && _stage == ReelStage.open) _stage = ReelStage.frame;
    }
    _syncHold();
    _preloadNext(list, gen);
    _settleStrip(gen);
  }

  /// The decision card is on screen: nothing plays (the TV's clip pauses,
  /// as at the end of a deck), the picks' metadata is read, and it is
  /// seen: it stays where it is and never comes up again this session.
  Future<void> _showDecide(List<ReelCardData> list, int gen) async {
    _cardShown = null;
    if (!_decideSeen) {
      _decideSeen = true;
      _decide = (deck: deck.id, before: index < list.length ? list[index].id : null);
      appLogger.i('[ReelDecide] ${deck.id}: Tonight\'s picks shown');
    }
    // Tonight's picks waits on nothing that plays.
    _settle(gen, playing: false);
    await _refreshPicks();
    // Moved on while the picks were read: that step shows its own card.
    if (gen != _generation || !_active) return;
    _readPicks();
    notifyListeners();
    // The window around the card after it ([index]) is fetched as usual.
    _prefetch.release();
    _plan(list, gen);
    if (!externalClips) await clips.pause();
    _settleStrip(gen);
  }

  /// Hands the prefetcher the window around the card on screen, nearest
  /// first (0, +1, -1, +2 in the direction of travel), each card's clip
  /// before its art and text, and for +1 and +2 their art decoded last
  /// (plan V2-13). On a metered or offline link, or under memory pressure,
  /// only the card on screen and the next; under memory pressure no art is
  /// decoded ahead.
  ///
  /// The decision card a page or two ahead has its picks' metadata read, and
  /// on the phone a card ahead that turns out to be an AI card with no room
  /// is held back once its clip answer is in ([_holdBackAhead]).
  void _plan(List<ReelCardData> list, int gen) {
    if (_disposed || gen != _generation) return;
    final at = _decideAt(deck.id, list);
    if (at != null && at > index && at - index <= 2) _readPicks();
    final lean = memoryLevel >= 1 || resolver.playback.link != ReelLink.unmetered;
    final tasks = <ReelPrefetchTask>[];
    final answered = <ReelCardData>[];
    final window = <String>[];
    for (final offset in lean ? ReelPrefetcher.leanOffsets : ReelPrefetcher.offsets) {
      final j = index + offset * _direction;
      if (j < 0 || j >= list.length) continue;
      final c = list[j];
      window.add(c.id);
      if (!_resolved.contains(c.id)) {
        tasks.add(
          ReelPrefetchTask(
            cardId: c.id,
            offset: offset,
            stage: ReelPrefetchStage.resolve,
            lane: ReelPrefetcher.laneFor(c.title),
            run: offset > 0 ? () => _resolve(c).then((_) => _holdBackAhead(c)) : () => _resolve(c),
          ),
        );
      } else if (offset > 0) {
        answered.add(c);
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
    // The art budget keeps the same window: on a lean step (memory
    // pressure, a metered link) only this card and the next.
    if (_active) artWindow?.call(window);
    // Cards ahead already answered: checked once this step has settled.
    if (externalClips && answered.isNotEmpty) scheduleMicrotask(() => answered.forEach(_holdBackAhead));
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
      await precache(c, item, clip: _clip[c.id] != null).timeout(timeouts.art);
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
    if (externalClips || memoryLevel != 0 || !_budget.clips || ahead < 0 || ahead >= list.length) return;
    final next = list[ahead];
    unawaited(
      _prefetch.done(ReelPrefetcher.keyOf(next.id, ReelPrefetchStage.resolve)).then((_) {
        if (gen != _generation || !_active || memoryLevel != 0 || !_budget.clips) return;
        if (!_resolved.contains(next.id)) return;
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

  /// Phone: the TV's 1-in-6 AI-card cap. The feed never skips the card
  /// under your thumb, so an AI card ahead (resolved two cards early) with
  /// no room is taken out of this session's list before it comes on screen;
  /// the title waits for another day, as on the TV.
  void _holdBackAhead(ReelCardData c) {
    if (!externalClips || _disposed || !_active) return;
    final list = _cards[deck.id];
    if (list == null) return;
    final j = list.indexOf(c);
    if (j <= index || !_resolved.contains(c.id) || _clip[c.id] != null) return;
    if (_aiCardFits(list, j)) return;
    _unanchor(deck.id, list, c.id);
    final left = [...list]..removeAt(j);
    _cards[deck.id] = left;
    appLogger.d('[ReelDeck] ${deck.id}: AI card held back (at most 1 in ${ReelDecay.aiCardEvery})');
    notifyListeners();
    _plan(left, _generation);
  }

  /// Whether an AI card at [j] (ahead of the cursor) keeps the 1-in-6 cap:
  /// the clip cards since the last AI card shown, plus those between here
  /// and [j] (a card not resolved yet counts as a clip card).
  bool _aiCardFits(List<ReelCardData> list, int j) {
    var since = _sinceAiCard;
    for (var i = index + 1; i < j; i++) {
      final x = list[i];
      if (_resolved.contains(x.id) && _clip[x.id] == null) return false;
      since++;
    }
    return since >= ReelDecay.aiCardEvery;
  }

  /// TV: the clock starts when this card's clip first plays with its own
  /// picture up: from its opening, or from a pause that came while it opened
  /// (the viewer's, or one held for an `inactive` app), whose first frame
  /// landed in the pause; a later resume doesn't count again.
  /// With Next card (Lean back, V2-47), a clip that played out moves on to
  /// the next card with a clip, until [leanBackIdle] passes with no input;
  /// then it holds with Replay like Twice then hold.
  void _onPhase() {
    final now = clips.phase.value, was = _lastPhase;
    _lastPhase = now;
    final uri = _cardClip;
    if (externalClips || _cardShown == null || uri == null || clips.current?.uri != uri) return;
    if (now == ClipPhase.failed) {
      unawaited(clipFailed(_cardShown!));
    } else if (now == ClipPhase.playing && _cardSince == null && !_cardFailed && clips.onScreen.value?.uri == uri) {
      _cardSince = _clock();
      _settle(_generation, playing: true);
      _syncHold();
    } else if (now == ClipPhase.held && was != ClipPhase.held && _active) {
      if (clipEnd == ReelClipEnd.nextCard && mayRollOn) unawaited(step(1, skipAi: true));
    }
  }

  /// TV: this card's clip showed its first frame ([ClipPlayer.onScreen]),
  /// playing or paused: the card has shown something, so the stuck-card
  /// watchdog stands down. A clip resumed before its first frame is already
  /// playing when that frame lands, so its clock starts here ([_onPhase]
  /// sees no phase change then).
  void _onClipOnScreen() {
    final uri = _cardClip;
    if (externalClips || _cardShown == null || uri == null || _cardFailed) return;
    if (clips.onScreen.value?.uri != uri) return;
    if (clips.phase.value == ClipPhase.playing) _cardSince ??= _clock();
    _settle(_generation, playing: true);
    _syncHold();
  }

  /// Phone feed: [cardId]'s player is playing (its position has moved).
  void clipStarted(String cardId) {
    if (!externalClips) return;
    if (cardId != _cardShown) {
      _feedStarted = (id: cardId, at: _clock());
    } else if (_cardSince == null && !_cardFailed) {
      _cardSince = _clock();
      _settle(_generation, playing: true);
    }
  }

  /// [cardId]'s clip failed to open or broke mid-play (the phone feed's
  /// player, or the TV's clip core). How the card is left then says nothing
  /// about the title. Its cached answer is cleared and it is looked up once
  /// more without the failed asset: the next rung plays, or an AI card.
  ///
  /// Phone: the feed also tells of a parked card's clip, and of the card
  /// under the thumb before its swipe commits, so those are looked up again
  /// too. A card whose clip fails a second time becomes an AI card (its art
  /// and premise) rather than a page with a broken clip.
  Future<void> clipFailed(String cardId) async {
    final shown = cardId == _cardShown;
    if (!shown && !externalClips) return;
    if (shown) {
      _cardFailed = true;
      _syncHold();
    }
    final failed = _clip[cardId];
    final c = cards?.where((x) => x.id == cardId).firstOrNull;
    if (c == null || failed == null) return;
    if (!_retried.add(cardId)) {
      if (externalClips && _resolved.contains(cardId)) {
        _clip[cardId] = null;
        notifyListeners();
      }
      // A second failure leaves the card's art: a still, nothing to wait on.
      if (shown) _settle(_generation, playing: false);
      return;
    }
    appLogger.i('Reel: a clip failed to play; looking for another');
    (_excluded[cardId] ??= {}).add(failed.assetId);
    await resolver.forget(c.title);
    unawaited(_resolving.remove(cardId));
    _resolved.remove(cardId);
    _clip.remove(cardId);
    notifyListeners();
    final gen = _generation;
    await _resolve(c);
    if (_disposed || !_active || _cardShown != cardId) return;
    final clip = _clip[cardId];
    if (clip == null) {
      // An AI card now: a still, seen whole from here; still neutral.
      _settle(gen, playing: false);
      if (!externalClips) {
        _sinceAiCard = 0;
        await clips.pause();
      }
      return;
    }
    // The new clip's first frame starts the clock, and the watchdog times
    // it afresh.
    _cardFailed = false;
    _cardSince = null;
    if (gen != _generation) return;
    if (memoryLevel >= 2 || !_budget.clips) return _settle(gen, playing: false);
    _arm();
    _stage = externalClips ? ReelStage.frame : ReelStage.open;
    if (externalClips) return;
    _cardClip = clip.source.uri;
    _prefetch.hold();
    await clips.play(clip.source, first: _firstClip);
    _firstClip = false;
    if (gen == _generation && _stage == ReelStage.open) _stage = ReelStage.frame;
    _syncHold();
  }

  /// Phone feed: [cardId] is no longer the page under the thumb (V2-02). A
  /// start it reported before the swipe committed belonged to a visit that
  /// ended, so it can't time a later one.
  void clipLeft(String cardId) {
    if (_feedStarted?.id == cardId) _feedStarted = null;
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
    // [_feedStarted] stays: on the phone the step commits when the page
    // settles (V2-02), after the incoming card has already started playing.
    if (id == null) return;
    final deckId = deck.id;
    if (since == null || failed) {
      await _recordLeft(id, ReelAction.unplayed, deckId);
      return;
    }
    final secs = _clock().difference(since).inMilliseconds / 1000;
    if (clips.phase.value == ClipPhase.held || _clipEnded) {
      await _recordLeft(id, ReelAction.toEnd, deckId, seconds: secs.round());
    } else if (secs < 2) {
      await _recordLeft(id, ReelAction.quickSkip, deckId);
    } else if (secs >= 8) {
      await _recordLeft(id, ReelAction.sampled, deckId, seconds: secs.round());
    }
  }

  /// How a card was left, never holding up the card change behind it: a
  /// write that runs out ([ReelTimeouts.store]) is let go.
  Future<void> _recordLeft(String id, ReelAction action, String deckId, {int? seconds}) async {
    try {
      await store.record(id, action, deck: deckId, seconds: seconds).timeout(timeouts.store);
    } on TimeoutException {
      appLogger.w('Reel: a card event write timed out');
    }
  }

  // ---- actions ----

  /// OK = Watch: pause, show the loading curtain, await the clip core's
  /// dispose, then hand over to real playback (which reports normally). On
  /// the decision card it watches the chosen pick the same way.
  Future<bool> watch({bool onTv = false}) async {
    final s = current;
    final c = s.card, pick = s.chosen?.pick;
    final ({String id, String serverId, String ratingKey, MediaItem? known})? target = c != null
        ? (id: c.id, serverId: c.best.serverId, ratingKey: c.best.ratingKey, known: s.item)
        : pick != null
        ? (id: pick.titleId, serverId: pick.serverId, ratingKey: pick.ratingKey, known: s.chosen?.item)
        : null;
    if (target == null) return false;
    // No Reel prefetch competes with the hand-over, or follows it.
    _clearPrefetch();
    // Watch keeps its full read (file checks, streams): the card's own
    // item may be a lean row. The card's item stands in only when that read
    // fails.
    final item = await media.fullItem(target.serverId, target.ratingKey).catchError((Object _) => null) ?? target.known;
    if (item == null) {
      // Nothing to hand over: the Reel stays, and so does its window.
      final list = cards;
      if (list != null && _active) _plan(list, _generation);
      return false;
    }
    await store.record(target.id, onTv ? ReelAction.watchOnTv : ReelAction.watch, deck: deck.id);
    if (!onTv) {
      // A card change still on its way stops here: real playback is next.
      _generation++;
      _disarm();
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
    // went (or that it couldn't be kept). A pick is already kept.
    if (!ok && onTv && c != null) await save();
    return ok;
  }

  /// The decision card: moves the choice [dir] picks along (D-pad left and
  /// right); it stops at either end.
  void movePick(int dir) {
    final s = current;
    if (s.kind != ReelSlotKind.decide || s.picks.isEmpty) return;
    selectPick(s.pick + dir);
  }

  /// The decision card: chooses pick [i] (a tap, or the Fold's On TV mode).
  void selectPick(int i) {
    final s = current;
    if (s.kind != ReelSlotKind.decide || s.picks.isEmpty) return;
    final to = i.clamp(0, s.picks.length - 1);
    if (to == s.pick) return;
    _pickAt = to;
    notifyListeners();
  }

  /// Confirmations that say where a Save went.
  static String get savedOnTv => t.reel.toast.savedOnTv;
  static String get savedForLater => t.reel.toast.savedForLater;
  static String get notConnected => t.reel.toast.notConnected;

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

  /// The titles saved and still waiting on the TV's Home (fresh picks),
  /// so the phone's Save shows as saved (V2-29).
  final Set<String> _saved = {};

  /// Bumped by every Save, so a picks read that started before it can't
  /// put back a list without it.
  int _savedReads = 0;

  /// Whether the card [cardId] is saved: a fresh pick, from this device or
  /// synced from the other one.
  bool isSaved(String cardId) => _saved.contains(cardId);

  void _onPicksChanged() => unawaited(_loadSaved());

  Future<void> _loadSaved() async {
    final read = ++_savedReads;
    final List<ReelPick> picks;
    try {
      picks = await store.picks().timeout(timeouts.store);
    } catch (e) {
      appLogger.w('Reel: saved picks could not be read', error: e);
      return;
    }
    if (_disposed || read != _savedReads) return;
    final now = _clock();
    final saved = {
      for (final p in picks)
        if (p.isFresh(now)) p.titleId,
    };
    if (setEquals(saved, _saved)) return;
    _saved
      ..clear()
      ..addAll(saved);
    notifyListeners();
  }

  /// One Save: waits on the TV's Home for 3 days and goes to the Plex
  /// watchlist so it's never lost. The card shows as saved at once, and
  /// goes back if the pick couldn't be kept. [silent] leaves out the
  /// confirmation (the phone feed's filled Save and burst say it, and a
  /// toast would float over its buttons); a failure is always said.
  Future<void> save({bool silent = false}) async {
    final c = current.card;
    if (c == null) return;
    _savedReads++;
    final added = _saved.add(c.id);
    if (added) notifyListeners();
    var kept = false;
    try {
      await _act('save', () async {
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
        kept = true;
        await _afterSave(c, silent: silent);
      });
    } finally {
      if (!kept && added && _saved.remove(c.id)) notifyListeners();
    }
  }

  /// After the pick is kept: the event, the watchlist mirror, the Home row
  /// and the confirmation.
  Future<void> _afterSave(ReelCardData c, {required bool silent}) async {
    await store.record(c.id, ReelAction.save, deck: deck.id);
    unawaited(_mirrorToWatchlist(_item[c.id], c));
    final seat = onSaved;
    if (seat != null) unawaited(seat().catchError((Object _) {}));
    if (!silent) _say((reachesTvNow?.call() ?? true) ? savedOnTv : savedForLater);
    _saves++;
    await _refreshPicks();
    _placeDecideNext(c);
  }

  /// After the [decideAfterSaves]th Save of the session, the decision card
  /// comes up next: straight after the card just saved, [saved]. Once seen
  /// it never moves again.
  void _placeDecideNext(ReelCardData saved) {
    if (_decideSeen || _saves < decideAfterSaves || _picks.isEmpty || _disposed) return;
    final list = cards;
    if (list == null || current.card?.id != saved.id) return;
    _decide = (deck: deck.id, before: index + 1 < list.length ? list[index + 1].id : null);
    appLogger.d('[ReelDecide] ${deck.id}: Tonight\'s picks up next');
    notifyListeners();
    if (_active) _readPicks();
  }

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

  /// Takes [c] out of every deck. The deck on screen keeps its page, so the
  /// slot after it (a card, the decision card or the end) slides in.
  void _drop(ReelCardData c) {
    final p = page;
    for (final e in _cards.entries) {
      if (e.value.any((x) => x.id == c.id)) {
        _unanchor(e.key, e.value, c.id);
        _cards[e.key] = [...e.value]..removeWhere((x) => x.id == c.id);
      }
    }
    _seek(p.clamp(0, slotCount - 1));
  }

  /// Phone feed: the current card's clip played through once.
  void clipEnded() => _clipEnded = true;

  /// What More like this says: while the call runs, when its cards are in,
  /// and when it found none.
  static String get findingMoreLike => t.reel.moreLike.finding;
  static String get moreLikeUpNext => t.reel.moreLike.upNext;
  static String get noMoreLike => t.reel.moreLike.none;

  /// Whether the current card offers More like this.
  bool get canMoreLike => moreLike != null && current.card != null;

  /// The press in flight; a second press while it runs joins it.
  Future<void>? _moreLiking;

  /// More like this (V2-39): records the ask as a fact, then inserts the
  /// cards the call chose straight after the card on screen once it lands
  /// (never the raw similar titles), so they come next; the cursor, and so
  /// the phone's page, stays where it is. Cards already shown in the deck
  /// stay out; one further down the deck moves up instead of showing twice.
  Future<void> moreLikeThis() => _moreLiking ??= _moreLikeThis().whenComplete(() => _moreLiking = null);

  Future<void> _moreLikeThis() async {
    final find = moreLike;
    final seed = current.card;
    if (find == null || seed == null) return;
    final shown = {for (final c in (cards ?? const <ReelCardData>[]).take(index + 1)) c.id};
    await store.record(seed.id, ReelAction.moreLikeThis, deck: deck.id);
    _say(findingMoreLike);
    List<ReelCardData>? found;
    try {
      found = await find(seed, skip: shown);
    } catch (e) {
      appLogger.w('Reel: More like this failed', error: e);
    }
    if (_disposed) return;
    // Inserted after the card on screen when the call lands, in the deck on
    // screen then: the press asked for them next.
    final list = _cards[deck.id];
    final at = index;
    final before = {for (final c in (list ?? const <ReelCardData>[]).take(at + 1)) c.id, seed.id};
    final fresh = <ReelCardData>[];
    for (final c in found ?? const <ReelCardData>[]) {
      if (fresh.length >= ReelPool.moreLikeMax) break;
      if (before.add(c.id)) fresh.add(c);
    }
    if (list == null || fresh.isEmpty) {
      _say(noMoreLike);
      return;
    }
    final freshIds = {for (final c in fresh) c.id};
    final next = [
      ...list.take(at + 1),
      ...fresh,
      for (final c in list.skip(at + 1))
        if (!freshIds.contains(c.id)) c,
    ];
    _cards[deck.id] = next;
    // The decision card waiting before a card that moved up into the new
    // ones comes after them instead.
    final dc = _decide;
    if (dc != null && dc.deck == deck.id && freshIds.contains(dc.before)) {
      final after = at + 1 + fresh.length;
      _decide = (deck: deck.id, before: after < next.length ? next[after].id : null);
    }
    appLogger.i('[ReelMore] ${deck.id}: ${fresh.length} cards after card ${at + 1}');
    _say(moreLikeUpNext);
    if (at >= list.length) {
      // At the end of the deck: the first new card comes on screen.
      if (_active) return _show();
      notifyListeners();
      return;
    }
    notifyListeners();
    if (_active) {
      _plan(next, _generation);
      _preloadNext(next, _generation);
    }
  }

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

  bool get muted => clips.muted;

  /// The mute button (V2-22): an unmute is recorded against the card on
  /// screen, and the choice is kept for the next card and the next launch
  /// ([SettingsService.reelMuted]). The phone feed's own players follow it
  /// from the view. With [remember] off (a visit starting muted while the TV
  /// plays, or the saved mute put back) nothing is recorded or kept.
  Future<void> setMuted(bool muted, {bool remember = true}) async {
    final c = current.card;
    if (remember && !muted && c != null) await store.record(c.id, ReelAction.unmute, deck: deck.id);
    await clips.setMuted(muted);
    notifyListeners();
    if (remember) await (saveMuted ?? _saveMutedPref)(muted);
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
      // The card on screen is a still now (the TV's core and the phone's
      // players are let go): it waits on no first frame.
      if (_cardShown != null) _settle(_generation, playing: false);
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
        for (final d in shownDecks) {'id': d.id, 'name': d.name},
      ],
      'index': index,
      'groupKey': c?.title.groupKey,
      'card': card(s),
      'next': [for (final n in upNext) ?card(n)],
      'playing': clips.phase.value == ClipPhase.playing,
      'poolEnd': s.kind == ReelSlotKind.poolEnd,
      if (s.kind == ReelSlotKind.decide)
        'decide': {
          'pick': s.pick,
          'picks': [
            for (final p in s.picks)
              {
                'id': p.pick.titleId,
                'title': p.pick.title,
                'year': p.item?.year,
                'server': p.pick.serverId,
                'art': p.item?.artPath,
                'thumb': p.item?.thumbPath,
              },
          ],
        },
      // V2-49: the phone's More menu offers Replay and Spoiled me only with
      // a clip, and its mute button follows the TV's sound.
      'hasClip': s.clip != null,
      'muted': clips.muted,
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
    clips.onScreen.removeListener(_onClipOnScreen);
    memoryRestored?.removeListener(_onMemoryRestored);
    resolver.profile?.removeListener(_onProfile);
    ReelStore.picksChanged.removeListener(_onPicksChanged);
    settingsChanged?.removeListener(_onSettingsChanged);
    linkChanged?.removeListener(_onLinkChanged);
    deckPrefsChanged.removeListener(_onDeckPrefsChanged);
    for (final MapEntry(key: d, value: l) in _rebuiltListeners.entries) {
      d.rebuilt?.removeListener(l);
    }
    _rebuiltListeners.clear();
    _prefetch.dispose();
    _stuckTimer?.cancel();
    _stuckTimer = null;
    stuck.dispose();
    _stripTimer?.cancel();
    _toastTimer?.cancel();
    deckStrip.dispose();
    toast.dispose();
    cardChanged.dispose();
    unawaited(clips.release());
    super.dispose();
  }
}
