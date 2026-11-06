import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:plezy_brain/plezy_brain.dart' show TitleProfile;

import '../../media/catalog_item_ref.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/app_logger.dart';
import '../ai/ai_briefing.dart';
import '../ai/ai_history.dart';
import '../ai/ai_suggestions.dart' show AiSuggestions;
import '../ai/facts/title_facts.dart';
import '../brain/history_brain.dart';
import '../library_index/index_database.dart';
import 'reel_decay.dart';
import 'reel_library.dart';
import 'reel_pool.dart';
import 'reel_signals.dart';
import 'reel_store.dart';

/// A deck: an ordered list of titles and how seen titles are treated
/// (spec §3). Decks are lenses onto the index, never crawls.
abstract class ReelDeck {
  String get id;
  String get name;

  /// Most Watched, Anime openings and franchise answers keep seen titles
  /// (badged); every other deck is unseen only.
  bool get keepsSeen;

  /// Raw decks (charts) are never re-ordered by code.
  bool get raw => false;

  /// The deck is built for the day: a controller that loaded it on an
  /// earlier day loads it again on its next start.
  bool get daily => false;

  /// Fires when a fresh build of the deck lands after [load] returned, so a
  /// session already showing it can take the new list.
  Listenable? get rebuilt => null;

  Future<List<ReelCardData>> load();
}

/// Applies a deck's hard rules: unseen only unless it keeps seen titles,
/// nothing resting after Not for me or marked seen / for kids, and (for
/// non-raw decks) the adjacency and AI-card layout rules.
Future<List<ReelCardData>> finishDeck(
  ReelDeck deck,
  List<ReelCardData> cards, {
  required ReelStore store,
  required bool Function(ReelCardData) hasClip,
}) async {
  final excluded = await store.excluded();
  final kept = [
    for (final c in cards)
      if (!excluded.contains(c.id) && (deck.keepsSeen || c.facts.seen.isUnseen)) c,
  ];
  if (deck.raw) return kept;
  return ReelDecay.arrange<ReelCardData>(kept, cluster: (c) => c.cluster, isAiCard: (c) => !hasClip(c));
}

