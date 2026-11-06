import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:plezy_brain/plezy_brain.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../brain/history_brain.dart';
import '../customisation/customisation_store.dart';
import '../library_index/library_index.dart';
import 'ai_history.dart';
import 'ai_key_store.dart';
import 'ai_rows.dart' show pickFetchTimeout;
import 'ai_spend.dart';
import 'ai_suggestions.dart' show AiSuggestions;
import 'claude_client.dart';

/// Fork: "Tonight" at the top of the AI page on touch screens: three cards,
/// each a title with a one-line reason.
///
/// - New episode: a show the user is partway through with episodes they
///   haven't seen, newest additions first.
/// - Tonight's pick: the strongest unwatched match for their taste that
///   fits an evening.
/// - From your library: rated 8+ by audiences (7.5+ by critics, when
///   known) and on the server a year or more, also matching their taste.
///
/// The brain and the local library index (no server crawl) find
/// candidates near what they love; [model] chooses each card from them and
/// writes its line. A title shown recently ([cooldown]) waits its turn while
/// there are others, so a new Tonight (pull to refresh, or the next day)
/// brings different titles. Made on the host at most
/// once a day (pull to refresh makes a new one) and kept as one setting, so
/// a phone mirroring the host gets it with the rest of the data. The slot
/// of each card is in [AiHistoryEntry.spotlights] ([slotNewEpisode]...),
/// its line in [AiHistoryEntry.reasons].
abstract final class AiBriefing {
  static const bool enabled = true;

  static const String settingKey = 'ai.briefing';
  static const String entryId = 'briefing';

  static const String slotNewEpisode = 'newEpisode';
  static const String slotPick = 'pick';
  static const String slotLibrary = 'library';

  static Future<AiHistoryEntry?>? _running;

  /// Titles shown on a card in the last [cooldown] (card id → when), so the
  /// next Tonight picks others.
  static const String shownKey = 'ai.briefing.shown';
  static const Duration cooldown = Duration(days: 5);

  /// How many candidates the model chooses each card from.
  static const int maxCandidates = 15;

  /// Choosing well needs judgement (tone, audience), not just a line of
  /// copy: Sonnet, once a day, a cent or two.
  static const ClaudeModel model = ClaudeModel.sonnet;

  /// What the last run knew about each card (for checking by hand).
  static List<String> lastFacts = const [];

  /// The saved card set, whatever its day.
  static Future<AiHistoryEntry?> cached() async {
    final raw = await (await Customisation.store).readSetting(settingKey);
    if (raw == null) return null;
    final entry = AiHistoryEntry.fromJson(jsonDecode(raw));
    // A briefing from before the cards: make a new one.
    return entry != null && entry.spotlights.isNotEmpty ? entry : null;
  }

