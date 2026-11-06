import 'package:drift/drift.dart';
import 'package:plezy_brain/plezy_brain.dart';

import '../../../utils/app_logger.dart';
import '../../brain/history_brain.dart';
import '../../brain/history_profiles.dart';
import '../../library_index/index_database.dart';
import '../../library_index/library_index.dart';
import '../ai_watch_state.dart';
import 'title_facts.dart';

/// A brain profile by id, or null when the brain has none.
typedef ProfileLookup = TitleProfile? Function(TitleId id);

/// Fork: [TitleFacts] from the library index (every copy of a title) and
/// the history brain (the seen state). One query per batch, no Plex reads.
///
/// Scores: the index keeps Plex's numbers but not their source, so the
/// audience score is carried unlabelled ([TitleFacts.audience], a bare ★).
/// Labelled IMDb/RT/TMDB scores come from a title's rating list
/// ([TitleFacts.withRatings]) until the IMDb dataset job fills them here.
class IndexTitleFactsSource implements TitleFactsSource {
  IndexTitleFactsSource({
    required this.database,
    Future<ProfileLookup?> Function()? profiles,
    DateTime Function()? clock,
  }) : _profiles = profiles ?? (() async => null),
       _clock = clock ?? DateTime.now;

  /// The app's index and brain.
  factory IndexTitleFactsSource.app() => IndexTitleFactsSource(
    database: () => LibraryIndex.instance.database,
    profiles: () async {
      try {
        final store = await HistoryBrain.instance.store;
        return store.profile;
      } catch (e) {
        appLogger.d('Facts: brain unavailable, seen state from the index only', error: e);
        return null;
      }
    },
  );

  final Future<IndexDatabase> Function() database;
  final Future<ProfileLookup?> Function() _profiles;
  final DateTime Function() _clock;

  /// Loaded facts by copy (`serverId:ratingKey`), for [peek].
  final Map<String, TitleFacts> _byCopy = {};

  static const int _batch = 400;

  static bool isKidsLibrary(String libraryTitle) => libraryTitle.toLowerCase().contains('kids');

  @override
  TitleFacts? peek(String globalKey) => _byCopy[globalKey];

  @override
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs) async {
    final wanted = {for (final r in refs) r.groupKey: r};
    if (wanted.isEmpty) return const {};
    final db = await database();
    final ProfileLookup? profile = await _profiles();
    final now = _clock();

    final copies = <String, List<IndexedTitle>>{};
    final keys = wanted.keys.toList();
    for (var i = 0; i < keys.length; i += _batch) {
      final chunk = keys.sublist(i, i + _batch > keys.length ? keys.length : i + _batch);
      final rows = await db
          .customSelect(
            'SELECT * FROM index_titles WHERE group_key IN (${List.filled(chunk.length, '?').join(',')})',
            variables: [for (final k in chunk) Variable<String>(k)],
            readsFrom: {db.indexTitles},
          )
          .get();
      for (final r in rows) {
        final t = db.indexTitles.map(r.data);
        (copies[t.groupKey] ??= []).add(t);
      }
    }

    final out = <TitleId, TitleFacts>{};
    for (final MapEntry(key: group, value: ref) in wanted.entries) {
      final rows = copies[group];
      if (rows == null || rows.isEmpty) continue;
      TitleProfile? p;
      try {
        // The ref's id first, then any copy's own id (a copy matched by a
        // different external id keeps its watches under that id).
        p = profile?.call(ref.id);
        for (final t in rows) {
          if (p != null || profile == null) break;
          final id = LibraryRef.of(t).titleId;
          if (id != ref.id) p = profile(id);
        }
      } catch (e) {
        appLogger.d('Facts: brain profile unreadable', error: e);
      }
      final facts = factsOf(ref, rows, profile: p, now: now);
      out[ref.id] = facts;
      for (final t in rows) {
        _byCopy[t.id] = facts;
      }
    }
    return out;
  }

  /// The facts for [ref] from all its index [copies] and its brain
  /// [profile]. Pure, for tests.
  static TitleFacts factsOf(TitleRef ref, List<IndexedTitle> copies, {TitleProfile? profile, required DateTime now}) {
    final best = _best(copies);
    final kids = copies.where((t) => isKidsLibrary(t.libraryTitle)).length;
    // The best watch evidence any copy holds (a copy watched on Main still
    // counts when the 4K copy on Xtra has no plays).
    final watchedCopy = copies.reduce((a, b) => _watchScore(a) >= _watchScore(b) ? a : b);
    final row = WatchState.of(watchedCopy, profile);
    return TitleFacts(
      ref: ref,
      seen: SeenState.of(row: row, profile: profile, now: now),
      audience: best.audienceRating ?? profile?.audienceRating,
      certificate: best.contentRating ?? profile?.contentRating,
      inKidsLibrary: kids > 0,
      kidsLibraryOnly: kids == copies.length,
      genres: best.genres.isEmpty ? (profile?.genres ?? const []) : best.genres.split('|'),
      runtimeMinutes: best.durationMinutes ?? profile?.runtimeMinutes,
      episodes: best.type == 'show' ? best.episodeCount : null,
    );
  }

  /// The copy that stands for the title: most episodes, then a non-Kids
  /// library, then the most watched.
  static IndexedTitle _best(List<IndexedTitle> copies) => copies.reduce((a, b) {
    final ea = a.episodeCount ?? 0, eb = b.episodeCount ?? 0;
    if (ea != eb) return ea > eb ? a : b;
    final ka = isKidsLibrary(a.libraryTitle), kb = isKidsLibrary(b.libraryTitle);
    if (ka != kb) return ka ? b : a;
    return _watchScore(a) >= _watchScore(b) ? a : b;
  });

  static int _watchScore(IndexedTitle t) =>
      (t.watchedEpisodeCount ?? 0) * 4 +
      (t.viewCount ?? 0) * 4 +
      (t.lastViewedAt != null ? 2 : 0) +
      ((t.viewOffsetMs ?? 0) > 0 ? 1 : 0);

  /// The ref for an index row.
  static TitleRef refOf(IndexedTitle t) =>
      TitleRef(id: LibraryRef.of(t).titleId, groupKey: t.groupKey, globalKey: t.id);
}