/// A deck over a fixed list of entries.
class EntriesDeck extends ReelDeck {
  EntriesDeck({
    required this.id,
    required this.name,
    required this.library,
    required this.entries,
    this.keepsSeen = false,
    this.raw = false,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final bool keepsSeen;
  @override
  final bool raw;
  final ReelLibrary library;
  final Future<List<DeckEntry>> Function() entries;

  @override
  Future<List<ReelCardData>> load() async => library.cards(await entries());
}

/// For You: today's pool (or yesterday's remainder while today's builds),
/// else the taste pool in code order. The pool is this device's own build
/// or the one the TV shares (see [ReelPool]). When today's build lands here,
/// or the TV's shared pool for today arrives through [sharedChanges], [rebuilt]
/// fires and the session takes it.
class ForYouDeck extends ReelDeck {
  ForYouDeck({
    required this.pool,
    required this.library,
    required this.candidates,
    required this.facts,
    Listenable? sharedChanges,
  }) {
    _rebuilt = _PoolRebuilt(sharedChanges, () => unawaited(_onSharedChange()));
  }

  final ReelPool pool;
  final ReelLibrary library;
  final Future<List<PoolCandidate>> Function() candidates;
  final Future<String> Function() facts;
  Future<void>? _building;
  ({String day, Future<List<PoolCandidate>> list})? _candidates;

  /// The shared pool's day as last seen, so only a new one fires [rebuilt].
  String? _sharedDay;

  @override
  String get id => 'for-you';
  @override
  String get name => 'For You';
  @override
  bool get keepsSeen => false;
  @override
  bool get daily => true;

  /// Fires when today's build has been cached, or today's shared pool has
  /// arrived. Listens to the synced data only while something listens here.
  @override
  Listenable get rebuilt => _rebuilt;
  late final _PoolRebuilt _rebuilt;

  @override
  Future<List<ReelCardData>> load() async {
    _sharedDay = (await pool.shared())?.day;
    final cached = await pool.cachedPool();
    if (await pool.shouldBuild()) _building ??= _buildToday();
    if (cached != null && cached.isNotEmpty) return library.cards(cached);
    return worthShowing(await library.cards(await pool.codeOrder(await _todaysCandidates())));
  }

  /// The synced data changed (a sync or a TV snapshot): when it brought the
  /// shared pool for today, and this device has no pool of its own for
  /// today (its own comes first), the session takes it.
  Future<void> _onSharedChange() async {
    try {
      final day = (await pool.shared())?.day;
      if (day == null || day == _sharedDay) return;
      _sharedDay = day;
      if (day != ReelPool.dateOf(pool.now()) || await pool.hasOwnToday()) return;
      appLogger.i('[ReelDeck] for-you: shared pool for $day arrived');
      _rebuilt.bump();
    } catch (e) {
      appLogger.d('Reel: shared pool check failed', error: e);
    }
  }

  /// [candidates], gathered once a day: code order and the build share it.
  /// A failed gather isn't kept.
  Future<List<PoolCandidate>> _todaysCandidates() {
    final day = pool.today();
    final have = _candidates;
    if (have != null && have.day == day) return have.list;
    final list = candidates();
    _candidates = (day: day, list: list);
    unawaited(
      list.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_candidates?.list, list)) _candidates = null;
        },
      ),
    );
    return list;
  }

  /// Today's gather, when the Reel will need it: started when today's build
  /// is due, or joined when already running. Completes when the gather (the
  /// brain's similarity reads among it) is done, so the app can wait for it
  /// before the Reel yields the brain; a failed gather completes too.
  Future<void> prepare() async {
    try {
      final have = _candidates;
      if (have == null || have.day != pool.today()) {
        if (!await pool.shouldBuild()) return;
      }
      await _todaysCandidates();
    } catch (e) {
      appLogger.d('Reel: For You gather failed', error: e);
    }
  }

  /// The public's verdict, 0-10: IMDb, else TMDB, RT audience or the Plex
  /// audience score. Null when nothing rates it.
  static double? publicScore(TitleFacts f) => f.imdb ?? f.tmdb ?? f.rtAudience ?? f.audience;

  /// Below this the code-order stopgap leaves a title out.
  static const double qualityFloor = 6.0;

  /// Code order (before today's build lands) has no judge: similarity alone
  /// put 2-to-3-star titles on top. It keeps to titles the public rates at
  /// least [qualityFloor], in similarity order, with unrated titles after
  /// the rated ones. The daily build decides for itself from the same
  /// ratings.
  static List<ReelCardData> worthShowing(List<ReelCardData> cards) {
    final rated = <ReelCardData>[], unrated = <ReelCardData>[];
    for (final c in cards) {
      final score = publicScore(c.facts);
      if (score == null) {
        unrated.add(c);
      } else if (score >= qualityFloor) {
        rated.add(c);
      }
    }
    return [...rated, ...unrated];
  }

  /// The first Reel open of the day starts the build (on a phone, only
  /// once the TV's shared pool is stale); nothing schedules it.
  Future<void> _buildToday() async {
    try {
      final built = await pool.build(await _todaysCandidates(), facts: await facts());
      if (built != null) _rebuilt.bump();
    } catch (e) {
      appLogger.w('Reel: For You build failed', error: e);
    } finally {
      _building = null;
    }
  }

  /// Tests and the History page: wait for a build in flight.
  Future<void> get building => _building ?? Future.value();
}

/// Fits tonight keeps films this long or shorter, in minutes (D8).
const int fitsTonightFilmMinutes = 110;

/// Fits tonight keeps shows whose episodes run this long or shorter, in
/// minutes (D8).
const int fitsTonightEpisodeMinutes = 45;