  static bool _isToday(AiHistoryEntry e) {
    final a = e.createdAt, b = DateTime.now();
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Today's cards: the saved ones if they're from today (unless [force]),
  /// else new ones. Null without a key or a history brain.
  static Future<AiHistoryEntry?> today({
    required MediaServerClient? Function(ServerId serverId) clientFor,
    bool force = false,
  }) async {
    final saved = await cached();
    if (!force && saved != null && _isToday(saved)) return saved;
    return _running ??= _make(clientFor).whenComplete(() => _running = null);
  }

  static Future<AiHistoryEntry?> _make(MediaServerClient? Function(ServerId serverId) clientFor) async {
    final key = await AiKeyStore.read();
    final brain = HistoryBrain.instance;
    if (key == null || !await brain.hasProfiles()) {
      appLogger.i('AI tonight: no key or history yet');
      return cached();
    }
    final now = DateTime.now();
    final watched = await brain.watchedProfiles();
    if (watched.isEmpty) return cached();

    final store = await Customisation.store;
    final shown = _readShown(await store.readSetting(shownKey), now);
    final episode = await _newEpisode(watched, now, shown);
    final pool = await _tastePool(brain, watched, now);
    final candidates = await _candidates(pool, now, shown);
    if (episode == null && candidates.pick.isEmpty && candidates.gem.isEmpty) {
      appLogger.i('AI tonight: no candidates (pool ${pool.length})');
      return cached();
    }
    String line(String slot, _Candidate c) =>
        '- $slot: ${c.profile.title}${c.profile.year == null ? '' : ' (${c.profile.year})'}. ${c.facts}';
    String options(String prefix, List<_Candidate> list) => [
      for (final (i, c) in list.indexed)
        '$prefix${i + 1}: ${c.profile.title}${c.profile.year == null ? '' : ' (${c.profile.year})'}. ${c.facts}',
    ].join('\n');

    final client = ClaudeClient(key);
    try {
      final taste = await brain.taste();
      final response = await client.createMessage({
        'model': model.id,
        'max_tokens': 600,
        'thinking': model.noThinking,
        'system': _prompt,
        'tools': [_tool],
        'tool_choice': model.answerWith(_tool['name']! as String),
        'messages': [
          {
            'role': 'user',
            'content': [
              'Their taste:\n$taste',
              if (episode != null)
                'The newEpisode card:\n${line(slotNewEpisode, (profile: episode.profile, facts: episode.facts))}',
              if (candidates.pick.isNotEmpty) 'Choose the pick from:\n${options('p', candidates.pick)}',
              if (candidates.gem.isNotEmpty) 'Choose the library card from:\n${options('g', candidates.gem)}',
            ].join('\n\n'),
          },
        ],
      });
      final usage = (response['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cost = await AiSpend.record(model, usage);
      final input = [
        for (final b in (response['content'] as List? ?? const []).whereType<Map>())
          if (b['type'] == 'tool_use') (b['input'] as Map).cast<String, dynamic>(),
      ].firstOrNull;
      // The model's choice, or the best candidate when it named none.
      _Candidate? chosen(String key, String prefix, List<_Candidate> list) {
        final n = int.tryParse('${input?[key] ?? ''}'.replaceFirst(prefix, ''));
        return n != null && n >= 1 && n <= list.length ? list[n - 1] : list.firstOrNull;
      }

      final pick = chosen('pick_id', 'p', candidates.pick);
      // Never the pick twice.
      final gem = switch (chosen('library_id', 'g', candidates.gem)) {
        final g? when g.profile.id != pick?.profile.id => g,
        _ => candidates.gem.where((c) => c.profile.id != pick?.profile.id).firstOrNull,
      };
      final slots = <(String, TitleProfile, String)>[
        if (episode != null) (slotNewEpisode, episode.profile, episode.facts),
        if (pick != null) (slotPick, pick.profile, pick.facts),
        if (gem != null) (slotLibrary, gem.profile, gem.facts),
      ];
      lastFacts = [for (final (slot, p, facts) in slots) '$slot: ${p.title}: $facts'];
      final lines = {
        for (final (slot, _, _) in slots)
          if ('${input?[slot] ?? ''}'.trim() case final line when line.isNotEmpty) slot: line,
      };

      final items = <MediaItem>[];
      final slotOf = <String, String>{};
      final reasons = <String, String>{};
      for (final (slot, p, _) in slots) {
        final item = await _item(p, clientFor);
        if (item == null) continue;
        items.add(item);
        slotOf[item.globalKey] = slot;
        if (lines[slot] case final line?) reasons[item.globalKey] = line;
      }
      if (items.isEmpty) {
        appLogger.i('AI tonight: none of ${slots.length} cards loaded from the servers');
        return await cached();
      }
      final entry = AiHistoryEntry(
        id: entryId,
        request: entryId,
        title: null,
        intro: null,
        answer: null,
        createdAt: now,
        items: items,
        reasons: reasons,
        spotlights: slotOf,
      );
      await store.writeSetting(settingKey, jsonEncode(entry.toJson()));
      await store.writeSetting(
        shownKey,
        jsonEncode({
          ...shown.map((id, at) => MapEntry(id, at.millisecondsSinceEpoch)),
          for (final (_, p, _) in slots) ?_cardId(p): now.millisecondsSinceEpoch,
        }),
      );
      appLogger.i(
        'AI tonight: ${items.length} cards (${slotOf.values.join(', ')}), \$${cost.toStringAsFixed(4)} '
        '(${usage['input_tokens']} in, ${usage['output_tokens']} out)',
      );
      return entry;
    } catch (e) {
      appLogger.w('AI tonight failed', error: e);
      return await cached();
    } finally {
      client.close();
    }
  }

  /// Recently shown titles still in their [cooldown].
  static Map<String, DateTime> _readShown(String? raw, DateTime now) {
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is int)
            if (DateTime.fromMillisecondsSinceEpoch(value) case final at when now.difference(at) < cooldown) key: at,
      };
    } catch (_) {
      return {};
    }
  }

