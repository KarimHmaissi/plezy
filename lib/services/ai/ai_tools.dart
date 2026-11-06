import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../../utils/app_logger.dart';
import '../library_index/index_database.dart';
import '../library_index/index_search.dart';
import '../library_index/library_index.dart';
import '../trackers/trakt/trakt_client.dart';
import '../trackers/trakt/trakt_constants.dart';
import 'ai_history_tools.dart';
import 'ai_watch_state.dart';

/// One pick the model chose for the user: an index title id and why.
typedef AiPick = ({String id, String reason});

/// The tools the AI helper can call, backed by the library index (and Trakt
/// ratings for a shortlist). All read-only except [showPicksTool], which is
/// how the model hands back its final picks.
class AiTools {
  AiTools({required this.index, this.trakt, this.history, WatchStates? watch}) : watch = watch ?? WatchStates.none;

  final LibraryIndex index;
  final TraktClient? trakt;

  /// Fork: what the user has seen (the history brain merged in), for this
  /// ask only.
  final WatchStates watch;

  /// Fork: tools over the history brain, on hosts that have one.
  final AiHistoryTools? history;

  /// Picks from the last `show_picks` call, its intro line and row name.
  List<AiPick> picks = const [];
  String? intro;
  String? title;

  /// Fork: the written answer from `answer_question`.
  String? answer;

  /// Fork: the write-up, notes and follow-up refinements of the final call.
  String? writeup;
  List<String> notes = const [];
  List<String> followUps = const [];

  /// Fork: the answer's gist in a few words, for its folded state.
  String? headline;

  /// Fork: picks worth a closer look (title-specific insight), and the
  /// strongest matches, by pick id.
  List<({String id, String text})> spotlights = const [];
  List<({String id, String text})> topPicks = const [];

  /// Fork: how big the request is ('narrow', 'broad' or 'list'), and every
  /// title id the lookups returned, in order, with the tool that returned
  /// it: a short broad row is topped up from [topUpTools]' ones without
  /// another turn. Only for this answer; never saved.
  String? scope;
  final Set<String> _seenCandidates = {};

  /// Fork: the lookups a top-up may draw from: the model's own candidates
  /// and its structured searches. Surface matches (text_search,
  /// similar_titles) and history lookups never fill a row.
  static const Set<String> topUpTools = {'find_titles', 'search_library'};

  static final RegExp _lineId = RegExp(r'^([^\s|]+:[^\s|]+) \|', multiLine: true);

  /// A result line's id and the title after it ("id | Title (2018) | ..."),
  /// year left off.
  static final RegExp _lineTitle = RegExp(r'^([^\s|]+:[^\s|]+) \| ([^|\n]+?)(?: \(\d{4}\))? \|', multiLine: true);

  /// Titles the history tools named, by id, for answers that name titles in
  /// their text but leave out the cards ([cardsNamedIn]).
  final Map<String, String> _historyTitles = {};

  /// Remember the ids in a lookup's [result] lines. The model's own
  /// candidates (find_titles) rank first, then titles like ones they loved,
  /// then keyword searches.
  void noteCandidates(String tool, String result) {
    final rank = switch (tool) {
      'find_titles' => 0,
      'similar_titles' => 1,
      _ => 2,
    };
    for (final m in _lineId.allMatches(result)) {
      final id = m.group(1)!;
      if (_seenCandidates.add('$tool $id')) _ranked.add((id: id, tool: tool, rank: rank, order: _ranked.length));
    }
  }

  final List<({String id, String tool, int rank, int order})> _ranked = [];

  /// [noteCandidates]' ids from [topUpTools], best source first.
  List<String> get topUpCandidates => {
    for (final c in [..._ranked]..sort((a, b) => a.rank != b.rank ? a.rank - b.rank : a.order - b.order))
      if (topUpTools.contains(c.tool)) c.id,
  }.toList();

  /// Remember the titles a history tool's [result] lists; returns it.
  String noteHistoryTitles(String result) {
    for (final m in _lineTitle.allMatches(result)) {
      _historyTitles.putIfAbsent(m.group(1)!, () => m.group(2)!.trim());
    }
    return result;
  }