/// Fits tonight: today's For You order, kept to films of at most
/// [fitsTonightFilmMinutes] and shows whose episodes run at most
/// [fitsTonightEpisodeMinutes]. A title of unknown length is left out
/// (nothing says it fits). Each card's chip shows its length. It follows
/// For You's day and takes its fresh builds through For You's [rebuilt].
class FitsTonightDeck extends ReelDeck {
  FitsTonightDeck({required this.forYou});

  final ForYouDeck forYou;

  @override
  String get id => 'fits-tonight';
  @override
  String get name => 'Fits tonight';
  @override
  bool get keepsSeen => false;
  @override
  bool get daily => true;
  @override
  Listenable get rebuilt => forYou.rebuilt;

  @override
  Future<List<ReelCardData>> load() async => [
    for (final c in await forYou.load())
      if (fitLine(c.facts) case final chip?)
        ReelCardData(
          title: c.title,
          facts: c.facts,
          best: c.best,
          chip: chip,
          why: c.why,
          cluster: c.cluster,
          hook: c.hook,
        ),
  ];

  /// The card's length when it fits tonight, else null: a film's
  /// [TitleFacts.lengthLine] ("1h 42m"), or a show's episode length
  /// ("40m episodes"). [TitleFacts.runtimeMinutes] is a film's length or a
  /// show's episode length.
  static String? fitLine(TitleFacts f) {
    final m = f.runtimeMinutes;
    if (m == null || m <= 0) return null;
    if (f.isShow) return m <= fitsTonightEpisodeMinutes ? '${m}m episodes' : null;
    return m <= fitsTonightFilmMinutes ? f.lengthLine() : null;
  }
}

/// [ForYouDeck.rebuilt]: its own bumps, plus [source] (the synced data
/// changing) while it has listeners, so a deck the controller has let go
/// of holds no listener on the app-wide notifier.
class _PoolRebuilt extends ChangeNotifier {
  _PoolRebuilt(this.source, this.onSource);

  final Listenable? source;
  final VoidCallback onSource;

  void bump() => notifyListeners();

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) source?.addListener(onSource);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) source?.removeListener(onSource);
  }

  @override
  void dispose() {
    source?.removeListener(onSource);
    super.dispose();
  }
}

/// Anime openings: shows from the anime libraries, seen ones allowed and
/// badged (an opening is a song). Unseen first, then by score.
EntriesDeck animeOpeningsDeck({required ReelLibrary library, required Future<IndexDatabase> Function() database}) =>
    EntriesDeck(
      id: 'anime-openings',
      name: 'Anime openings',
      library: library,
      keepsSeen: true,
      entries: () async {
        final db = await database();
        final rows = await db
            .customSelect(
              "SELECT * FROM index_titles WHERE type = 'show' AND lower(library_title) LIKE '%anime%' "
              'ORDER BY (COALESCE(watched_episode_count, 0) > 0) ASC, audience_rating DESC LIMIT 120',
              readsFrom: {db.indexTitles},
            )
            .get();
        return [
          for (final r in rows)
            if (db.indexTitles.map(r.data) case final t) DeckEntry(serverId: t.serverId, ratingKey: t.ratingKey),
        ];
      },
    );

/// A deck entry for a server item, or a catalog stand-in by its ids.
DeckEntry? entryOf(MediaItem item, {String? chip}) {
  final isShow = item.kind == MediaKind.show;
  if (!item.isCatalogItem && item.serverId != null) {
    return DeckEntry(serverId: item.serverId, ratingKey: item.id, isShow: isShow, chip: chip);
  }
  final ids = item.catalogItem?.ids;
  if (ids == null || (ids.imdb == null && ids.tmdb == null && ids.tvdb == null)) return null;
  return DeckEntry(imdb: ids.imdb, tmdb: ids.tmdb?.toString(), tvdb: ids.tvdb?.toString(), isShow: isShow, chip: chip);
}

