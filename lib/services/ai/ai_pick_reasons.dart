import 'dart:async';

import '../../utils/app_logger.dart';
import '../brain/history_brain.dart';
import 'ai_history.dart';
import 'ai_key_store.dart';
import 'ai_spend.dart';
import 'claude_client.dart';

/// Fork: a pick's reason when the answer didn't write one (only its first
/// picks get one, to keep answers quick): one small Haiku call, made on the
/// host when the pick's peek sheet opens, and saved with the answer so it
/// is made once and mirrors to the phone.
abstract final class AiPickReasons {
  static final Map<String, Future<String?>> _running = {};

  /// The reason for the item [key] of the saved answer [entryId]; null when
  /// it can't be made (no key, no such answer or item, the call failed).
  static Future<String?> reasonFor(String entryId, String key) =>
      _running['$entryId/$key'] ??= _make(entryId, key).whenComplete(() {
        // A block body: returning the removed future would wait on itself.
        _running.remove('$entryId/$key');
      });

  static Future<String?> _make(String entryId, String key) async {
    final entry = await AiHistory.get(entryId);
    final existing = entry?.reasons[key]?.trim();
    if (existing != null && existing.isNotEmpty) return existing;
    final item = entry?.items.where((i) => i.globalKey == key).firstOrNull;
    final apiKey = await AiKeyStore.read();
    if (entry == null || item == null || apiKey == null || apiKey.isEmpty) return null;

    String taste = '';
    try {
      taste = await HistoryBrain.instance.taste();
    } catch (_) {}
    final about = [
      '${item.title}${item.year == null ? '' : ' (${item.year})'}, ${item.kind.name}',
      if (item.genres?.isNotEmpty ?? false) 'Genres: ${item.genres!.join(', ')}',
      if (item.summary?.isNotEmpty ?? false) 'Summary: ${item.summary}',
    ].join('\n');
    final client = ClaudeClient(apiKey);
    try {
      final response = await client.createMessage({
        'model': ClaudeModel.haiku.id,
        'max_tokens': 200,
        // One short sentence: no thinking (it would use up the budget).
        'thinking': {'type': 'disabled'},
        'system':
            'You explain, in one sentence of at most 20 words, why a film or show fits what the user asked for. '
            'Specific to the title, spoiler-free, plain text, no quotes or preamble.',
        'messages': [
          {
            'role': 'user',
            'content':
                'They asked: ${entry.request}\n\n'
                '${taste.isEmpty ? '' : 'Their watching, for taste:\n${taste.length > 1500 ? taste.substring(0, 1500) : taste}\n\n'}'
                'The pick:\n$about',
          },
        ],
      });
      final cost = await AiSpend.record(ClaudeModel.haiku, (response['usage'] as Map?)?.cast<String, dynamic>() ?? {});
      final text = [
        for (final b in (response['content'] as List? ?? const []).whereType<Map>())
          if (b['type'] == 'text') '${b['text']}',
      ].join().trim();
      if (text.isEmpty) return null;
      // The answer as it is now: it may have changed meanwhile.
      final current = await AiHistory.get(entryId);
      if (current != null) await AiHistory.replace(current.withReason(key, text));
      appLogger.d('AI: a pick reason, \$${cost.toStringAsFixed(4)}');
      return text;
    } catch (e) {
      appLogger.d('AI: pick reason failed', error: e);
      return null;
    } finally {
      client.close();
    }
  }
}
