import 'package:plezy_brain/plezy_brain.dart';

import '../brain/history_brain.dart';
import '../brain/history_profiles.dart';
import '../library_index/index_search.dart';
import '../library_index/library_index.dart';

/// Fork: the AI helper's tools over the history brain: what the user
/// watched, when, how much, how far they got, and what's like it. Answers
/// come from the brain's profiles (merged Plex + Trakt history), so counts
/// are exact rather than the model's guess.
class AiHistoryTools {
  AiHistoryTools({required this.brain, required this.index, this.fixedNow});

  final HistoryBrain brain;
  final LibraryIndex index;

  /// Tests: a fixed "today".
  final DateTime? fixedNow;
  DateTime get now => fixedNow ?? DateTime.now();

  static const String queryTool = 'history_query';
  static const String statsTool = 'history_stats';
  static const String similarTool = 'similar_titles';
  static const Set<String> names = {queryTool, statsTool, similarTool};

  static const Map<String, Object?> _filters = {
    'type': {
      'type': 'string',
      'enum': ['movie', 'show'],
    },
    'watched_from': {'type': 'string', 'description': 'YYYY-MM-DD: a real watch on or after this day'},
    'watched_to': {'type': 'string', 'description': 'YYYY-MM-DD: a real watch before this day'},
    'genres_any': {
      'type': 'array',
      'items': {'type': 'string'},
    },
    'genres_all': {
      'type': 'array',
      'items': {'type': 'string'},
    },
    'person': {'type': 'string', 'description': 'Actor or director name (substring)'},
    'collection': {'type': 'string', 'description': 'Library collection name (substring); few titles have one'},
    'studio': {
      'type': 'string',
      'description': 'Production studio (substring), e.g. "Marvel Studios" for the MCU, "Pixar", "Studio Ghibli"',
    },
    'title_contains': {'type': 'string'},
    'rewatched': {'type': 'boolean', 'description': 'A film seen more than once, or a show with episodes rewatched'},
    'progress': {
      'type': 'array',
      'description':
          'Shows only. finished = caught up on every episode so far (it may still be airing); in_progress = not caught '
          'up, watched in the last 60 days; paused = not caught up, last watched 2-6 months ago; dropped = not caught '
          'up, untouched for 6+ months after at least 3 episodes or 10%; sampled = an episode or two, long ago; '
          'unknown = episode count unknown',
      'items': {
        'type': 'string',
        'enum': ['in_progress', 'paused', 'dropped', 'sampled', 'finished', 'unknown'],
      },
    },
    'min_my_rating': {'type': 'integer', 'description': "The user's own Trakt rating, 1-10"},
    'comfort': {'type': 'boolean', 'description': "On the user's Comfort list (shows they rewatch for comfort)"},
    'watchlist': {'type': 'boolean'},
    'on_servers': {'type': 'boolean', 'description': "Available on the user's Plex servers now"},
  };

  List<Map<String, Object?>> definitions() => [
    {
      'name': queryTool,
      'description':
          "Search the user's full watch history (Plex and Trakt merged; one entry per film or show) with filters. "
          'Use for "what was that film I watched...", "which shows did I drop", "films I rewatched", "what did I '
          'watch last summer". `about` ranks the matches by meaning (plot, mood, theme: "heist", "time loop", '
          '"cosy mystery") and is the way to find a half-remembered title. Each line has the title\'s id (use it '
          'in answer_question or show_picks; "not on servers" titles have no id to show), its watch dates, plays, '
          'progress and the user\'s rating. Dates are real viewing dates; imported or marked-as-watched plays are '
          'counted as "undated".',
      'input_schema': {
        'type': 'object',
        'properties': {
          ..._filters,
          'about': {'type': 'string', 'description': 'Rank by similarity to this description'},
          'sort': {
            'type': 'string',
            'enum': ['last_watched', 'first_watched', 'plays', 'my_rating', 'year', 'title'],
          },
          'limit': {'type': 'integer', 'description': 'Max 50, default 20'},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': statsTool,
      'description':
          'Exact counts over the watch history, grouped: titles, watches (plays; episodes for shows) and hours per '
          'group, plus the total. Takes the same filters as history_query; with a date range only watches inside '
          'it count. Use for "how many", "how much", "what did I watch most", "my top genres in 2024".',
      'input_schema': {
        'type': 'object',
        'properties': {
          ..._filters,
          'group_by': {
            'type': 'string',
            'enum': [
              'year',
              'month',
              'genre',
              'type',
              'decade',
              'director',
              'actor',
              'collection',
              'progress',
              'title',
            ],
          },
          'limit': {'type': 'integer', 'description': 'Max 50 groups, default 20'},
        },
        'required': ['group_by'],
        'additionalProperties': false,
      },
    },
    {
      'name': similarTool,
      'description':
          'Titles most similar in content to one title (by id from any tool, or by exact title), from the user\'s '
          'servers. `watched`: false for unwatched only (recommendations), true for things they have seen.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'title': {'type': 'string'},
          'watched': {'type': 'boolean'},
          'type': {
            'type': 'string',
            'enum': ['movie', 'show'],
          },
          'limit': {'type': 'integer', 'description': 'Max 30, default 15'},
        },
        'additionalProperties': false,
      },
    },
  ];