/// Most Watched This Week: the raw Trakt charts, films and shows taken in
/// turn, each in its own order, limited to titles on the servers. Never
/// re-ranked; seen titles kept and badged.
EntriesDeck mostWatchedDeck({
  required ReelLibrary library,
  required Future<List<MediaItem>> Function() films,
  required Future<List<MediaItem>> Function() shows,
}) => EntriesDeck(
  id: 'most-watched',
  name: 'Most Watched',
  library: library,
  keepsSeen: true,
  raw: true,
  entries: () async {
    final (f, s) = await (films(), shows()).wait;
    final out = <DeckEntry>[];
    for (var i = 0; i < f.length || i < s.length; i++) {
      final show = i < s.length ? entryOf(s[i], chip: '#${i + 1} show this week') : null;
      final film = i < f.length ? entryOf(f[i], chip: '#${i + 1} film this week') : null;
      if (show != null) out.add(show);
      if (film != null) out.add(film);
    }
    return out;
  },
);

/// A saved AI answer as a channel: the answer's order, seen titles dropped
/// unless the answer is a franchise list (most picks share a collection).
class AiAnswerDeck extends ReelDeck {
  AiAnswerDeck({required this.entry, required this.library});

  final AiHistoryEntry entry;
  final ReelLibrary library;
  bool? _franchise;

  @override
  String get id => 'ai:${entry.id}';
  @override
  String get name => entry.label;
  @override
  bool get keepsSeen => _franchise ?? false;
  @override
  bool get raw => true;

  @override
  Future<List<ReelCardData>> load() async {
    final cards = await library.cards([for (final item in entry.items) ?entryOf(item, chip: entry.label)]);
    final collections = <String, int>{};
    for (final c in cards) {
      for (final col in c.best.collections.split('|').where((s) => s.isNotEmpty)) {
        collections[col] = (collections[col] ?? 0) + 1;
      }
    }
    _franchise = cards.length >= 3 && collections.values.any((n) => n >= cards.length * 0.6);
    return cards;
  }
}

/// How many titles played lately seed For You (newest first).
const int forYouRecentSeeds = 6;

/// How far back a play still counts as lately.
const Duration forYouRecentWithin = Duration(days: 30);

/// How many Reel Saves seed For You (newest first).
const int forYouSaveSeeds = 6;

/// Similar titles taken per seed, as the taste pool does.
const int forYouPerSeed = 25;

/// At most this many titles added in the last [PoolCandidate.newWithin].
const int forYouNewTitles = 60;

