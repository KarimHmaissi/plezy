import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../../utils/app_logger.dart';
import '../library_index/index_database.dart';
import '../library_index/index_search.dart';
import '../library_index/library_index.dart';
import '../trackers/trakt/trakt_client.dart';
import '../trackers/trakt/trakt_constants.dart';

/// One pick the model chose for the user: an index title id and why.
typedef AiPick = ({String id, String reason});

/// The tools the AI helper can call, backed by the library index (and Trakt
/// ratings for a shortlist). All read-only except [showPicksTool], which is
/// how the model hands back its final picks.
class AiTools {
  AiTools({required this.index, this.trakt});

  final LibraryIndex index;
  final TraktClient? trakt;

  /// Picks from the last `show_picks` call, and its intro line.
  List<AiPick> picks = const [];
  String? intro;

  static const String showPicksTool = 'show_picks';

  static const _typeEnum = {
    'type': 'string',
    'enum': ['movie', 'show'],
  };

  /// Tool definitions for the request. Kept in a fixed order so the prompt
  /// cache prefix stays stable.
  List<Map<String, Object?>> definitions() => [
    {
      'name': 'search_library',
      'description':
          'Structured search over every movie and show on the user\'s Plex servers. Use for "only what\'s here" '
          'requests: genres, years, release or added dates, ratings, runtime, watch state, people, library. Returns '
          'one entry per title with its id. Ratings are audience ratings (usually IMDb, 0-10); brand-new titles can '
          'show inflated ratings from very few votes, so check get_ratings before calling a new title "top rated".',
      'input_schema': {
        'type': 'object',
        'properties': {
          'type': _typeEnum,
          'genres_all': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Every one of these genres, e.g. ["Crime","Thriller"]',
          },
          'genres_none': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'None of these genres',
          },
          'year_from': {'type': 'integer'},
          'year_to': {'type': 'integer'},
          'released_after': {'type': 'string', 'description': 'YYYY-MM-DD (a show\'s first air date)'},
          'released_before': {'type': 'string', 'description': 'YYYY-MM-DD'},
          'added_within_days': {'type': 'integer', 'description': 'Added to the servers in the last N days'},
          'min_rating': {'type': 'number', 'description': '0-10'},
          'max_minutes': {'type': 'integer', 'description': 'Movie runtime or show episode length'},
          'watch': {
            'type': 'string',
            'enum': ['any', 'unwatched', 'in_progress', 'watched'],
          },
          'person': {'type': 'string', 'description': 'Actor or director name'},
          'country': {'type': 'string'},
          'library': {'type': 'string', 'description': 'Library name contains, e.g. "Anime", "Kids", "4K", "Docs"'},
          'sort': {
            'type': 'string',
            'enum': ['rating', 'added', 'released', 'title'],
          },
          'limit': {'type': 'integer', 'description': 'Max 40, default 20'},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'text_search',
      'description':
          'Full-text search over titles, plot summaries, taglines, cast, directors and collections, for themes or '
          'plot words ("heist", "time loop", "Jane Austen"). Returns one entry per title with its id.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
          'type': _typeEnum,
          'limit': {'type': 'integer', 'description': 'Max 40, default 20'},
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'find_titles',
      'description':
          'Check which titles you have in mind are on the user\'s servers. Pass titles from your own knowledge '
          '(with year when you know it); returns the matching entries with ids, and lists the ones not found.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'titles': {
            'type': 'array',
            'maxItems': 30,
            'items': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'},
                'year': {'type': 'integer'},
              },
              'required': ['title'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['titles'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_title',
      'description':
          'Details for one title by id: summary, genres, cast, ratings, runtime, the user\'s progress, and every '
          'copy (4K, other server).',
      'input_schema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_history',
      'description': 'What the user watched most recently (movies and shows), newest first.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer', 'description': 'Max 50, default 25'},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_continue_watching',
      'description': 'Movies the user stopped part-way through and shows they\'ve started but not finished.',
      'input_schema': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
    },
    {
      'name': 'get_ratings',
      'description':
          'Trakt community rating and vote count for up to 10 shortlisted titles (by id), to judge new or '
          'surprisingly highly rated titles. Use only on a shortlist, never on long result lists.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'ids': {
            'type': 'array',
            'items': {'type': 'string'},
            'maxItems': 10,
          },
        },
        'required': ['ids'],
        'additionalProperties': false,
      },
    },
    {
      'name': showPicksTool,
      'description':
          'Show your final picks to the user as a row of playable cards. Call exactly once, at the end, with ids '
          'returned by the other tools only (never invented). 3-12 picks, best first, each with one short reason.',
      'strict': true,
      'input_schema': {
        'type': 'object',
        'properties': {
          'intro': {'type': 'string', 'description': 'One friendly sentence introducing the picks'},
          'picks': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'reason': {'type': 'string', 'description': 'One short sentence: why this fits the request'},
              },
              'required': ['id', 'reason'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['intro', 'picks'],
        'additionalProperties': false,
      },
    },
  ];

  /// Run one tool call; returns the text for its `tool_result`.
  Future<String> run(String name, Map<String, dynamic> input) async {
    switch (name) {
      case 'search_library':
        return _list(await index.search(_query(input)));
      case 'text_search':
        return _list(
          await index.textSearch(
            input['query'] as String? ?? '',
            type: input['type'] as String?,
            limit: _limit(input['limit'], 20, 40),
          ),
        );
      case 'find_titles':
        return _findTitles(input);
      case 'get_title':
        return _getTitle(input['id'] as String? ?? '');
      case 'get_history':
        return _list(await _history(_limit(input['limit'], 25, 50)), withWatched: true);
      case 'get_continue_watching':
        return _list(await _continueWatching(), withWatched: true);
      case 'get_ratings':
        return _ratings([...(input['ids'] as List? ?? const []).whereType<String>()].take(10).toList());
      case showPicksTool:
        intro = input['intro'] as String?;
        picks = [
          for (final p in (input['picks'] as List? ?? const []).whereType<Map>())
            if (p['id'] is String) (id: p['id'] as String, reason: p['reason'] as String? ?? ''),
        ];
        return 'Shown to the user.';
      default:
        throw ArgumentError('Unknown tool $name');
    }
  }

  static int _limit(Object? value, int fallback, int max) => ((value as num?)?.toInt() ?? fallback).clamp(1, max);

  IndexQuery _query(Map<String, dynamic> i) {
    List<String> strings(String key) => [...(i[key] as List? ?? const []).whereType<String>()];
    final days = (i['added_within_days'] as num?)?.toInt();
    return IndexQuery(
      type: i['type'] as String?,
      genresAll: strings('genres_all'),
      genresNone: strings('genres_none'),
      yearFrom: (i['year_from'] as num?)?.toInt(),
      yearTo: (i['year_to'] as num?)?.toInt(),
      releasedAfter: i['released_after'] as String?,
      releasedBefore: i['released_before'] as String?,
      addedAfter: days == null ? null : DateTime.now().subtract(Duration(days: days)),
      minRating: (i['min_rating'] as num?)?.toDouble(),
      maxMinutes: (i['max_minutes'] as num?)?.toInt(),
      watch: switch (i['watch']) {
        'unwatched' => IndexWatchFilter.unwatched,
        'in_progress' => IndexWatchFilter.inProgress,
        'watched' => IndexWatchFilter.watched,
        _ => IndexWatchFilter.any,
      },
      person: i['person'] as String?,
      country: i['country'] as String?,
      library: i['library'] as String?,
      sort: switch (i['sort']) {
        'added' => IndexSort.added,
        'released' => IndexSort.released,
        'title' => IndexSort.title,
        _ => IndexSort.rating,
      },
      limit: _limit(i['limit'], 20, 40),
    );
  }

  /// One compact line per title, cheap in tokens.
  static String line(IndexedTitle t, {bool withWatched = false}) {
    final parts = <String>[
      t.id,
      '${t.title}${t.year == null ? '' : ' (${t.year})'}',
      t.type,
      if (t.genres.isNotEmpty) t.genres.replaceAll('|', ', '),
      if (t.audienceRating != null) '★${t.audienceRating!.toStringAsFixed(1)}',
      if (t.type == 'movie' && t.durationMinutes != null) '${t.durationMinutes} min',
      if (t.type == 'show' && t.episodeCount != null) '${t.episodeCount} eps',
      if (t.releaseDate != null && t.type == 'show') 'first aired ${t.releaseDate}',
      _watchState(t),
      t.libraryTitle,
    ];
    return parts.where((p) => p.isNotEmpty).join(' | ');
  }

  static String _watchState(IndexedTitle t) {
    if (t.type == 'show') {
      final watched = t.watchedEpisodeCount ?? 0;
      final total = t.episodeCount ?? 0;
      if (watched == 0) return 'unwatched';
      if (watched >= total) return 'watched all';
      return 'watched $watched/$total';
    }
    if ((t.viewOffsetMs ?? 0) > 0) return 'in progress';
    if ((t.viewCount ?? 0) > 0) return 'watched';
    return 'unwatched';
  }

  static String _list(List<IndexedTitle> titles, {bool withWatched = false}) =>
      titles.isEmpty ? 'No matches.' : titles.map((t) => line(t, withWatched: withWatched)).join('\n');

  Future<String> _findTitles(Map<String, dynamic> input) async {
    final db = await index.database;
    final found = <String>[];
    final missing = <String>[];
    for (final t in (input['titles'] as List? ?? const []).whereType<Map>().take(30)) {
      final title = (t['title'] as String? ?? '').trim();
      if (title.isEmpty) continue;
      final year = (t['year'] as num?)?.toInt();
      final rows = await db
          .customSelect(
            'SELECT * FROM index_titles WHERE (title = ? COLLATE NOCASE OR original_title = ? COLLATE NOCASE)'
            '${year == null ? '' : ' AND year BETWEEN ? AND ?'} ORDER BY audience_rating DESC LIMIT 5',
            variables: [
              Variable<String>(title),
              Variable<String>(title),
              if (year != null) ...[Variable<int>(year - 1), Variable<int>(year + 1)],
            ],
            readsFrom: {db.indexTitles},
          )
          .get();
      final match = rows.isEmpty ? null : db.indexTitles.map(rows.first.data);
      if (match == null) {
        missing.add(year == null ? title : '$title ($year)');
      } else {
        found.add(line(match));
      }
    }
    return [
      if (found.isNotEmpty) 'On the servers:\n${found.join('\n')}',
      if (missing.isNotEmpty) 'Not on the servers: ${missing.join('; ')}',
    ].join('\n\n');
  }

  Future<String> _getTitle(String id) async {
    final db = await index.database;
    final t = await (db.select(db.indexTitles)..where((r) => r.id.equals(id))).getSingleOrNull();
    if (t == null) return 'No title with id $id.';
    final copies = await index.copiesOf(t.groupKey);
    return [
      line(t),
      if (t.originalTitle != null) 'Original title: ${t.originalTitle}',
      if (t.summary != null) 'Summary: ${t.summary}',
      if (t.cast.isNotEmpty) 'Cast: ${t.cast.replaceAll('|', ', ')}',
      if (t.directors.isNotEmpty) 'Director: ${t.directors.replaceAll('|', ', ')}',
      if (t.countries.isNotEmpty) 'Country: ${t.countries.replaceAll('|', ', ')}',
      if (t.collections.isNotEmpty) 'Collections: ${t.collections.replaceAll('|', ', ')}',
      if (t.criticRating != null) 'Critic rating: ${t.criticRating!.toStringAsFixed(1)}',
      if (t.contentRating != null) 'Age rating: ${t.contentRating}',
      'Copies: ${copies.map((c) => '${c.serverName} · ${c.libraryTitle}').join('; ')}',
    ].join('\n');
  }

  Future<List<IndexedTitle>> _history(int limit) async {
    final db = await index.database;
    final rows = await db
        .customSelect(
          'SELECT * FROM index_titles WHERE last_viewed_at IS NOT NULL ORDER BY last_viewed_at DESC LIMIT ?',
          variables: [Variable<int>(limit * 3)],
          readsFrom: {db.indexTitles},
        )
        .get();
    final seen = <String>{};
    return [
      for (final r in rows)
        if (db.indexTitles.map(r.data) case final t when seen.add(t.groupKey)) t,
    ].take(limit).toList();
  }

  Future<List<IndexedTitle>> _continueWatching() async {
    final db = await index.database;
    final rows = await db
        .customSelect(
          "SELECT * FROM index_titles WHERE (type = 'movie' AND view_offset_ms > 0) OR "
          "(type = 'show' AND watched_episode_count > 0 AND watched_episode_count < episode_count) "
          'ORDER BY last_viewed_at DESC LIMIT 60',
          readsFrom: {db.indexTitles},
        )
        .get();
    final seen = <String>{};
    return [
      for (final r in rows)
        if (db.indexTitles.map(r.data) case final t when seen.add(t.groupKey)) t,
    ].take(25).toList();
  }

  Future<String> _ratings(List<String> ids) async {
    final client = trakt;
    if (client == null) return 'Trakt isn\'t connected; ratings unavailable.';
    final db = await index.database;
    final out = <String>[];
    for (final id in ids) {
      final t = await (db.select(db.indexTitles)..where((r) => r.id.equals(id))).getSingleOrNull();
      if (t == null) continue;
      final traktId = t.imdb;
      if (traktId == null) {
        out.add('${t.title}: no IMDb id, rating unavailable');
        continue;
      }
      try {
        final r = await client.getCommunityRating(
          t.type == 'show' ? TraktCatalogType.shows : TraktCatalogType.movies,
          traktId,
        );
        out.add(
          r?.rating == null
              ? '${t.title}: no Trakt rating'
              : '${t.title}: Trakt ${r!.rating!.toStringAsFixed(1)} from ${r.votes ?? 0} votes',
        );
      } catch (e) {
        appLogger.d('AI: Trakt rating failed for ${t.title}', error: e);
        out.add('${t.title}: rating lookup failed');
      }
      // Gentle on Trakt: a short gap between lookups.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return out.isEmpty ? 'No ratings.' : out.join('\n');
  }

  /// Picks as JSON, for logs and the eval report.
  String picksJson() => jsonEncode({
    'intro': intro,
    'picks': [
      for (final p in picks) {'id': p.id, 'reason': p.reason},
    ],
  });
}