  Future<String> run(String name, Map<String, dynamic> input) async {
    final profiles = await brain.watchedProfiles();
    if (profiles.isEmpty && name != similarTool) return 'The watch history isn\'t indexed yet on this device.';
    switch (name) {
      case queryTool:
        return _query(profiles, input);
      case statsTool:
        return _stats(profiles, input);
      case similarTool:
        return _similar(input);
    }
    throw ArgumentError('Unknown tool $name');
  }

  HistoryQuery _filter(Map<String, dynamic> i, {int limit = 20, HistorySort sort = HistorySort.lastWatched}) {
    List<String> strings(String key) => [...(i[key] as List? ?? const []).whereType<String>()];
    DateTime? day(String key) => DateTime.tryParse('${i[key] ?? ''}');
    return HistoryQuery(
      kind: switch (i['type']) {
        'movie' => TitleKind.movie,
        'show' => TitleKind.show,
        _ => null,
      },
      watchedFrom: day('watched_from'),
      watchedTo: day('watched_to'),
      genresAny: strings('genres_any'),
      genresAll: strings('genres_all'),
      person: i['person'] as String?,
      collection: i['collection'] as String?,
      studio: i['studio'] as String?,
      titleContains: i['title_contains'] as String?,
      rewatched: i['rewatched'] as bool?,
      progress: {
        for (final p in strings('progress'))
          switch (p) {
            'in_progress' => ShowProgress.inProgress,
            'paused' => ShowProgress.paused,
            'dropped' => ShowProgress.dropped,
            'sampled' => ShowProgress.sampled,
            'finished' => ShowProgress.finished,
            _ => ShowProgress.unknown,
          },
      },
      minMyRating: (i['min_my_rating'] as num?)?.toInt(),
      comfort: i['comfort'] as bool?,
      watchlist: i['watchlist'] as bool?,
      inLibrary: i['on_servers'] as bool?,
      sort: sort,
      limit: limit,
    );
  }

  static int _limit(Object? v, int fallback, int max) => ((v as num?)?.toInt() ?? fallback).clamp(1, max);

  Future<String> _query(List<TitleProfile> profiles, Map<String, dynamic> input) async {
    final limit = _limit(input['limit'], 20, 50);
    final sort = switch (input['sort']) {
      'first_watched' => HistorySort.firstWatched,
      'plays' => HistorySort.plays,
      'my_rating' => HistorySort.myRating,
      'year' => HistorySort.year,
      'title' => HistorySort.title,
      _ => HistorySort.lastWatched,
    };
    final query = _filter(input, limit: 1 << 20, sort: sort);
    var matches = query.run(profiles, now: now);
    final total = matches.length;
    final about = (input['about'] as String?)?.trim();
    if (about != null && about.isNotEmpty && matches.isNotEmpty) {
      // Similarity is a rough first cut: send more candidates, each with its
      // plot, and let the model judge which really fit.
      final ranked = await brain.searchText(
        about,
        limit: limit < 30 ? 30 : limit,
        watched: true,
        ids: {for (final p in matches) p.id},
      );
      matches = [for (final h in ranked) h.profile];
    }
    if (matches.isEmpty) return 'No watched titles match.';
    final ranked = about != null && about.isNotEmpty;
    final shown = matches.take(ranked && limit < 30 ? 30 : limit).toList();
    return [
      ranked
          ? '$total watched titles match the filters; the ${shown.length} closest to "$about" follow, roughly ranked. '
                'Check each plot: similarity is approximate, keep only those that truly fit.'
          : '$total watched titles match${shown.length < total ? ' (showing ${shown.length})' : ''}.',
      for (final p in shown) describe(p, query, withPlot: ranked),
    ].join('\n');
  }

  String _stats(List<TitleProfile> profiles, Map<String, dynamic> input) {
    final query = _filter(input);
    final limit = _limit(input['limit'], 20, 50);
    final groupBy = input['group_by'] as String?;
    final matching = [
      for (final p in profiles)
        if (query.matches(p, now)) p,
    ];
    if (matching.isEmpty) return 'No watched titles match.';
    int playsOf(TitleProfile p) => query.watchesIn(p).length + (query.hasDateRange ? 0 : p.bulkPlays);
    int hours(int minutes) => (minutes / 60).round();
    var totalPlays = 0, totalMinutes = 0;
    for (final p in matching) {
      final n = playsOf(p);
      totalPlays += n;
      totalMinutes += n * (p.runtimeMinutes ?? (p.isMovie ? fallbackMovieMinutes : fallbackEpisodeMinutes));
    }
    final films = matching.where((p) => p.isMovie).length;
    final lines = <String>[
      'Total: ${matching.length} titles ($films films, ${matching.length - films} shows), $totalPlays watches '
          '(episodes count one each), about ${hours(totalMinutes)} hours.',
    ];
    if (groupBy == 'title') {
      final top = [...matching]..sort((a, b) => playsOf(b).compareTo(playsOf(a)));
      for (final p in top.take(limit)) {
        lines.add('${_cardId(p) ?? 'not on servers'} | ${_name(p)} | ${playsOf(p)} watches');
      }
      return lines.join('\n');
    }
    final group = switch (groupBy) {
      'month' => HistoryGroup.month,
      'genre' => HistoryGroup.genre,
      'type' => HistoryGroup.kind,
      'decade' => HistoryGroup.decade,
      'director' => HistoryGroup.director,
      'actor' => HistoryGroup.actor,
      'collection' => HistoryGroup.collection,
      'studio' => HistoryGroup.studio,
      'progress' => HistoryGroup.progress,
      _ => HistoryGroup.year,
    };
    for (final r in historyStats(matching, query, group, now: now, limit: limit)) {
      lines.add('${r.group}: ${r.titles} titles, ${r.plays} watches, ${hours(r.minutes)} h');
    }
    return lines.join('\n');
  }

