import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
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
import 'ai_spend.dart';
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
/// The titles come from the history brain and the local library index (no
/// server crawl); Haiku only writes the lines. Made on the host at most
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
    if (key == null || brain.status.value.profiles == 0) return cached();
    final now = DateTime.now();
    final watched = await brain.watchedProfiles();
    if (watched.isEmpty) return cached();

    final episode = await _newEpisode(watched, now);
    final pool = await _tastePool(brain, watched, now);
    final picked = await _pickAndGem(pool, now);
    final slots = <(String, TitleProfile, String)>[
      if (episode != null) (slotNewEpisode, episode.profile, episode.facts),
      if (picked.pick case final p?) (slotPick, p.profile, p.facts),
      if (picked.gem case final g?) (slotLibrary, g.profile, g.facts),
    ];
    if (slots.isEmpty) return cached();
    lastFacts = [for (final (slot, p, facts) in slots) '$slot: ${p.title}: $facts'];

    final client = ClaudeClient(key);
    try {
      final taste = await brain.taste();
      final response = await client.createMessage({
        'model': ClaudeModel.haiku.id,
        'max_tokens': 400,
        'thinking': {'type': 'disabled'},
        'system': _prompt,
        'tools': [_tool],
        'tool_choice': {'type': 'tool', 'name': _tool['name']},
        'messages': [
          {
            'role': 'user',
            'content':
                'Their taste:\n$taste\nThe cards:\n'
                '${[for (final (slot, p, facts) in slots) '- $slot: ${p.title}${p.year == null ? '' : ' (${p.year})'}. $facts'].join('\n')}',
          },
        ],
      });
      final usage = (response['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cost = await AiSpend.record(ClaudeModel.haiku, usage);
      final input = [
        for (final b in (response['content'] as List? ?? const []).whereType<Map>())
          if (b['type'] == 'tool_use') (b['input'] as Map).cast<String, dynamic>(),
      ].firstOrNull;
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
      if (items.isEmpty) return await cached();
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
      await (await Customisation.store).writeSetting(settingKey, jsonEncode(entry.toJson()));
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
  static Future<({TitleProfile profile, String facts})?> _newEpisode(List<TitleProfile> watched, DateTime now) async {
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
    ({TitleProfile profile, int unseen, bool fresh, int updated})? best;
    for (final MapEntry(key: id, value: p) in shows.entries) {
      final r = rows[id];
      if (r == null) continue;
      final unseen = (r.readNullable<int>('episode_count') ?? 0) - p.episodesWatched;
      if (unseen <= 0) continue;
      final updated = r.readNullable<int>('updated_at') ?? 0;
      final fresh = updated * 1000 > p.lastWatched!.millisecondsSinceEpoch;
      final better = best == null || (fresh && !best.fresh) || (fresh == best.fresh && updated > best.updated);
      if (better) best = (profile: p, unseen: unseen, fresh: fresh, updated: updated);
    }
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

  /// Tonight's pick (rated 7+, a film of 80-150 minutes or a show) and a
  /// library gem (rated 8+, critics 7.5+ when known, on the server a year
  /// or more), not the same.
  static Future<({({TitleProfile profile, String facts})? pick, ({TitleProfile profile, String facts})? gem})>
  _pickAndGem(List<({TitleProfile profile, double score, List<String> like})> pool, DateTime now) async {
    if (pool.isEmpty) return (pick: null, gem: null);
    final top = pool.take(80).toList();
    final rows = await _indexRows([for (final c in top) _cardId(c.profile)!]);
    double? rating(TitleProfile p) => rows[_cardId(p)]?.readNullable<double>('audience_rating') ?? p.audienceRating;
    String facts(({TitleProfile profile, double score, List<String> like}) c) {
      final p = c.profile;
      final minutes = rows[_cardId(p)]?.readNullable<int>('duration_minutes') ?? p.runtimeMinutes;
      return [
        p.isMovie ? 'Film' : 'Show',
        if (minutes != null) '$minutes min${p.isMovie ? '' : ' episodes'}',
        if (rating(p) case final r?) 'rated ${r.toStringAsFixed(1)}/10',
        if (rows[_cardId(p)]?.readNullable<double>('critic_rating') case final r?) 'critics ${r.toStringAsFixed(1)}/10',
        _genres(p),
        'Like their ${c.like.take(3).join(', ')}',
        if (p.summary case final s? when s.isNotEmpty) s.length > 280 ? '${s.substring(0, 280)}…' : s,
      ].where((s) => s.isNotEmpty).join('. ');
    }

    final pick = top.where((c) {
      final r = rating(c.profile);
      if (r == null || r < 7) return false;
      if (!c.profile.isMovie) return true;
      final minutes = rows[_cardId(c.profile)]?.readNullable<int>('duration_minutes') ?? c.profile.runtimeMinutes;
      return minutes != null && minutes >= 80 && minutes <= 150;
    }).firstOrNull;
    final yearAgo = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch ~/ 1000;
    final gem = top.where((c) {
      if (identical(c, pick)) return false;
      final r = rating(c.profile);
      final critics = rows[_cardId(c.profile)]?.readNullable<double>('critic_rating');
      final added = rows[_cardId(c.profile)]?.readNullable<int>('added_at');
      return r != null && r >= 8 && (critics == null || critics >= 7.5) && added != null && added < yearAgo;
    }).firstOrNull;
    return (
      pick: pick == null ? null : (profile: pick.profile, facts: facts(pick)),
      gem: gem == null ? null : (profile: gem.profile, facts: '${facts(gem)}. On their server over a year'),
    );
  }

  static String _genres(TitleProfile p) => p.genres.isEmpty ? '' : 'Genres: ${p.genres.take(3).join(', ')}';

  static Future<MediaItem?> _item(TitleProfile p, MediaServerClient? Function(ServerId) clientFor) async {
    try {
      return await clientFor(ServerId(p.serverId!))?.fetchItem(p.ratingKey!);
    } catch (e) {
      appLogger.d('AI tonight: a title could not be loaded', error: e);
      return null;
    }
  }

  static const String _prompt = '''
You write the one-line reasons on three cards at the top of a TV app tonight, each under a title chosen for the user. Rules:
- One line per card, at most 14 words, plain text, no markdown, no emoji. The card already shows its title: never name it in its line.
- newEpisode: nudge them back to the show (where they are, what's waiting). pick: why it suits their taste tonight. library: why this one they own is worth finally watching.
- Be specific: name what it shares with titles they love, from the facts given. Never invent facts.
- Warm and light, not salesy. Address them as "you".''';

  static const Map<String, Object?> _tool = {
    'name': 'show_cards',
    'description': 'Show the card lines.',
    'input_schema': {
      'type': 'object',
      'properties': {
        slotNewEpisode: {'type': 'string', 'description': 'The newEpisode card line, if that card is given'},
        slotPick: {'type': 'string', 'description': 'The pick card line, if given'},
        slotLibrary: {'type': 'string', 'description': 'The library card line, if given'},
      },
    },
  };
}
