import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../media/ids.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../brain/history_brain.dart';
import '../customisation/customisation_store.dart';
import '../library_index/index_database.dart';
import '../library_index/index_search.dart';
import '../library_index/library_index.dart';
import 'ai_history.dart';
import 'ai_key_store.dart';
import 'ai_rows.dart' show pickFetchTimeout;
import 'ai_spend.dart';
import 'claude_client.dart';

/// One list the AI suggests: what it's called, the request it stands for
/// (what "Keep" saves), how to fill it from the library, and its picks.
class AiSuggestion {
  AiSuggestion({required this.spec, required this.entry});

  /// The model's idea: `title`, `request`, `why` and the `search` that
  /// fills it (see [AiSuggestions.fill]). Kept so the picks can be topped up
  /// without asking the model again.
  final Map<String, Object?> spec;
  final AiHistoryEntry entry;

  String get title => spec['title'] as String? ?? entry.label;

  Map<String, Object?> toJson() => {'spec': spec, 'entry': entry.toJson()};

  static AiSuggestion? fromJson(Object? json) {
    if (json is! Map) return null;
    final entry = AiHistoryEntry.fromJson(json['entry']);
    final spec = json['spec'];
    if (entry == null || spec is! Map) return null;
    return AiSuggestion(spec: spec.cast<String, Object?>(), entry: entry);
  }
}

/// Fork: "Suggested for you" on the AI page: up to [maxLists] ready-made
/// lists the AI thinks of from the user's watching, so they don't have to
/// ask. Haiku names the lists and says how to fill each one (genres, years,
/// a theme, "like a title they loved"); the app fills them from the library
/// index and the history brain, unwatched titles only, so a tap opens a
/// list at once and topping it up costs nothing.
///
/// A new set comes once a day (or on "New lists"); the picks inside are
/// topped up every [topUpEvery]. "Keep" moves a list into the saved
/// answers; "Not for me" hides it, and the next sets steer away from the
/// themes hidden lately.
abstract final class AiSuggestions {
  static const String settingKey = 'ai.suggestions';
  static const String dismissedKey = 'ai.suggestions.dismissed';
  static const int maxLists = 6;
  static const int minPicks = 6;
  static const int maxPicks = 20;
  static const Duration newSetEvery = Duration(days: 1);
  static const Duration topUpEvery = Duration(hours: 12);

  /// Bumped when the shelf changed (a new set, a top-up, keep or hide).
  static final ValueNotifier<int> changed = ValueNotifier(0);

  static Future<({DateTime? createdAt, List<AiSuggestion> lists})>? _running;