/// For You candidates, from several sources, each named in the candidate's
/// line: the taste pool (similar unwatched titles to their best-loved
/// ones), titles similar to what they played lately and to their Reel
/// Saves, the unseen picks of their saved AI answers and of the AI page's
/// suggested lists, and unseen titles added in the last
/// [PoolCandidate.newWithin]. Facts only: code never judges taste here,
/// and sets no mix of films and shows. The sources are taken in turn only
/// so each reaches the list before [ReelPool.maxCandidates] bounds it; a
/// title from several sources is one candidate with all of their facts.
///
/// [asks], [suggested] and [added] stand in for the saved answers, the
/// suggested lists and the library's newest titles (tests).
Future<List<PoolCandidate>> forYouCandidates({
  required ReelLibrary library,
  required ReelStore store,
  HistoryBrain? brain,
  DateTime? now,
  Future<List<AiHistoryEntry>> Function()? asks,
  Future<List<AiHistoryEntry>> Function()? suggested,
  Future<List<({DeckEntry entry, DateTime added})>> Function(DateTime since)? added,
}) async {
  final b = brain ?? HistoryBrain.instance;
  final at = now ?? DateTime.now();
  final sources = <List<PoolCandidate>>[];

  // Titles like the given seeds, in order of summed similarity.
  Future<List<PoolCandidate>> similarTo(
    List<({String id, String name})> seeds,
    PoolCandidate Function(TitleProfile p, double score, String seed) make,
  ) async {
    final pool = <String, PoolCandidate>{};
    for (final seed in seeds) {
      for (final hit in await b.similar(seed.id, limit: forYouPerSeed, watched: false)) {
        final p = hit.profile;
        if (!p.inLibrary || p.serverId == null || p.ratingKey == null) continue;
        final c = make(p, hit.score, seed.name);
        pool[p.id] = pool[p.id]?.merge(c) ?? c;
      }
    }
    return pool.values.toList()..sort((a, b) => b.score.compareTo(a.score));
  }

  DeckEntry entryFor(TitleProfile p) => DeckEntry(serverId: p.serverId, ratingKey: p.ratingKey);

  try {
    final watched = await b.watchedProfiles();
    sources.add([
      for (final hit in await AiBriefing.tastePool(b, watched, at))
        if (hit.profile case final p when p.inLibrary && p.serverId != null && p.ratingKey != null)
          PoolCandidate(entry: entryFor(p), titleId: p.id, score: hit.score, like: hit.like),
    ]);
    // What they played lately (real dated plays, not imports), newest first.
    final since = at.subtract(forYouRecentWithin);
    final recent = [
      for (final p in watched)
        if (p.lastWatched case final last? when last.isAfter(since)) p,
    ]..sort((a, b) => b.lastWatched!.compareTo(a.lastWatched!));
    final seeds = [for (final p in recent.take(forYouRecentSeeds)) (id: p.id, name: p.title)];
    sources.add(
      await similarTo(
        seeds,
        (p, score, seed) => PoolCandidate(entry: entryFor(p), titleId: p.id, score: score, recent: [seed]),
      ),
    );
  } catch (e) {
    appLogger.d('Reel: taste pool unavailable', error: e);
  }
  try {
    // Reel Saves: the synced picks (either device) and this device's saves
    // within [forYouRecentWithin], newest first.
    final saves = <String, ({String name, DateTime at})>{
      for (final p in await store.picks()) p.titleId: (name: p.title, at: p.at),
    };
    for (final e in await store.events(since: at.subtract(forYouRecentWithin))) {
      if (e.action != ReelAction.save.name) continue;
      final when = DateTime.fromMillisecondsSinceEpoch(e.at);
      final had = saves[e.titleId];
      if (had != null && !when.isAfter(had.at)) continue;
      final name = had?.name ?? (await b.profile(e.titleId))?.title;
      if (name != null) saves[e.titleId] = (name: name, at: when);
    }
    final newest = saves.entries.toList()..sort((a, b) => b.value.at.compareTo(a.value.at));
    final seeds = [for (final s in newest.take(forYouSaveSeeds)) (id: s.key, name: s.value.name)];
    sources.add(
      await similarTo(
        seeds,
        (p, score, seed) => PoolCandidate(entry: entryFor(p), titleId: p.id, score: score, saved: [seed]),
      ),
    );
  } catch (e) {
    appLogger.d('Reel: saves unavailable as seeds', error: e);
  }

  // A saved answer's or suggested list's picks, in its own order.
  List<PoolCandidate> picksOf(
    List<AiHistoryEntry> entries,
    PoolCandidate Function(DeckEntry e, String label, int i) make,
  ) => [
    for (final entry in entries)
      for (final (i, item) in entry.items.take(12).indexed)
        if (entryOf(item) case final e? when e.rowId != null) make(e, entry.label, i),
  ];

  try {
    sources.add(
      picksOf(
        await (asks ?? () => AiHistory.page(limit: 23))(),
        (e, label, i) => PoolCandidate(entry: e, titleId: 'row:${e.rowId}', score: 0.5 - i * 0.02, askedFor: label),
      ),
    );
  } catch (e) {
    appLogger.d('Reel: saved answers unavailable', error: e);
  }
  try {
    sources.add(
      picksOf(
        await (suggested ?? _suggestedLists)(),
        (e, label, i) => PoolCandidate(entry: e, titleId: 'row:${e.rowId}', score: 0.45 - i * 0.02, suggested: label),
      ),
    );
  } catch (e) {
    appLogger.d('Reel: suggested lists unavailable', error: e);
  }
  try {
    final since = at.subtract(PoolCandidate.newWithin);
    sources.add([
      for (final n in await (added ?? (since) => _addedSince(library, since))(since))
        PoolCandidate(entry: n.entry, titleId: 'row:${n.entry.rowId}', score: 0.4, added: n.added),
    ]);
  } catch (e) {
    appLogger.d('Reel: newest titles unavailable', error: e);
  }

  // The sources in turn, each in its own order, up to twice the bound (some
  // fall to the hard facts below).
  final taken = <PoolCandidate>[];
  final rows = <String>{};
  for (var i = 0; taken.length < ReelPool.maxCandidates * 2 && sources.any((s) => i < s.length); i++) {
    for (final s in sources) {
      if (i < s.length && taken.length < ReelPool.maxCandidates * 2) {
        final row = s[i].entry.rowId;
        if (row != null && rows.add(row)) taken.add(s[i]);
      }
    }
  }
  // Hard facts only: on the servers, not Kids-only, unseen, not resting.
  // Every copy of a card stands for it, so one title from several sources
  // is one candidate with all their facts, under the card's own copy.
  final cards = await library.cards([for (final c in taken) c.entry]);
  final byRow = {
    for (final c in cards)
      for (final copy in c.title.copies) '${copy.serverId}:${copy.ratingKey}': c,
  };
  final excluded = await store.excluded();
  final out = <String, PoolCandidate>{};
  // Every raw hit merged per card (a title can come from several sources).
  for (final s in sources) {
    for (final c in s) {
      final card = byRow[c.entry.rowId];
      if (card == null || !card.facts.seen.isUnseen || excluded.contains(card.id)) continue;
      final here = c.onCard(DeckEntry(serverId: card.best.serverId, ratingKey: card.best.ratingKey), card.id);
      out[card.id] = out[card.id]?.merge(here) ?? here;
    }
  }
  // In the order the sources were taken.
  final order = <String>{
    for (final c in taken)
      if (byRow[c.entry.rowId]?.id case final id? when out.containsKey(id)) id,
  };
  return [for (final id in order.take(ReelPool.maxCandidates)) out[id]!];
}