  /// [ranked] (best first) for the model to choose from: titles not shown
  /// lately; while fewer than [minFresh] are, the ones shown longest ago
  /// make up the list.
  @visibleForTesting
  static List<T> rotate<T>(List<T> ranked, {required String? Function(T) id, required Map<String, DateTime> shown}) {
    final fresh = [
      for (final c in ranked)
        if (!shown.containsKey(id(c))) c,
    ];
    if (fresh.length >= minFresh) return fresh.take(maxCandidates).toList();
    final stale = [
      for (final c in ranked)
        if (shown.containsKey(id(c))) c,
    ]..sort((a, b) => shown[id(a)]!.compareTo(shown[id(b)]!));
    return [...fresh, ...stale].take(maxCandidates).toList();
  }

  static const int minFresh = 3;

  static String? _cardId(TitleProfile p) =>
      p.inLibrary && p.serverId != null && p.ratingKey != null ? '${p.serverId}:${p.ratingKey}' : null;

  /// Library index rows for [ids] (card ids), by id.
  static Future<Map<String, QueryRow>> _indexRows(Iterable<String> ids) async {
    final db = await LibraryIndex.instance.database;
    final list = ids.toList();
    final out = <String, QueryRow>{};
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, (i + 500).clamp(0, list.length));
      final rows = await db
          .customSelect(
            'SELECT id, episode_count, added_at, updated_at, audience_rating, critic_rating, duration_minutes '
            'FROM index_titles WHERE id IN (${List.filled(chunk.length, '?').join(',')})',
            variables: [for (final id in chunk) Variable<String>(id)],
            readsFrom: {db.indexTitles},
          )
          .get();
      for (final r in rows) {
        out[r.read<String>('id')] = r;
      }
    }
    return out;
  }

  /// A show watched in the last four months and not caught up, with
  /// episodes on the server they haven't seen: new since they last watched
  /// first, then the most recently updated.
  static Future<({TitleProfile profile, String facts})?> _newEpisode(
    List<TitleProfile> watched,
    DateTime now,
    Map<String, DateTime> shown,
  ) async {
    final shows = {
      for (final p in watched)
        if (!p.isMovie &&
            p.lastWatched != null &&
            now.difference(p.lastWatched!) < const Duration(days: 120) &&
            p.progress(now) != ShowProgress.finished &&
            _cardId(p) != null)
          _cardId(p)!: p,
    };
    if (shows.isEmpty) return null;
    final rows = await _indexRows(shows.keys);
    final candidates = <({TitleProfile profile, int unseen, bool fresh, int updated})>[];
    for (final MapEntry(key: id, value: p) in shows.entries) {
      final r = rows[id];
      if (r == null) continue;
      final unseen = (r.readNullable<int>('episode_count') ?? 0) - p.episodesWatched;
      if (unseen <= 0) continue;
      final updated = r.readNullable<int>('updated_at') ?? 0;
      final fresh = updated * 1000 > p.lastWatched!.millisecondsSinceEpoch;
      candidates.add((profile: p, unseen: unseen, fresh: fresh, updated: updated));
    }
    // New since they last watched first, then the most recently updated.
    candidates.sort((a, b) => a.fresh != b.fresh ? (a.fresh ? -1 : 1) : b.updated.compareTo(a.updated));
    final best = rotate(candidates, id: (c) => _cardId(c.profile), shown: shown).firstOrNull;
    if (best == null) return null;
    return (
      profile: best.profile,
      facts:
          'Watched ${best.profile.episodesWatched} of ${best.profile.episodesWatched + best.unseen} episodes, '
          '${best.unseen} unwatched${best.fresh ? ', some added since they last watched' : ''}. '
          '${_genres(best.profile)}',
    );
  }

  /// Unwatched titles in the library nearest the ones they love most, with
  /// how strongly and which loved titles they're like.
  /// The taste pool (similar unwatched titles to their best-loved ones),
  /// shared with the Reel's daily For You build.
  static Future<List<({TitleProfile profile, double score, List<String> like})>> tastePool(
    HistoryBrain brain,
    List<TitleProfile> watched,
    DateTime now,
  ) => _tastePool(brain, watched, now);

  static Future<List<({TitleProfile profile, double score, List<String> like})>> _tastePool(
    HistoryBrain brain,
    List<TitleProfile> watched,
    DateTime now,
  ) async {
    int weight(TitleProfile p) =>
        (p.myRating ?? 0) * 10 +
        (p.rewatched ? 15 : 0) +
        (p.comfort ? 20 : 0) +
        (p.lastWatched != null && now.difference(p.lastWatched!) < const Duration(days: 180) ? 25 : 0);
    final seeds = [
      for (final p in watched)
        if ((p.myRating ?? 0) >= 8 || p.rewatched || p.comfort || p.progress(now) == ShowProgress.finished) p,
    ]..sort((a, b) => weight(b) - weight(a));
    final pool = <String, ({TitleProfile profile, double score, List<String> like})>{};
    for (final seed in seeds.take(8)) {
      for (final hit in await brain.similar(seed.id, limit: 25, watched: false)) {
        if (_cardId(hit.profile) == null) continue;
        final had = pool[hit.profile.id];
        pool[hit.profile.id] = (
          profile: hit.profile,
          score: (had?.score ?? 0) + hit.score,
          like: [...?had?.like, seed.title],
        );
      }
    }
    return pool.values.toList()..sort((a, b) => b.score.compareTo(a.score));
  }

  /// Candidates for Tonight's pick (rated 7+, a film of 80-150 minutes or a
  /// show) and the library gem (rated 8+, critics 7.5+ when known, on the
  /// server a year or more), best first, titles shown lately left out
  /// ([rotate]). The
  /// model chooses among them: similarity alone matches on surface words
  /// ("Girlfriends" for someone who loved "Friends").
  static Future<({List<_Candidate> pick, List<_Candidate> gem})> _candidates(
    List<({TitleProfile profile, double score, List<String> like})> pool,
    DateTime now,
    Map<String, DateTime> shown,
  ) async {
    if (pool.isEmpty) return (pick: const <_Candidate>[], gem: const <_Candidate>[]);
    final top = pool.take(120).toList();
    final rows = await _indexRows([for (final c in top) _cardId(c.profile)!]);
    double? rating(TitleProfile p) => rows[_cardId(p)]?.readNullable<double>('audience_rating') ?? p.audienceRating;
    // Nearness leads, but a better rated title close by moves ahead, so the
    // model sees the strongest candidates.
    final place = {for (final (i, c) in top.indexed) c.profile.id: i};
    double order(TitleProfile p) => AiSuggestions.rankScore(place[p.id]!, rating(p));
    top.sort((a, b) => order(a.profile).compareTo(order(b.profile)));
    String facts(({TitleProfile profile, double score, List<String> like}) c) {
      final p = c.profile;
      final minutes = rows[_cardId(p)]?.readNullable<int>('duration_minutes') ?? p.runtimeMinutes;
      return [
        p.isMovie ? 'Film' : 'Show',
        if (minutes != null) '$minutes min${p.isMovie ? '' : ' episodes'}',
        if (rating(p) case final r?) 'rated ${r.toStringAsFixed(1)}/10',
        if (rows[_cardId(p)]?.readNullable<double>('critic_rating') case final r?) 'critics ${r.toStringAsFixed(1)}/10',
        _genres(p),
        'Near their ${c.like.take(3).join(', ')}',
        if (p.summary case final s? when s.isNotEmpty) s.length > 280 ? '${s.substring(0, 280)}…' : s,
      ].where((s) => s.isNotEmpty).join('. ');
    }

    bool length(TitleProfile p) {
      if (!p.isMovie) return true;
      final minutes = rows[_cardId(p)]?.readNullable<int>('duration_minutes') ?? p.runtimeMinutes;
      return minutes != null && minutes >= 80 && minutes <= 150;
    }

    String? id(_Candidate c) => _cardId(c.profile);
    final pick = rotate(
      [
        for (final c in top)
          if ((rating(c.profile) ?? 0) >= 7 && length(c.profile)) (profile: c.profile, facts: facts(c)),
      ],
      id: id,
      shown: shown,
    );
    final yearAgo = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch ~/ 1000;
    bool gemWorthy(TitleProfile p) {
      final row = rows[_cardId(p)];
      final critics = row?.readNullable<double>('critic_rating');
      final added = row?.readNullable<int>('added_at');
      return (rating(p) ?? 0) >= 8 && (critics == null || critics >= 7.5) && added != null && added < yearAgo;
    }

    final gem = rotate(
      [
        for (final c in top)
          if (gemWorthy(c.profile)) (profile: c.profile, facts: '${facts(c)}. On their server over a year'),
      ],
      id: id,
      shown: shown,
    );
    return (pick: pick, gem: gem);
  }

  static String _genres(TitleProfile p) => p.genres.isEmpty ? '' : 'Genres: ${p.genres.take(3).join(', ')}';

  static Future<MediaItem?> _item(TitleProfile p, MediaServerClient? Function(ServerId) clientFor) async {
    try {
      return await clientFor(ServerId(p.serverId!))?.fetchItem(p.ratingKey!).timeout(pickFetchTimeout);
    } catch (e) {
      appLogger.d('AI tonight: a title could not be loaded', error: e);
      return null;
    }
  }

  static const String _prompt = '''
You choose and introduce up to three cards at the top of a TV app tonight.
- pick: choose the one candidate (p1, p2, ...) they would most enjoy tonight. library: choose the one candidate (g1, g2, ...) from their own library most worth finally watching. Judge by genre, tone, story and audience against their taste, and favour the better rated (the ratings are in the facts): a lower-rated title only when it clearly fits them better. The candidates are only similar by a rough measure that can match on surface words ("Girlfriends" is nothing like "Friends", a kids' cartoon is nothing like a grown-up drama), so ignore any candidate that doesn't genuinely fit.
- Then one line per card, at most 14 words, plain text, no markdown, no emoji. The card already shows its title: never name it in its line.
- newEpisode: nudge them back to the show (where they are, what's waiting). pick: why it suits their taste tonight. library: why this one they own is worth finally watching.
- Be specific: name what it shares with titles they love, from the facts given. Never invent facts.
- Warm and light, not salesy. Address them as "you".
- Answer only by calling show_cards, once.''';

  static const Map<String, Object?> _tool = {
    'name': 'show_cards',
    'description': 'Show the card lines.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'pick_id': {'type': 'string', 'description': 'The chosen pick candidate, e.g. "p3"'},
        'library_id': {'type': 'string', 'description': 'The chosen library candidate, e.g. "g2"'},
        slotNewEpisode: {'type': 'string', 'description': 'The newEpisode card line, if that card is given'},
        slotPick: {'type': 'string', 'description': 'The pick card line, if given'},
        slotLibrary: {'type': 'string', 'description': 'The library card line, if given'},
      },
    },
  };
}

/// A title Tonight could show, with what's known about it for the model.
typedef _Candidate = ({TitleProfile profile, String facts});
