import 'dart:convert';

import '../customisation/customisation_store.dart';
import 'claude_client.dart';

typedef AiMonthSpend = ({
  double dollars,
  int requests,
  int inputTokens,
  int outputTokens,
  int cachedTokens,
  double autoRefreshDollars,
});

/// What the AI helper has cost, per calendar month, from each response's
/// token usage (no cap; shown in Settings ▸ AI).
abstract final class AiSpend {
  /// Settings keys of this device's spend records; another device's copy
  /// of the data shouldn't bring its spend along.
  static const String keyPrefix = 'ai.spend.';

  static String _key(DateTime month) => '$keyPrefix${month.year}-${month.month.toString().padLeft(2, '0')}';

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
      autoRefreshDollars: (j['auto'] as num?)?.toDouble() ?? 0,
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
        'auto': current.autoRefreshDollars,
      }),
    );
    return cost;
  }

  /// Note that [dollars] (already recorded) went on Home's auto-refresh, so
  /// Settings can show it separately.
  static Future<void> noteAutoRefresh(double dollars) async {
    final now = DateTime.now();
    final store = await Customisation.store;
    final raw = await store.readSetting(_key(now));
    final j = raw == null ? <String, Object?>{} : Map<String, Object?>.of(jsonDecode(raw) as Map<String, Object?>);
    j['auto'] = ((j['auto'] as num?)?.toDouble() ?? 0) + dollars;
    await store.writeSetting(_key(now), jsonEncode(j));
  }
}