/// The AI page's suggested lists, as saved (no new call).
Future<List<AiHistoryEntry>> _suggestedLists() async => [for (final l in (await AiSuggestions.cached()).lists) l.entry];

/// Library titles added since [since], newest first: one row each.
Future<List<({DeckEntry entry, DateTime added})>> _addedSince(ReelLibrary library, DateTime since) async {
  final db = await library.database();
  final rows = await db
      .customSelect(
        'SELECT * FROM index_titles WHERE added_at >= ? ORDER BY added_at DESC LIMIT ?',
        variables: [Variable<int>(since.millisecondsSinceEpoch ~/ 1000), Variable<int>(forYouNewTitles * 2)],
        readsFrom: {db.indexTitles},
      )
      .get();
  final out = <({DeckEntry entry, DateTime added})>[];
  final groups = <String>{};
  for (final r in rows) {
    final t = db.indexTitles.map(r.data);
    final secs = t.addedAt;
    if (secs == null || !groups.add(t.groupKey)) continue;
    out.add((
      entry: DeckEntry(serverId: t.serverId, ratingKey: t.ratingKey),
      added: DateTime.fromMillisecondsSinceEpoch(secs * 1000),
    ));
    if (out.length >= forYouNewTitles) break;
  }
  return out;
}

/// The facts block the daily build reads first: how they watch lately, the
/// day and the local time it was built, and what the Reel saw them do on this device and the other one:
/// counts, counts per kind of title (the pool's clusters, from [pool]) and
/// the titles they passed on lately. [nameOf] names a title id (the brain's
/// profile by default).
Future<String> forYouFacts({
  required ReelStore store,
  ReelPool? pool,
  HistoryBrain? brain,
  DateTime? now,
  Future<String?> Function(String titleId)? nameOf,
}) async {
  final b = brain ?? HistoryBrain.instance;
  final at = now ?? DateTime.now();
  final lines = <String>[];
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  String two(int n) => n.toString().padLeft(2, '0');
  lines.add('Today is ${days[at.weekday - 1]}; the local time is ${two(at.hour)}:${two(at.minute)}.');
  try {
    lines.add('Their taste:\n${await b.taste()}');
    final watched = await b.watchedProfiles();
    String window(int d) {
      final since = at.subtract(Duration(days: d));
      final counts = <String, int>{};
      for (final p in watched) {
        final n = p.watches.where((w) => w.isAfter(since)).length;
        if (n > 0) counts[p.title] = n;
      }
      final top = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      return top.take(12).map((e) => '${e.key} ${e.value}').join(', ');
    }

    lines.add('Real plays, last 30 days: ${window(30)}');
    lines.add('Real plays, last 90 days: ${window(90)}');
  } catch (e) {
    appLogger.d('Reel: brain facts unavailable', error: e);
  }
  // Cards left before their clip played are neutral, not a Reel habit (the
  // signals leave them out).
  final signals = pool?.signals ?? ReelSignals(store: store, host: true, clock: () => at);
  final seen = await signals.since(at.subtract(const Duration(days: 30)));
  final clusters = pool == null ? const <String, String>{} : await pool.clusters();
  final counts = ReelSignals.countsLine(seen);
  if (counts.isNotEmpty) lines.add('In the Reel, last 30 days, both devices together: $counts.');
  final kinds = ReelSignals.clusterLines(seen, clusters);
  if (kinds.isNotEmpty) lines.add('In the Reel by kind of title, last 30 days:\n${kinds.join('\n')}');
  final passed = await _passedOn(store, seen, at, nameOf ?? (id) async => (await b.profile(id))?.title);
  if (passed.isNotEmpty) {
    lines.add(
      'Passed on in the Reel lately (Not for me, newest first): '
      '${[for (final (id, name) in passed) clusters[id] == null ? name : '$name (${clusters[id]})'].join(', ')}',
    );
  }
  return lines.join('\n');
}

