import 'dart:async';

import '../../media/catalog_item_ref.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/app_logger.dart';
import '../ai/ai_briefing.dart';
import '../ai/ai_history.dart';
import '../ai/facts/title_facts.dart';
import '../brain/history_brain.dart';
import '../library_index/index_database.dart';
import 'reel_decay.dart';
import 'reel_library.dart';
import 'reel_pool.dart';
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
/// else the taste pool in code order.
class ForYouDeck extends ReelDeck {
  ForYouDeck({required this.pool, required this.library, required this.candidates, required this.facts});

  final ReelPool pool;
  final ReelLibrary library;
  final Future<List<PoolCandidate>> Function() candidates;
  final Future<String> Function() facts;
  Future<void>? _building;

  @override
  String get id => 'for-you';
  @override
  String get name => 'For You';
  @override
  bool get keepsSeen => false;

  @override
  Future<List<ReelCardData>> load() async {
    final cached = await pool.cachedPool();
    if (!await pool.hasToday()) _building ??= _buildToday();
    if (cached != null && cached.isNotEmpty) return library.cards(cached);
    return worthShowing(await library.cards(await pool.codeOrder(await candidates())));
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

  /// The first Reel open of the day starts the build; nothing schedules it.
  Future<void> _buildToday() async {
    try {
      await pool.build(await candidates(), facts: await facts());
    } catch (e) {
      appLogger.w('Reel: For You build failed', error: e);
    } finally {
      _building = null;
    }
  }

  /// Tests and the History page: wait for a build in flight.
  Future<void> get building => _building ?? Future.value();
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

/// For You candidates: the taste pool (similar unwatched titles to their
/// best-loved ones) plus the unseen picks of their saved AI answers. Facts
/// only: code never judges taste here.
Future<List<PoolCandidate>> forYouCandidates({
  required ReelLibrary library,
  required ReelStore store,
  HistoryBrain? brain,
  DateTime? now,
}) async {
  final b = brain ?? HistoryBrain.instance;
  final at = now ?? DateTime.now();
  final out = <String, PoolCandidate>{};
  try {
    final watched = await b.watchedProfiles();
    for (final hit in await AiBriefing.tastePool(b, watched, at)) {
      final p = hit.profile;
      if (!p.inLibrary || p.serverId == null || p.ratingKey == null) continue;
      out.putIfAbsent(
        p.id,
        () => PoolCandidate(
          entry: DeckEntry(serverId: p.serverId, ratingKey: p.ratingKey),
          titleId: p.id,
          score: hit.score,
          like: hit.like,
        ),
      );
    }
  } catch (e) {
    appLogger.d('Reel: taste pool unavailable', error: e);
  }
  try {
    for (final entry in await AiHistory.page(limit: 23)) {
      for (final (i, item) in entry.items.take(12).indexed) {
        final e = entryOf(item);
        if (e?.rowId == null) continue;
        final key = 'row:${e!.rowId}';
        if (out.values.any((c) => c.entry.rowId == e.rowId)) continue;
        out[key] = PoolCandidate(entry: e, titleId: key, score: 0.5 - i * 0.02, askedFor: entry.label);
      }
    }
  } catch (e) {
    appLogger.d('Reel: saved answers unavailable', error: e);
  }
  // Hard facts only: on the servers, not Kids-only, unseen, not resting.
  final list = out.values.toList()..sort((a, b) => b.score.compareTo(a.score));
  final cards = await library.cards([for (final c in list.take(ReelPool.maxCandidates * 2)) c.entry]);
  final ok = {
    for (final c in cards)
      if (c.facts.seen.isUnseen) c.best.id: c,
  };
  final excluded = await store.excluded();
  return [
    for (final c in list)
      if (ok[c.entry.rowId] case final card? when !excluded.contains(card.id))
        PoolCandidate(entry: c.entry, titleId: card.id, score: c.score, like: c.like, askedFor: c.askedFor),
  ].take(ReelPool.maxCandidates).toList();
}

/// The facts block the daily build reads first: how they watch lately, the
/// day, and what the Reel saw them do.
Future<String> forYouFacts({required ReelStore store, HistoryBrain? brain, DateTime? now}) async {
  final b = brain ?? HistoryBrain.instance;
  final at = now ?? DateTime.now();
  final lines = <String>[];
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  lines.add('Today is ${days[at.weekday - 1]}.');
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
  final events = await store.events(since: at.subtract(const Duration(days: 30)));
  if (events.isNotEmpty) {
    int n(ReelAction a) => events.where((e) => e.action == a.name).length;
    lines.add(
      'In the Reel, last 30 days: ${n(ReelAction.sampled)} sampled, ${n(ReelAction.toEnd)} watched to the end, '
      '${n(ReelAction.quickSkip)} skipped within 2 s, ${n(ReelAction.save)} saved, '
      '${n(ReelAction.watch) + n(ReelAction.watchOnTv)} played.',
    );
  }
  return lines.join('\n');
}