  /// The saved shelf, whatever its age.
  static Future<({DateTime? createdAt, List<AiSuggestion> lists})> cached() async {
    final raw = await (await Customisation.store).readSetting(settingKey);
    if (raw == null) return (createdAt: null, lists: const <AiSuggestion>[]);
    try {
      final json = jsonDecode(raw) as Map;
      return (
        createdAt: json['createdAt'] is int ? DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int) : null,
        lists: [for (final l in (json['lists'] as List? ?? const [])) ?AiSuggestion.fromJson(l)],
      );
    } catch (e) {
      appLogger.w('AI suggestions: saved shelf unreadable', error: e);
      return (createdAt: null, lists: const <AiSuggestion>[]);
    }
  }

  static Future<void> _save(DateTime? createdAt, List<AiSuggestion> lists) async {
    await (await Customisation.store).writeSetting(
      settingKey,
      jsonEncode({
        'createdAt': createdAt?.millisecondsSinceEpoch,
        'lists': [for (final l in lists) l.toJson()],
      }),
    );
    changed.value++;
  }

  /// Today's shelf: a new set when there's none, it's a day old or [force]
  /// ("New lists"); else the saved one, its picks topped up when due.
  static Future<({DateTime? createdAt, List<AiSuggestion> lists})> today({
    required MediaServerClient? Function(ServerId serverId) clientFor,
    bool force = false,
  }) {
    return _running ??= () async {
      try {
        final saved = await cached();
        final at = saved.createdAt;
        final due = at == null || DateTime.now().difference(at) >= newSetEvery;
        if (force || due || saved.lists.isEmpty) {
          final fresh = await _make(clientFor, avoid: [for (final l in saved.lists) l.title]);
          if (fresh.isNotEmpty) {
            final now = DateTime.now();
            await _save(now, fresh);
            return (createdAt: now, lists: fresh);
          }
          return saved;
        }
        return await _topUp(saved, clientFor);
      } finally {
        _running = null;
      }
    }();
  }

  /// "Keep": the list becomes a saved answer (a new id, so it stays when
  /// the shelf changes) and leaves the shelf.
  static Future<AiHistoryEntry> keep(AiSuggestion suggestion) async {
    final kept = suggestion.entry.copyWithId(AiHistory.newId());
    await AiHistory.add(kept);
    await _remove(suggestion);
    return kept;
  }

  /// "Not for me": off the shelf, and its theme avoided for a while.
  static Future<void> dismiss(AiSuggestion suggestion) async {
    final store = await Customisation.store;
    final dismissed = await _dismissed();
    await store.writeSetting(dismissedKey, jsonEncode([suggestion.title, ...dismissed].take(30).toList()));
    await _remove(suggestion);
  }

  static Future<void> _remove(AiSuggestion suggestion) async {
    final saved = await cached();
    await _save(saved.createdAt, [
      for (final l in saved.lists)
        if (l.entry.id != suggestion.entry.id) l,
    ]);
  }

  static Future<List<String>> _dismissed() async {
    final raw = await (await Customisation.store).readSetting(dismissedKey);
    if (raw == null) return const [];
    try {
      return [...(jsonDecode(raw) as List).whereType<String>()];
    } catch (_) {
      return const [];
    }
  }

  static Future<({DateTime? createdAt, List<AiSuggestion> lists})> _topUp(
    ({DateTime? createdAt, List<AiSuggestion> lists}) saved,
    MediaServerClient? Function(ServerId serverId) clientFor,
  ) async {
    final stale = saved.lists.any((l) => DateTime.now().difference(l.entry.createdAt) >= topUpEvery);
    if (!stale) return saved;
    final lists = <AiSuggestion>[];
    for (final l in saved.lists) {
      if (DateTime.now().difference(l.entry.createdAt) < topUpEvery) {
        lists.add(l);
        continue;
      }
      // Watched since: gone; new arrivals that fit: in.
      lists.add(await _build(l.spec, clientFor, id: l.entry.id) ?? l);
    }
    await _save(saved.createdAt, lists);
    return (createdAt: saved.createdAt, lists: lists);
  }

  /// A new set: Haiku's ideas, each filled from the library; ideas that
  /// find fewer than [minPicks] titles are dropped.
  static Future<List<AiSuggestion>> _make(
    MediaServerClient? Function(ServerId serverId) clientFor, {
    List<String> avoid = const [],
  }) async {
    final key = await AiKeyStore.read();
    final brain = HistoryBrain.instance;
    if (key == null || brain.status.value.profiles == 0) return const [];
    final client = ClaudeClient(key);
    try {
      final taste = await brain.taste();
      final dismissed = await _dismissed();
      final asked = [for (final e in await AiHistory.page(limit: 15)) e.label];
      final response = await client.createMessage({
        'model': ClaudeModel.haiku.id,
        'max_tokens': 2500,
        'thinking': {'type': 'disabled'},
        'system': _prompt,
        'tools': [_tool],
        'tool_choice': {'type': 'tool', 'name': _tool['name']},
        'messages': [
          {
            'role': 'user',
            'content': [
              'Their taste:\n$taste',
              if (asked.isNotEmpty) 'Lists they already have (do not repeat): ${asked.join('; ')}',
              if (avoid.isNotEmpty) 'Lists on the shelf now (make different ones): ${avoid.join('; ')}',
              if (dismissed.isNotEmpty) 'Themes they hid (steer away from these): ${dismissed.take(15).join('; ')}',
              'Today: ${DateTime.now().toIso8601String().substring(0, 10)}',
            ].join('\n\n'),
          },
        ],
      });
      final usage = (response['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cost = await AiSpend.record(ClaudeModel.haiku, usage);
      final input = [
        for (final b in (response['content'] as List? ?? const []).whereType<Map>())
          if (b['type'] == 'tool_use') (b['input'] as Map).cast<String, dynamic>(),
      ].firstOrNull;
      final ideas = [...(input?['lists'] as List? ?? const []).whereType<Map>()];
      final lists = <AiSuggestion>[];
      for (final idea in ideas) {
        if (lists.length >= maxLists) break;
        final built = await _build(idea.cast<String, Object?>(), clientFor);
        if (built != null) lists.add(built);
      }
      appLogger.i('AI suggestions: ${lists.length} of ${ideas.length} lists filled, \$${cost.toStringAsFixed(4)}');
      return lists;
    } catch (e) {
      appLogger.w('AI suggestions failed', error: e);
      return const [];
    } finally {
      client.close();
    }
  }

  /// Fill one list from [spec] (null when too few titles fit).
  static Future<AiSuggestion?> _build(
    Map<String, Object?> spec,
    MediaServerClient? Function(ServerId serverId) clientFor, {
    String? id,
  }) async {
    final title = (spec['title'] as String?)?.trim();
    final request = (spec['request'] as String?)?.trim();
    if (title == null || title.isEmpty || request == null || request.isEmpty) return null;
    final search = (spec['search'] as Map?)?.cast<String, Object?>() ?? const {};
    final titles = await fill(LibraryIndex.instance, HistoryBrain.instance, search);
    if (titles.length < minPicks) return null;
    final items = (await Future.wait([
      for (final t in titles.take(maxPicks))
        () async {
          try {
            return await clientFor(ServerId(t.serverId))?.fetchItem(t.ratingKey).timeout(pickFetchTimeout);
          } catch (_) {
            return null;
          }
        }(),
    ])).nonNulls.toList();
    if (items.length < minPicks) return null;
    final why = (spec['why'] as String?)?.trim();
    return AiSuggestion(
      spec: spec,
      entry: AiHistoryEntry(
        id: id ?? 'suggested-${AiHistory.newId()}',
        request: request,
        title: title,
        // Said once, as the page's headline.
        intro: null,
        headline: why,
        createdAt: DateTime.now(),
        items: items,
        reasons: const {},
      ),
    );
  }

  /// The library titles [search] describes, unwatched, best first, one per
  /// film or show: the structured filters, narrowed (or, alone, found) by
  /// `text`, and titles like `like` (a title they watched) first.
  @visibleForTesting
  static Future<List<IndexedTitle>> fill(LibraryIndex index, HistoryBrain? brain, Map<String, Object?> search) async {
    List<String> strings(String key) => [...(search[key] as List? ?? const []).whereType<String>()];
    final type = switch (search['type']) {
      final String t when t == 'movie' || t == 'show' => t,
      _ => null,
    };
    final structured =
        strings('genres_all').isNotEmpty ||
        search['year_from'] != null ||
        search['year_to'] != null ||
        search['min_rating'] != null ||
        search['max_minutes'] != null ||
        search['person'] != null ||
        search['country'] != null ||
        search['library'] != null;
    final filtered = structured || search['text'] == null
        ? await index.search(
            IndexQuery(
              type: type,
              genresAll: strings('genres_all'),
              genresNone: strings('genres_none'),
              yearFrom: (search['year_from'] as num?)?.toInt(),
              yearTo: (search['year_to'] as num?)?.toInt(),
              minRating: (search['min_rating'] as num?)?.toDouble(),
              maxMinutes: (search['max_minutes'] as num?)?.toInt(),
              person: search['person'] as String?,
              country: search['country'] as String?,
              library: search['library'] as String?,
              watch: IndexWatchFilter.unwatched,
              limit: 120,
            ),
          )
        : null;
    final text = (search['text'] as String?)?.trim();
    final themed = text == null || text.isEmpty ? null : await index.textSearch(text, type: type, limit: 120);

    var titles = switch ((filtered, themed)) {
      (final f?, final t?) => [
        for (final x in t)
          if (f.any((y) => y.groupKey == x.groupKey)) x,
      ],
      (final f?, null) => f,
      (null, final t?) => t,
      _ => const <IndexedTitle>[],
    };
    // Titles like one they loved lead the list, when the brain knows them.
    final like = (search['like'] as String?)?.trim();
    String? seed;
    final none = {for (final g in strings('genres_none')) g.toLowerCase()};
    if (brain != null && like != null && like.isNotEmpty) {
      try {
        final store = await brain.store;
        seed = store.idsByTitle(like).firstOrNull;
        // "Like" a live-action title keeps animation out: a list like Dune
        // shouldn't fill with animated films that share its genres.
        final seedGenres = seed == null ? null : store.profile(seed)?.genres;
        if (seedGenres != null && !seedGenres.any((g) => g.toLowerCase() == 'animation')) none.add('animation');
      } catch (e) {
        appLogger.d('AI suggestions: brain unavailable', error: e);
      }
    }
    bool excluded(IndexedTitle t) => t.genres.toLowerCase().split('|').any(none.contains);
    titles = [
      for (final t in titles)
        if ((t.viewCount ?? 0) == 0 && (t.watchedEpisodeCount ?? 0) == 0 && !excluded(t)) t,
    ];

    if (brain != null && seed != null && titles.isNotEmpty) {
      try {
        final near = await brain.similar(seed, limit: 60, watched: false);
        final rank = <String, int>{
          for (final (i, h) in near.indexed)
            if (h.profile.serverId != null && h.profile.ratingKey != null)
              '${h.profile.serverId}:${h.profile.ratingKey}': i,
        };
        int score(IndexedTitle t) => rank[t.id] ?? 1000;
        titles = [...titles]..sort((a, b) => score(a).compareTo(score(b)));
      } catch (e) {
        appLogger.d('AI suggestions: similarity unavailable', error: e);
      }
    }
    return titles;
  }

  static const String _prompt = '''
You suggest ready-made lists for a TV app's AI page, so the user finds something without asking. From their taste, think of 8 varied lists they would enjoy browsing tonight: specific and inviting ("90s heist films", "Short anime to finish this week", "Slow-burn British crime"), never generic ("Action movies", "Top rated"). Mix films and shows, moods, eras and one or two that stretch their taste a little. The app fills each list from their own library with the search you give, unwatched titles only, so keep searches broad enough to find 10+ titles: usually 1-2 genres plus a year range or a theme word, not every filter at once.
- title: 2-5 words, the shelf name. Plain, no emoji.
- request: the same list as the user would ask for it, one sentence.
- why: one short line on why it suits them, naming a title they love when it fits. Address them as "you".
- search: genres use the library's names (Action, Adventure, Animation, Comedy, Crime, Documentary, Drama, Family, Fantasy, History, Horror, Music, Mystery, Romance, Science Fiction, Thriller, War, Western). genres_none keeps out what would spoil the list: kids' and animated titles carry most genres too, so put Animation and Family in genres_none unless the list is meant for them (anime, animated, family night). text = 1-3 plot or theme words matched in titles and summaries ("heist", "time loop"). like = the exact title of something they watched and loved, to rank by similarity.''';

  static const Map<String, Object?> _tool = {
    'name': 'suggest_lists',
    'description': 'The suggested lists, best first.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'lists': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'request': {'type': 'string'},
              'why': {'type': 'string'},
              'search': {
                'type': 'object',
                'properties': {
                  'type': {
                    'type': 'string',
                    'enum': ['movie', 'show'],
                  },
                  'genres_all': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                  'genres_none': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                  'year_from': {'type': 'integer'},
                  'year_to': {'type': 'integer'},
                  'min_rating': {'type': 'number', 'description': 'Audience rating 0-10'},
                  'max_minutes': {'type': 'integer', 'description': 'Film runtime or episode length'},
                  'person': {'type': 'string'},
                  'country': {'type': 'string'},
                  'library': {'type': 'string', 'description': 'Library name contains, e.g. "Anime", "Docs"'},
                  'text': {'type': 'string'},
                  'like': {'type': 'string'},
                },
              },
            },
            'required': ['title', 'request', 'why', 'search'],
          },
        },
      },
      'required': ['lists'],
    },
  };
}