/// How far back a Not for me still counts as "lately".
const Duration passedOnWindow = Duration(days: 180);

/// How many passes the facts name.
const int passedOnShown = 30;

/// The newest [passedOnShown] titles passed on within [passedOnWindow]:
/// the synced vetoes (either device) and the Not for me signals, named by
/// [nameOf]; titles it can't name are left out.
Future<List<(String, String)>> _passedOn(
  ReelStore store,
  List<ReelSignal> seen,
  DateTime now,
  Future<String?> Function(String) nameOf,
) async {
  final when = <String, DateTime>{};
  void note(String id, DateTime at) {
    final had = when[id];
    if (had == null || at.isAfter(had)) when[id] = at;
  }

  try {
    for (final MapEntry(:key, :value) in (await store.passedOn()).entries) {
      note(key, value);
    }
  } catch (e) {
    appLogger.d('Reel: passes unavailable', error: e);
  }
  for (final s in seen) {
    if (s.action == ReelAction.notForMe) note(s.titleId, s.at);
  }
  final since = now.subtract(passedOnWindow);
  final newest = when.entries.where((e) => e.value.isAfter(since)).toList()..sort((a, b) => b.value.compareTo(a.value));
  final out = <(String, String)>[];
  for (final e in newest) {
    if (out.length >= passedOnShown) break;
    String? name;
    try {
      name = await nameOf(e.key);
    } catch (_) {}
    if (name != null && name.isNotEmpty) out.add((e.key, name));
  }
  return out;
}