  Future<String> _similar(Map<String, dynamic> input) async {
    final id = await _resolve(input['id'] as String?, input['title'] as String?);
    if (id == null) return 'No such title in the index.';
    final hits = await brain.similar(
      id,
      limit: _limit(input['limit'], 15, 30) * 2,
      watched: input['watched'] as bool?,
      kind: switch (input['type']) {
        'movie' => TitleKind.movie,
        'show' => TitleKind.show,
        _ => null,
      },
    );
    final onServers = [
      for (final h in hits)
        if (h.profile.inLibrary) h.profile,
    ].take(_limit(input['limit'], 15, 30));
    if (onServers.isEmpty) return 'Nothing similar found (the index may still be building).';
    return onServers.map((p) => describe(p, const HistoryQuery(), withPlot: true)).join('\n');
  }

  /// A brain id from a brain id, an index id (`server:ratingKey`) or a title.
  Future<String?> _resolve(String? id, String? title) async {
    final store = await brain.store;
    if (id != null && store.profile(id) != null) return id;
    final db = await index.database;
    if (id != null) {
      final row = await (db.select(db.indexTitles)..where((r) => r.id.equals(id))).getSingleOrNull();
      if (row != null) {
        final copies = await index.copiesOf(row.groupKey);
        for (final c in [row, ...copies]) {
          final candidate = LibraryRef.of(c).titleId;
          if (store.profile(candidate) != null) return candidate;
        }
      }
    }
    if (title != null && title.trim().isNotEmpty) {
      final want = title.trim().toLowerCase();
      return store.profiles().where((p) => p.title.toLowerCase() == want).firstOrNull?.id;
    }
    return null;
  }

  /// The id cards and show_picks use: the title's library copy.
  static String? _cardId(TitleProfile p) =>
      p.inLibrary && p.serverId != null && p.ratingKey != null ? '${p.serverId}:${p.ratingKey}' : null;

  static String _name(TitleProfile p) => '${p.title}${p.year == null ? '' : ' (${p.year})'}';

  static String _day(DateTime d) => d.toLocal().toIso8601String().substring(0, 10);

  /// One compact line per title.
  String describe(TitleProfile p, HistoryQuery query, {bool withPlot = false}) {
    final inRange = query.hasDateRange ? query.watchesIn(p) : p.watches;
    final parts = <String>[
      _cardId(p) ?? 'not on servers',
      _name(p),
      p.isMovie ? 'film' : 'show',
      if (p.genres.isNotEmpty) p.genres.take(4).join(', '),
      if (p.watched) ...[
        if (p.isMovie)
          '${p.plays} ${p.plays == 1 ? 'watch' : 'watches'}'
        else
          '${p.episodesWatched}${p.episodeCount == null ? '' : '/${p.episodeCount}'} episodes '
              '(${p.progress(now).name})',
        if (inRange.isNotEmpty)
          inRange.length == 1
              ? 'watched ${_day(inRange.single)}'
              : 'watched ${_day(inRange.first)} to ${_day(inRange.last)}',
        if (query.hasDateRange && inRange.length != p.watches.length) '${inRange.length} in range',
        if (p.bulkPlays > 0) '${p.bulkPlays} undated',
        if (p.rewatched) 'rewatched',
      ] else
        'unwatched',
      if (p.myRating != null) 'rated ${p.myRating}/10',
      if (p.comfort) 'comfort',
      if (p.watchlist) 'on watchlist',
      if (p.collections.isNotEmpty) p.collections.take(2).join(', '),
      if (p.studio != null) p.studio!,
      if (withPlot && p.summary != null) _firstSentence(p.summary!),
    ];
    return parts.join(' | ');
  }

  /// A plot's opening, short enough for a list.
  static String _firstSentence(String text) {
    final cut = text.indexOf(RegExp(r'[.!?](\s|$)'));
    final s = cut > 0 && cut < 220 ? text.substring(0, cut + 1) : text;
    return s.length > 220 ? '${s.substring(0, 217)}...' : s;
  }
}