  /// Cards for the titles the history tools returned that [text] names,
  /// in the order the text names them (at most 20).
  List<AiPick> cardsNamedIn(String text) {
    final lower = text.toLowerCase();
    // Longest titles first, so "Desk" inside "The Night Desk" isn't a
    // second title.
    final titles = _historyTitles.entries.toList()..sort((a, b) => b.value.length - a.value.length);
    final taken = <(int, int)>[];
    final found = <({String id, int at})>[];
    for (final MapEntry(key: id, value: title) in titles) {
      if (title.length < 2) continue;
      final pattern = RegExp('(?<![\\w])${RegExp.escape(title.toLowerCase())}(?![\\w])');
      for (final m in pattern.allMatches(lower)) {
        if (taken.any((t) => m.start < t.$2 && t.$1 < m.end)) continue;
        taken.add((m.start, m.end));
        found.add((id: id, at: m.start));
        break;
      }
    }
    found.sort((a, b) => a.at - b.at);
    return [for (final f in found.take(20)) (id: f.id, reason: '')];
  }

  void _readExtras(Map<String, dynamic> input) {
    List<String> strings(String key) => [
      for (final v in (input[key] as List? ?? const []))
        if ('$v'.trim().isNotEmpty) '$v'.trim(),
    ];
    notes = strings('notes').take(2).toList();
    followUps = strings('follow_ups').take(3).toList();
  }

  bool _askedHistory = false;

