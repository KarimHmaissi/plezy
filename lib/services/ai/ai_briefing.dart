import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
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

/// Fork: the short daily briefing at the top of the AI tab ("you've been on
/// a sci-fi run; two new episodes of X; time for a comfort rewatch?").
///
/// Made on the host at most once a day with Haiku, from facts the history
/// brain computes (so the model phrases, never counts), and kept as one
/// setting: a phone mirroring the host gets it with the rest of the data.
/// Shown as an answer row: the text, then its titles as cards.
abstract final class AiBriefing {
  /// Off until the briefing is signed off: the AI tab shows none and makes none.
  static const bool enabled = false;

  static const String settingKey = 'ai.briefing';
  static const String entryId = 'briefing';

  static Future<AiHistoryEntry?>? _running;

  /// The saved briefing, whatever its day.
  static Future<AiHistoryEntry?> cached() async {
    final raw = await (await Customisation.store).readSetting(settingKey);
    return raw == null ? null : AiHistoryEntry.fromJson(jsonDecode(raw));
  }

  static bool _isToday(AiHistoryEntry e) {
    final a = e.createdAt, b = DateTime.now();
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// Today's briefing: the saved one if it's from today (unless [force]),
  /// else a new one. Null without a key or a history brain.
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
    final watched = await brain.watchedProfiles();
    if (watched.isEmpty) return cached();
    final facts = briefingFacts(
      watched,
      now: DateTime.now(),
      cardId: _cardId,
      newEpisodes: await _newEpisodes(watched),
    );

    final client = ClaudeClient(key);
    try {
      final response = await client.createMessage({
        'model': ClaudeModel.haiku.id,
        'max_tokens': 1200,
        'system': _prompt,
        'tools': [_tool],
        'tool_choice': {'type': 'tool', 'name': _tool['name']},
        'messages': [
          {'role': 'user', 'content': facts},
        ],
      });
      final usage = (response['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
      final cost = await AiSpend.record(ClaudeModel.haiku, usage);
      final input = [
        for (final b in (response['content'] as List? ?? const []).whereType<Map>())
          if (b['type'] == 'tool_use') (b['input'] as Map).cast<String, dynamic>(),
      ].firstOrNull;
      final lines = [
        for (final l in (input?['lines'] as List? ?? const []))
          if ('$l'.trim().isNotEmpty) '$l'.trim(),
      ];
      if (lines.isEmpty) return await cached();

      final ids = [
        for (final t in (input?['titles'] as List? ?? const []))
          if (t is String) t,
      ];
      final items = await _items(ids, clientFor);
      final entry = AiHistoryEntry(
        id: entryId,
        request: entryId,
        title: input?['title'] as String?,
        intro: null,
        answer: lines.join('\n'),
        createdAt: DateTime.now(),
        items: items,
        reasons: const {},
      );
      await (await Customisation.store).writeSetting(settingKey, jsonEncode(entry.toJson()));
      appLogger.i(
        'AI briefing: ${lines.length} lines, ${items.length} titles, \$${cost.toStringAsFixed(4)} '
        '(${usage['input_tokens']} in, ${usage['output_tokens']} out)',
      );
      return entry;
    } catch (e) {
      appLogger.w('AI briefing failed', error: e);
      return await cached();
    } finally {
      client.close();
    }
  }

  static String? _cardId(TitleProfile p) =>
      p.inLibrary && p.serverId != null && p.ratingKey != null ? '${p.serverId}:${p.ratingKey}' : null;

  /// Shows with episodes added to the library since the user last watched.
  static Future<Set<String>> _newEpisodes(List<TitleProfile> watched) async {
    final shows = {
      for (final p in watched)
        if (!p.isMovie && p.lastWatched != null && _cardId(p) != null) _cardId(p)!: p,
    };
    if (shows.isEmpty) return const {};
    final db = await LibraryIndex.instance.database;
    final out = <String>{};
    final ids = shows.keys.toList();
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, (i + 500).clamp(0, ids.length));
      final rows = await db
          .customSelect(
            'SELECT id, episode_count, updated_at FROM index_titles WHERE id IN (${List.filled(chunk.length, '?').join(',')})',
            variables: [for (final id in chunk) Variable<String>(id)],
            readsFrom: {db.indexTitles},
          )
          .get();
      for (final r in rows) {
        final p = shows[r.read<String>('id')]!;
        final episodes = r.readNullable<int>('episode_count') ?? 0;
        final updated = r.readNullable<int>('updated_at') ?? 0;
        if (episodes > p.episodesWatched && updated * 1000 > p.lastWatched!.millisecondsSinceEpoch) out.add(p.id);
      }
    }
    return out;
  }

  static Future<List<MediaItem>> _items(List<String> ids, MediaServerClient? Function(ServerId) clientFor) async {
    final fetched = await Future.wait([
      for (final id in ids.take(8))
        () async {
          final cut = id.indexOf(':');
          if (cut <= 0) return null;
          try {
            return await clientFor(ServerId(id.substring(0, cut)))?.fetchItem(id.substring(cut + 1));
          } catch (e) {
            appLogger.d('AI briefing: a title could not be loaded', error: e);
            return null;
          }
        }(),
    ]);
    return fetched.nonNulls.toList();
  }

  static const String _prompt = '''
You write the daily briefing at the top of a family's TV app: a friendly, specific note about their own watching, from the facts given. Rules:
- 3 to 5 short lines, each one sentence. Plain text, no markdown, no emoji, no greeting.
- Cover, in this order when the facts allow: what they've been into lately; a show they're partway through (say if new episodes were added); one rewatch or Comfort nudge; one fun pattern.
- Use only the facts given: never invent titles, numbers or dates. Name titles exactly as given (without the year unless needed).
- Warm and light, not salesy. Address them as "you".''';

  static const Map<String, Object?> _tool = {
    'name': 'show_briefing',
    'description': 'Show the briefing.',
    'input_schema': {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': '2-4 words, e.g. "Your week in TV"'},
        'lines': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '3-5 one-sentence lines',
        },
        'titles': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'The [ids] of the titles the lines mention, in order of mention, at most 6',
        },
      },
      'required': ['title', 'lines', 'titles'],
    },
  };
}
