import 'package:drift/drift.dart';

import 'index_database.dart';
import 'library_index.dart';

/// The audience rating used for "best rated" ordering. Plex often reports a
/// perfect 10.0 for titles with only a handful of votes (very common on new
/// releases), so a 10.0 counts as 7.0 here instead of topping every list.
const String trustedRatingSql = 'CASE WHEN audience_rating >= 9.95 THEN 7.0 ELSE audience_rating END';

enum IndexWatchFilter { any, unwatched, inProgress, watched }

enum IndexSort { rating, added, released, title }

/// A structured search over the library index (what the AI helper's
/// `search_library` tool sends).
class IndexQuery {
  const IndexQuery({
    this.type,
    this.genresAll = const [],
    this.genresNone = const [],
    this.yearFrom,
    this.yearTo,
    this.releasedAfter,
    this.releasedBefore,
    this.addedAfter,
    this.minRating,
    this.maxMinutes,
    this.watch = IndexWatchFilter.any,
    this.person,
    this.country,
    this.library,
    this.sort = IndexSort.rating,
    this.limit = 30,
  });

  /// `movie` or `show`; null for both.
  final String? type;
  final List<String> genresAll;
  final List<String> genresNone;
  final int? yearFrom;
  final int? yearTo;

  /// `YYYY-MM-DD` bounds on the release (first air) date.
  final String? releasedAfter;
  final String? releasedBefore;
  final DateTime? addedAfter;

  /// Minimum audience rating, 0-10.
  final double? minRating;
  final int? maxMinutes;
  final IndexWatchFilter watch;

  /// Cast or director name (substring).
  final String? person;
  final String? country;

  /// Library title (substring), e.g. "Anime", "4K".
  final String? library;
  final IndexSort sort;
  final int limit;
}

extension LibraryIndexSearch on LibraryIndex {
  /// Titles matching [query], one per film/show (4K copies and the second
  /// server collapsed), best first.
  ///
  /// Fork: [seen] says a title was already seen somewhere the row doesn't
  /// know about (the history brain: other copies, Trakt, bulk marks); an
  /// `unwatched` search over-fetches and drops those.
  Future<List<IndexedTitle>> search(IndexQuery query, {bool Function(IndexedTitle t)? seen}) async {
    final db = await database;
    final where = <String>[];
    final args = <Variable<Object>>[];
    void add(String clause, [List<Object> values = const []]) {
      where.add(clause);
      args.addAll(values.map(Variable<Object>.new));
    }

    String pipes(String column) => "('|' || $column || '|')";
    if (query.type != null) add('type = ?', [query.type!]);
    for (final g in query.genresAll) {
      add('${pipes('genres')} LIKE ? COLLATE NOCASE', ['%|$g|%']);
    }
    for (final g in query.genresNone) {
      add('${pipes('genres')} NOT LIKE ? COLLATE NOCASE', ['%|$g|%']);
    }
    if (query.yearFrom != null) add('year >= ?', [query.yearFrom!]);
    if (query.yearTo != null) add('year <= ?', [query.yearTo!]);
    if (query.releasedAfter != null) add('release_date >= ?', [query.releasedAfter!]);
    if (query.releasedBefore != null) add('release_date <= ?', [query.releasedBefore!]);
    if (query.addedAfter != null) add('added_at >= ?', [query.addedAfter!.millisecondsSinceEpoch ~/ 1000]);
    if (query.minRating != null) add('audience_rating >= ?', [query.minRating!]);
    if (query.maxMinutes != null) add('duration_minutes <= ?', [query.maxMinutes!]);
    if (query.person != null) {
      add('(("cast" LIKE ? COLLATE NOCASE) OR (directors LIKE ? COLLATE NOCASE))', [
        '%${query.person}%',
        '%${query.person}%',
      ]);
    }
    if (query.country != null) add('${pipes('countries')} LIKE ? COLLATE NOCASE', ['%|${query.country}|%']);
    if (query.library != null) add('library_title LIKE ? COLLATE NOCASE', ['%${query.library}%']);
    switch (query.watch) {
      case IndexWatchFilter.any:
        break;
      case IndexWatchFilter.unwatched:
        add(
          "((type = 'movie' AND COALESCE(view_count, 0) = 0 AND COALESCE(view_offset_ms, 0) = 0) OR "
          "(type = 'show' AND COALESCE(watched_episode_count, 0) = 0))",
        );
      case IndexWatchFilter.inProgress:
        add(
          "((type = 'movie' AND COALESCE(view_offset_ms, 0) > 0) OR "
          "(type = 'show' AND watched_episode_count > 0 AND watched_episode_count < episode_count))",
        );
      case IndexWatchFilter.watched:
        add("((type = 'movie' AND view_count > 0) OR (type = 'show' AND watched_episode_count >= episode_count))");
    }
    final order = switch (query.sort) {
      IndexSort.rating => '$trustedRatingSql DESC NULLS LAST, critic_rating DESC NULLS LAST',
      IndexSort.added => 'added_at DESC',
      IndexSort.released => 'release_date DESC NULLS LAST',
      IndexSort.title => 'title COLLATE NOCASE',
    };
    final sql =
        'SELECT * FROM index_titles${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'} '
        'ORDER BY $order LIMIT ?';
    final dropSeen = seen != null && query.watch == IndexWatchFilter.unwatched;
    args.add(Variable<Object>(query.limit * (dropSeen ? 12 : 4)));
    final rows = await db.customSelect(sql, variables: args, readsFrom: {db.indexTitles}).get();
    return _onePerGroup([
      for (final r in rows)
        if (db.indexTitles.map(r.data) case final t when !dropSeen || !seen(t)) t,
    ], query.limit);
  }

  /// Full-text search over titles, summaries, taglines, cast, directors and
  /// collections, best matches first, one per film/show.
  Future<List<IndexedTitle>> textSearch(String text, {String? type, int limit = 30}) async {
    final terms = RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(text).map((m) => '"${m[0]}"').toList();
    if (terms.isEmpty) return const [];
    // Every word first; if nothing has them all, any of them.
    final all = await _fts(terms.join(' '), type: type, limit: limit);
    if (all.isNotEmpty || terms.length == 1) return all;
    return _fts(terms.join(' OR '), type: type, limit: limit);
  }

  Future<List<IndexedTitle>> _fts(String match, {String? type, required int limit}) async {
    final db = await database;
    final rows = await db
        .customSelect(
          'SELECT t.* FROM titles_fts f JOIN index_titles t ON t.rowid = f.rowid '
          'WHERE titles_fts MATCH ?${type == null ? '' : ' AND t.type = ?'} '
          'ORDER BY bm25(titles_fts, 10.0, 6.0, 1.0, 2.0, 3.0, 3.0, 4.0) LIMIT ?',
          variables: [Variable<String>(match), if (type != null) Variable<String>(type), Variable<int>(limit * 4)],
          readsFrom: {db.indexTitles},
        )
        .get();
    return _onePerGroup([for (final r in rows) db.indexTitles.map(r.data)], limit);
  }

  /// Every copy of a title (4K, both servers), for "available in 4K" and
  /// picking where to play.
  Future<List<IndexedTitle>> copiesOf(String groupKey) async {
    final db = await database;
    return (db.select(db.indexTitles)..where((t) => t.groupKey.equals(groupKey))).get();
  }

  static List<IndexedTitle> _onePerGroup(List<IndexedTitle> titles, int limit) {
    final seen = <String>{};
    final out = <IndexedTitle>[];
    for (final t in titles) {
      if (seen.add(t.groupKey)) out.add(t);
      if (out.length >= limit) break;
    }
    return out;
  }
}
