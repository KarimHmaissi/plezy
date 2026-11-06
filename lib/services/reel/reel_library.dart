import 'package:drift/drift.dart';

import '../ai/facts/index_title_facts_source.dart';
import '../ai/facts/title_facts.dart';
import '../library_index/index_database.dart';
import 'clip_resolver.dart';
import 'reel_premise.dart';

/// One entry of a deck before it is matched to the servers: a server copy,
/// or a title known only by its external ids (a Trakt chart entry).
class DeckEntry {
  const DeckEntry({
    this.serverId,
    this.ratingKey,
    this.imdb,
    this.tmdb,
    this.tvdb,
    this.isShow,
    this.chip,
    this.why,
    this.cluster,
    this.hook,
  });

  final String? serverId;
  final String? ratingKey;
  final String? imdb;
  final String? tmdb;
  final String? tvdb;
  final bool? isShow;

  /// A deck's own badge ("#3 this week").
  final String? chip;

  /// The daily build's why line (already anchor-checked).
  final String? why;
  final String? cluster;

  /// The daily build's premise in a line (already checked, see
  /// [ReelPremise.checkedHook]).
  final String? hook;

  String? get rowId => serverId != null && ratingKey != null ? '$serverId:$ratingKey' : null;
}

/// A card's title, matched to the library: every copy, facts, and the copy
/// Watch plays.
class ReelCardData {
  const ReelCardData({
    required this.title,
    required this.facts,
    required this.best,
    this.chip,
    this.why,
    this.cluster,
    this.hook,
  });

  final ReelTitle title;
  final TitleFacts facts;

  /// The copy that stands for the title (most episodes, not Kids, not 4K
  /// when an HD copy exists).
  final IndexedTitle best;
  final String? chip;
  final String? why;
  final String? cluster;

  /// What it is about, in a line (the daily build's, For You only).
  final String? hook;

  String get id => title.titleId;
}

/// Maps deck entries onto the library index: one card per `group_key`,
/// Kids-library-only titles left out, facts loaded in one batch. Index
/// reads only; no server requests.
class ReelLibrary {
  ReelLibrary({required this.database, required this.facts});

  final Future<IndexDatabase> Function() database;
  final TitleFactsSource facts;

  static bool _is4k(IndexedTitle t) => RegExp(r'\b(4k|uhd|2160)\b', caseSensitive: false).hasMatch(t.libraryTitle);
  static bool _isAnime(IndexedTitle t) => t.libraryTitle.toLowerCase().contains('anime');

  Future<List<ReelCardData>> cards(List<DeckEntry> entries) async {
    if (entries.isEmpty) return const [];
    final db = await database();

    // 1. Entries → one index row each.
    final rowIds = {for (final e in entries) ?e.rowId};
    final imdbs = {for (final e in entries) ?e.imdb};
    final tmdbs = {for (final e in entries) ?e.tmdb};
    final tvdbs = {for (final e in entries) ?e.tvdb};
    final hits = <IndexedTitle>[];
    Future<void> select(String column, Set<String> values) async {
      final list = values.toList();
      for (var i = 0; i < list.length; i += 400) {
        final chunk = list.sublist(i, i + 400 > list.length ? list.length : i + 400);
        final rows = await db
            .customSelect(
              'SELECT * FROM index_titles WHERE $column IN (${List.filled(chunk.length, '?').join(',')})',
              variables: [for (final v in chunk) Variable<String>(v)],
              readsFrom: {db.indexTitles},
            )
            .get();
        hits.addAll(rows.map((r) => db.indexTitles.map(r.data)));
      }
    }

    await select('id', rowIds);
    await select('imdb', imdbs);
    await select('tmdb', tmdbs);
    await select('tvdb', tvdbs);
    final byRow = {for (final t in hits) t.id: t};
    IndexedTitle? match(DeckEntry e) {
      if (e.rowId case final id? when byRow.containsKey(id)) return byRow[id];
      bool kind(IndexedTitle t) => e.isShow == null || (t.type == 'show') == e.isShow;
      return hits.where((t) => kind(t) && e.imdb != null && t.imdb == e.imdb).firstOrNull ??
          hits.where((t) => kind(t) && e.tmdb != null && t.tmdb == e.tmdb).firstOrNull ??
          hits.where((t) => kind(t) && e.tvdb != null && t.tvdb == e.tvdb).firstOrNull;
    }

    // 2. Every copy of each matched title.
    final matched = <(DeckEntry, IndexedTitle)>[];
    final seenGroups = <String>{};
    for (final e in entries) {
      final t = match(e);
      if (t != null && seenGroups.add(t.groupKey)) matched.add((e, t));
    }
    final groups = <String, List<IndexedTitle>>{};
    final keys = seenGroups.toList();
    for (var i = 0; i < keys.length; i += 400) {
      final chunk = keys.sublist(i, i + 400 > keys.length ? keys.length : i + 400);
      final rows = await db
          .customSelect(
            'SELECT * FROM index_titles WHERE group_key IN (${List.filled(chunk.length, '?').join(',')})',
            variables: [for (final k in chunk) Variable<String>(k)],
            readsFrom: {db.indexTitles},
          )
          .get();
      for (final r in rows) {
        final t = db.indexTitles.map(r.data);
        (groups[t.groupKey] ??= []).add(t);
      }
    }

    // 3. Facts in one batch.
    final refs = {for (final (_, t) in matched) t.groupKey: IndexTitleFactsSource.refOf(t)};
    final loaded = await facts.load(refs.values);

    final out = <ReelCardData>[];
    for (final (e, t) in matched) {
      final copies = groups[t.groupKey] ?? [t];
      final ref = refs[t.groupKey]!;
      final f = loaded[ref.id];
      if (f == null || f.kidsLibraryOnly) continue;
      final grownUp = copies.where((c) => !IndexTitleFactsSource.isKidsLibrary(c.libraryTitle)).toList();
      final pool = grownUp.isEmpty ? copies : grownUp;
      final hd = pool.where((c) => !_is4k(c)).toList();
      final best = (hd.isEmpty ? pool : hd).reduce((a, b) => (a.episodeCount ?? 0) >= (b.episodeCount ?? 0) ? a : b);
      out.add(
        ReelCardData(
          title: ReelTitle(
            titleId: ref.id,
            groupKey: t.groupKey,
            title: best.title,
            isShow: best.type == 'show',
            anime: copies.any(_isAnime),
            tvdbId: int.tryParse(best.tvdb ?? ''),
            tmdbId: int.tryParse(best.tmdb ?? ''),
            copies: [for (final c in pool) ReelCopy(serverId: c.serverId, ratingKey: c.ratingKey, is4k: _is4k(c))],
          ),
          facts: f,
          best: best,
          chip: e.chip,
          why: e.why,
          cluster: e.cluster,
          hook: e.hook,
        ),
      );
    }
    return out;
  }
}
