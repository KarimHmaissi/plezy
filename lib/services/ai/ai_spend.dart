import 'dart:convert';

import '../customisation/customisation_store.dart';
import 'claude_client.dart';

typedef AiMonthSpend = ({double dollars, int requests, int inputTokens, int outputTokens, int cachedTokens});

/// What the AI helper has cost, per calendar month, from each response's
/// token usage (no cap; shown in Settings ▸ AI).
abstract final class AiSpend {
  static String _key(DateTime month) => 'ai.spend.${month.year}-${month.month.toString().padLeft(2, '0')}';

  static Future<AiMonthSpend> month([DateTime? when]) async {
    final raw = await (await Customisation.store).readSetting(_key(when ?? DateTime.now()));
    final j = raw == null ? const <String, Object?>{} : jsonDecode(raw) as Map<String, Object?>;
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    return (
      dollars: (j['dollars'] as num?)?.toDouble() ?? 0,
      requests: i('requests'),
      inputTokens: i('input'),
      outputTokens: i('output'),
      cachedTokens: i('cached'),
    );
  }

  /// Add one response's usage; returns its cost in dollars.
  static Future<double> record(ClaudeModel model, Map<String, dynamic> usage) async {
    final cost = model.cost(usage);
    final now = DateTime.now();
    final current = await month(now);
    int n(String k) => (usage[k] as num?)?.toInt() ?? 0;
    await (await Customisation.store).writeSetting(
      _key(now),
      jsonEncode({
        'dollars': current.dollars + cost,
        'requests': current.requests + 1,
        'input': current.inputTokens + n('input_tokens') + n('cache_creation_input_tokens'),
        'output': current.outputTokens + n('output_tokens'),
        'cached': current.cachedTokens + n('cache_read_input_tokens'),
      }),
    );
    return cost;
  }
}
