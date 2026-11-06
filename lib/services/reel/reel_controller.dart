import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_item.dart';
import '../../utils/app_logger.dart';
import 'clip_player.dart';
import 'clip_resolver.dart';
import 'reel_decks.dart';
import 'reel_library.dart';
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
    this.deckFor,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final List<ReelDeck> decks;
  final ClipResolver resolver;
  final ClipPlayer clips;
  final ReelStore store;
  final ReelMedia media;
  final ReelWatch onWatch;
  final ReelWatchlist addToWatchlist;

  /// After a Save: seats the Home row the first time (ReelApp).
  final Future<void> Function()? onSaved;

  /// Builds a deck asked for by id that isn't in [decks] yet (an answer
  /// saved after the Reel opened); it joins the end of [decks].
  final Future<ReelDeck?> Function(String id)? deckFor;

  Future<int> _deckIndex(String id) async {
    final i = decks.indexWhere((d) => d.id == id);
    if (i >= 0) return i;
    final made = await deckFor?.call(id).catchError((Object _) => null);
    if (made == null) return -1;
    decks.add(made);
    return decks.length - 1;
  }

  final DateTime Function() _clock;

  int _deck = 0;
  final Map<String, List<ReelCardData>> _cards = {};
  final Map<String, int> _cursor = {};
  final Map<String, Future<List<ReelCardData>>> _loading = {};
  final Map<String, ResolvedClip?> _clip = {};
  final Set<String> _resolved = {};
  final Map<String, MediaItem?> _item = {};
  final Map<String, Future<void>> _resolving = {};
  bool _active = false;
  bool _firstClip = true;
  DateTime? _cardSince;
  String? _cardShown;
  int _sinceAiCard = 99;
  int _generation = 0;

  /// The deck name shown for 1.5 s after a deck change.
  final ValueNotifier<String?> deckStrip = ValueNotifier(null);
  Timer? _stripTimer;

  /// One-line confirmations ("On the TV tonight").
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

  /// Opens the Reel (or comes back to it): loads the deck and plays.
  Future<void> start({String? deckId}) async {
    _active = true;
    // Each visit starts at the top of the degrade ladder: pressure from an
    // earlier visit (or while the Reel was hidden) has usually passed, and a
    // fresh callback steps it down again.
    memoryLevel = 0;
    if (deckId != null) {
      final i = await _deckIndex(deckId);
      if (i >= 0) _deck = i;
    }
    await _ensureDeck(deck);
    if (!_active) return;
    await _show();
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

  /// Next / previous card.
  Future<void> step(int dir) async {
    final list = cards;
    if (list == null) return;
    final to = (index + dir).clamp(0, list.length);
    if (to == index) return;
    await _leaveCard();
    _cursor[deck.id] = to;
    await _show(direction: dir);
  }

  /// Next / previous deck (wraps), with the deck strip.
  Future<void> switchDeck(int dir) async {
    if (decks.length < 2) return;
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
      await clips.pause();
      return;
    }
    final c = list[index];
    await _resolve(c);
    if (gen != _generation || !_active) return;
    // An AI card only with room (at most 1 in 6); otherwise the title waits
    // for another day and the feed moves on.
    if (_clip[c.id] == null && _sinceAiCard < 6 && index + direction >= 0 && index + direction <= list.length) {
      _cursor[deck.id] = index + (direction == 0 ? 1 : direction);
      return _show(direction: direction == 0 ? 1 : direction);
    }
    _cardSince = _clock();
    _cardShown = c.id;
    final clip = _clip[c.id];
    if (clip == null) {
      _sinceAiCard = 0;
      await clips.pause();
    } else if (memoryLevel >= 2) {
      // Low memory: the backdrop as a still, no clip core.
      _sinceAiCard++;
    } else {
      _sinceAiCard++;
      await clips.play(clip.source, first: _firstClip);
      _firstClip = false;
    }
    // Two ahead: resolve; one ahead (in the swipe direction): preload.
    for (var k = 1; k <= 2; k++) {
      final j = index + k * (direction < 0 ? -1 : 1);
      if (j >= 0 && j < list.length) unawaited(_resolve(list[j]));
    }
    final ahead = index + (direction < 0 ? -1 : 1);
    if (memoryLevel == 0 && ahead >= 0 && ahead < list.length) {
      final next = list[ahead];
      unawaited(
        _resolve(next).then((_) {
          if (gen == _generation && _active) unawaited(clips.preload(_clip[next.id]?.source));
        }),
      );
    }
  }

  /// Records how the card was left: a quick skip (<2 s) adds fatigue; 8 s
  /// or more is a sample; scrolling past in between records nothing.
  Future<void> _leaveCard() async {
    final id = _cardShown, since = _cardSince;
    _cardShown = null;
    _cardSince = null;
    if (id == null || since == null) return;
    final secs = _clock().difference(since).inMilliseconds / 1000;
    final deckId = deck.id;
    if (clips.phase.value == ClipPhase.held) {
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
    if (!ok && onTv) {
      await save(silent: true);
      _say('Saved for the TV.');
    }
    return ok;
  }

  /// One Save: waits on the TV's Home for 3 days and goes to the Plex
  /// watchlist so it's never lost.
  Future<void> save({bool silent = false}) async {
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
    final item = s.item;
    if (item != null) unawaited(addToWatchlist(item).catchError((Object _) => false));
    final seat = onSaved;
    if (seat != null) unawaited(seat().catchError((Object _) {}));
    if (!silent) _say('On the TV tonight');
  }

  /// Not for me: the title rests 90 days (never a ban) and the feed moves on.
  Future<void> notForMe() async {
    final c = current.card;
    if (c == null) return;
    await store.notForMe(c.id);
    await store.record(c.id, ReelAction.notForMe, deck: deck.id);
    _cardShown = null;
    _drop(c);
    await _show();
  }

  /// Spoiled me: bans this asset for good and drops to the next rung.
  Future<void> spoiledMe() async {
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
  }

  /// Seen it: a fact, so permanent (and the title leaves unseen-only decks).
  Future<void> seenIt() async {
    final c = current.card;
    if (c == null) return;
    await store.markFact(c.id, 'seen');
    await store.record(c.id, ReelAction.seenIt, deck: deck.id);
    if (!deck.keepsSeen) {
      _cardShown = null;
      _drop(c);
      await _show();
    }
  }

  void _drop(ReelCardData c) {
    for (final e in _cards.entries) {
      if (e.value.any((x) => x.id == c.id)) _cards[e.key] = [...e.value]..removeWhere((x) => x.id == c.id);
    }
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

  /// The On TV state the TV broadcasts on every card change.
  /// How hard the system has asked for memory back this session (the
  /// degrade ladder): 1 drops the preload, 2 releases the clip core and
  /// shows stills.
  int memoryLevel = 0;

  Future<void> trimMemory({bool severe = false}) async {
    memoryLevel = severe ? 2 : (memoryLevel + 1).clamp(0, 2);
    appLogger.w('Reel: memory pressure, level $memoryLevel');
    if (memoryLevel == 1) {
      await clips.dropPreload();
    } else {
      await clips.release();
      _firstClip = true;
      notifyListeners();
    }
  }

  /// What the Fold's On TV mode shows (`reelState`). Image paths only: the
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
    _active = false;
    _generation++;
    _stripTimer?.cancel();
    _toastTimer?.cancel();
    deckStrip.dispose();
    toast.dispose();
    cardChanged.dispose();
    unawaited(clips.release());
    super.dispose();
  }
}