  static Map<String, Object?> _idText(String text) => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string', 'description': 'A pick id'},
      'text': {'type': 'string', 'description': text},
    },
    'required': ['id', 'text'],
    'additionalProperties': false,
  };

  static const String showPicksTool = 'show_picks';
  static const String answerTool = 'answer_question';

  /// Tools that end the answer.
  static const Set<String> finalTools = {showPicksTool, answerTool};

  /// Hard cap on one answer's picks; the prompt lets the model size the list.
  static const int maxPicks = 50;

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
            'maxItems': 60,
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
          'Trakt community rating and vote count for up to 20 shortlisted titles (by id), to judge new or '
          'surprisingly highly rated titles. Use only on a shortlist, never on long result lists.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'ids': {
            'type': 'array',
            'items': {'type': 'string'},
            'maxItems': 20,
          },
        },
        'required': ['ids'],
        'additionalProperties': false,
      },
    },
    ...?history?.definitions(),
    {
      'name': showPicksTool,
      'description':
          'Show your final picks to the user as a row of playable cards. Call exactly once, at the end, with ids '
          'returned by the other tools only (never invented). Best first; only the first 10 get a reason. Up to 50, sized to the request: 40-50 for list-style asks, about 30-40 for broad requests, only the true matches for narrow ones.',
      'strict': true,
      'input_schema': {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'A short name for this row of picks, 2-6 words'},
          'scope': {
            'type': 'string',
            'enum': ['narrow', 'broad', 'list'],
            'description':
                'narrow: a specific title, yes/no or tight constraints; broad: a genre, mood, era or "like X"; '
                'list: every/all of something',
          },
          'intro': {'type': 'string', 'description': 'One friendly sentence introducing the picks'},
          'headline': {
            'type': 'string',
            'description':
                'At most 12 words, punchy, no full stop: the gist of these picks, shown when the answer is folded '
                '(e.g. "Binge-friendly hits with big hooks")',
          },
          'writeup': {
            'type': 'string',
            'description':
                'The overview, written first: 3-4 full sentences (60-90 words), plain text, no markdown: what ties the '
                'picks together and how they fit this '
                "user's taste. Draw on their watching when it's relevant (\"you finished X, so...\"). Spoiler-free.",
          },
          'top_picks': {
            'type': 'array',
            'items': _idText('Why this is the strongest match for them, one sentence, not starting with the title'),
            'description': '1-2 picks you rate the strongest match, for recommendation requests; else empty',
          },
          'spotlights': {
            'type': 'array',
            'items': _idText(
              '1-2 spoiler-free sentences of insight about this title: what makes it stand out, its tone, pacing, '
              'where to start. Not the pick reason again, and don\'t start the sentence with the title',
            ),
            'description':
                '2-3 picks worth a closer look (not the top picks); empty for narrow requests with 1-2 picks',
          },
          'notes': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Up to 2 short spoiler-free "worth knowing" notes (pace, where to start, intensity), only if useful; '
                'else empty',
          },
          'follow_ups': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                '2-3 short refinements the user might tap next, phrased as their request, 2-5 words each '
                '("Only films", "Something lighter", "More like <a pick>")',
          },
          'picks': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'reason': {
                  'type': 'string',
                  'description':
                      'For the first 10 picks only: why this fits the request, under 15 words, specific to the '
                      'title (never a placeholder). An empty string for every pick after the 10th.',
                },
              },
              'required': ['id', 'reason'],
              'additionalProperties': false,
            },
          },
        },
        'required': [
          'title',
          'scope',
          'intro',
          'headline',
          'writeup',
          'top_picks',
          'spotlights',
          'notes',
          'follow_ups',
          'picks',
        ],
        'additionalProperties': false,
      },
    },
    if (history != null)
      {
        'name': answerTool,
        'description':
            'Answer a question about the user\'s own watching (what, when, how many, which) in writing, with the '
            'titles it mentions as cards. Call exactly once, at the end, instead of show_picks. Only state facts the '
            'history tools returned; if they don\'t settle it, say what you don\'t know.',
        'strict': true,
        'input_schema': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string', 'description': 'A short name for this answer, 2-6 words'},
            'answer': {
              'type': 'string',
              'description':
                  'Plain text, no markdown: a direct answer, up to a short paragraph (1-6 sentences), numbers exact. '
                  'Mention titles by name.',
            },
            'titles': {
              'type': 'array',
              'description':
                  'Ids (from the tools) of the titles the answer is about, most relevant first, up to 20: every '
                  'title a list answer names. For a ranking, keep its order and put the number in the note '
                  '("129 episodes"). Titles "not on servers" have no id; name them in the answer instead.',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string'},
                  'note': {'type': 'string', 'description': 'A few words: when watched, how far, why it fits'},
                },
                'required': ['id', 'note'],
                'additionalProperties': false,
              },
            },
            'notes': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Up to 2 short spoiler-free "worth knowing" notes (pace, where to start, intensity), only if useful; '
                  'else empty',
            },
            'follow_ups': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  '2-3 short refinements the user might tap next, phrased as their request, 2-5 words each '
                  '("Only films", "Something lighter", "More like <a pick>")',
            },
          },
          'required': ['title', 'answer', 'titles', 'notes', 'follow_ups'],
          'additionalProperties': false,
        },
      },
  ];

  /// Run one tool call; returns the text for its `tool_result`.
  Future<String> run(String name, Map<String, dynamic> input) async {
    switch (name) {
      case 'search_library':
        return _list(await index.search(_query(input), seen: watch.seen));
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
        return _ratings([...(input['ids'] as List? ?? const []).whereType<String>()].take(20).toList());
      case final n when history != null && AiHistoryTools.names.contains(n):
        if (n != AiHistoryTools.similarTool) _askedHistory = true;
        return noteHistoryTitles(await history!.run(n, input));
      case answerTool:
        title = input['title'] as String?;
        answer = (input['answer'] as String?)?.trim();
        _readExtras(input);
        picks = [
          for (final p in (input['titles'] as List? ?? const []).whereType<Map>().take(20))
            if (p['id'] is String) (id: p['id'] as String, reason: p['note'] as String? ?? ''),
        ];
        // An answer that lists titles always comes with their cards, even
        // when the model only wrote them into the text.
        if (picks.isEmpty && answer != null) picks = cardsNamedIn(answer!);
        return 'Shown to the user.';
      case showPicksTool:
        intro = input['intro'] as String?;
        writeup = (input['writeup'] as String?)?.trim();
        _readExtras(input);
        // A question about their history gets a written answer even when the
        // model reached for picks: the intro is that answer.
        if (_askedHistory) answer = writeup ?? intro;
        title = input['title'] as String?;
        List<({String id, String text})> idTexts(String key, int max) => [
          for (final p in (input[key] as List? ?? const []).whereType<Map>().take(max))
            if (p['id'] is String && '${p['text'] ?? ''}'.trim().isNotEmpty)
              (id: p['id'] as String, text: '${p['text']}'.trim()),
        ];
        scope = input['scope'] as String?;
        headline = (input['headline'] as String?)?.trim();
        topPicks = idTexts('top_picks', 2);
        spotlights = idTexts('spotlights', 3);
        final listed = [
          for (final p in (input['picks'] as List? ?? const []).whereType<Map>().take(maxPicks))
            if (p['id'] is String) (id: p['id'] as String, reason: p['reason'] as String? ?? ''),
        ];
        // Top picks lead the row (added if the model left them out of picks).
        final top = {for (final p in topPicks) p.id};
        picks = [
          for (final t in topPicks) listed.where((p) => p.id == t.id).firstOrNull ?? (id: t.id, reason: t.text),
          for (final p in listed)
            if (!top.contains(p.id)) p,
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

  /// One compact line per title, cheap in tokens. Fork: [watch] is what the
  /// user has seen of it (the brain merged in); the row's own counts if not
  /// given.
  static String line(IndexedTitle t, {bool withWatched = false, WatchState? watch}) {
    final parts = <String>[
      t.id,
      '${t.title}${t.year == null ? '' : ' (${t.year})'}',
      t.type,
      if (t.genres.isNotEmpty) t.genres.replaceAll('|', ', '),
      if (t.audienceRating != null)
        t.audienceRating! >= 9.95 ? '★10.0 (likely few votes)' : '★${t.audienceRating!.toStringAsFixed(1)}',
      if (t.type == 'movie' && t.durationMinutes != null) '${t.durationMinutes} min',
      if (t.type == 'show' && t.episodeCount != null) '${t.episodeCount} eps',
      if (t.releaseDate != null && t.type == 'show') 'first aired ${t.releaseDate}',
      (watch ?? WatchState.of(t)).label,
      t.libraryTitle,
    ];
    return parts.where((p) => p.isNotEmpty).join(' | ');
  }

  String _list(List<IndexedTitle> titles, {bool withWatched = false}) => titles.isEmpty
      ? 'No matches.'
      : titles.map((t) => line(t, withWatched: withWatched, watch: watch.of(t))).join('\n');

  Future<String> _findTitles(Map<String, dynamic> input) async {
    final db = await index.database;
    final wanted = [
      for (final t in (input['titles'] as List? ?? const []).whereType<Map>().take(60))
        if ((t['title'] as String? ?? '').trim() case final title when title.isNotEmpty)
          (title: title, year: (t['year'] as num?)?.toInt()),
    ];
    if (wanted.isEmpty) return 'No titles given.';
    // One pass over the table for every title (one query each was a full
    // scan apiece: seconds for a long list).
    final names = {for (final w in wanted) w.title.toLowerCase()}.toList();
    final marks = List.filled(names.length, '?').join(',');
    final rows = await db
        .customSelect(
          'SELECT * FROM index_titles WHERE lower(title) IN ($marks) OR lower(original_title) IN ($marks) '
          'ORDER BY audience_rating DESC',
          variables: [
            for (final n in [...names, ...names]) Variable<String>(n),
          ],
          readsFrom: {db.indexTitles},
        )
        .get();
    final titles = [for (final r in rows) db.indexTitles.map(r.data)];
    final found = <String>[];
    final missing = <String>[];
    for (final w in wanted) {
      final name = w.title.toLowerCase();
      final year = w.year;
      final match = titles
          .where(
            (t) =>
                (t.title.toLowerCase() == name || t.originalTitle?.toLowerCase() == name) &&
                (year == null || (t.year != null && (t.year! - year).abs() <= 1)),
          )
          .firstOrNull;
      if (match == null) {
        missing.add(year == null ? w.title : '${w.title} ($year)');
      } else {
        found.add(line(match, watch: watch.of(match)));
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
      line(t, watch: watch.of(t)),
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
    'title': title,
    'intro': intro,
    'picks': [
      for (final p in picks) {'id': p.id, 'reason': p.reason},
    ],
  });
}
