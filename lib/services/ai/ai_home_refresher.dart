import 'dart:async';

import '../../media/ids.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../catalog/home_pins.dart';
import '../customisation/customisation_store.dart';
import '../trackers/trakt/trakt_client.dart';
import 'ai_history.dart';
import 'ai_key_store.dart';
import 'ai_rows.dart';
import 'ai_spend.dart';
import 'claude_client.dart';

/// Keeps AI rows on Home fresh while Plezy is open: each one re-runs its
/// request on Haiku once its picks are [maxAge] old, checked at start and
/// then hourly, one row at a time. A failed refresh keeps the old picks and
/// tries again at the next check. Rows only on the AI tab never refresh.
abstract final class AiHomeRefresher {
  static const Duration maxAge = Duration(hours: 12);
  static const Duration checkEvery = Duration(hours: 1);

  /// Most AI rows Home can hold, so auto-refresh costs stay small.
  static const int maxHomeRows = 10;

  static const String enabledKey = 'ai.autoRefreshHome';

  static Timer? _timer;
  static bool _running = false;
  static MediaServerClient? Function(ServerId serverId)? _clientFor;
  static TraktClient? Function()? _trakt;

  static Future<bool> enabled() async => await (await Customisation.store).readSetting(enabledKey) != 'false';

  static Future<void> setEnabled(bool on) async =>
      (await Customisation.store).writeSetting(enabledKey, on ? null : 'false');

  /// AI rows currently on Home.
  static int homeRowCount() =>
      HomePinsController.instance.layout.rows.where((r) => r.id.startsWith(HomeRowIds.ai(''))).length;

  static void start({
    required MediaServerClient? Function(ServerId serverId) clientFor,
    required TraktClient? Function() trakt,
  }) {
    _clientFor = clientFor;
    _trakt = trakt;
    _timer ??= Timer.periodic(checkEvery, (_) => unawaited(check()));
    unawaited(check());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Refresh every Home AI row that is due. Returns how many were refreshed.
  static Future<int> check({bool force = false}) async {
    final clientFor = _clientFor;
    if (_running || clientFor == null) return 0;
    _running = true;
    var refreshed = 0;
    try {
      if (!await enabled() || await AiKeyStore.read() == null) return 0;
      await HomePinsController.instance.ensureLoaded();
      final prefix = HomeRowIds.ai('');
      final ids = [
        for (final row in HomePinsController.instance.layout.rows)
          if (row.id.startsWith(prefix)) row.id.substring(prefix.length),
      ];
      for (final id in ids) {
        final entry = await AiHistory.get(id);
        if (entry == null) continue;
        if (!force && DateTime.now().difference(entry.createdAt) < maxAge) continue;
        if (await _refresh(entry, clientFor)) refreshed++;
      }
    } catch (e) {
      appLogger.w('AI auto-refresh: check failed', error: e);
    } finally {
      _running = false;
    }
    return refreshed;
  }

  static Future<bool> _refresh(AiHistoryEntry entry, MediaServerClient? Function(ServerId) clientFor) async {
    if (entry.extended) return _extend(entry, clientFor);
    final previous = entry.items.map((i) => i.title).nonNulls.join(', ');
    final sent =
        '${entry.request}\n\n'
        'This refreshes a row the user already has. Leave out anything they have already watched, and prefer '
        'titles that were not in the previous version (${previous.isEmpty ? 'none' : previous}), so the row '
        'feels fresh; a few strong repeats are fine. Keep it to 20 picks at most.';
    try {
      final result = await buildAiRow(
        request: entry.request,
        sentRequest: sent,
        model: ClaudeModel.haiku,
        clientFor: clientFor,
        trakt: _trakt?.call(),
        id: entry.id,
        keepTitle: entry.title,
      );
      await AiSpend.noteAutoRefresh(result.answer.cost);
      final fresh = result.entry;
      if (fresh == null) {
        appLogger.i('AI auto-refresh: no picks for "${entry.label}"; keeping the old ones');
        return false;
      }
      await AiHistory.replace(fresh);
      appLogger.i(
        'AI auto-refresh: "${entry.label}" now has ${fresh.items.length} picks '
        '(\$${result.answer.cost.toStringAsFixed(4)})',
      );
      return true;
    } catch (e) {
      appLogger.w('AI auto-refresh: "${entry.label}" failed; keeping the old picks', error: e);
      return false;
    }
  }

  /// A row grown with Find more keeps its picks: add up to 10 new ones in
  /// front instead of replacing it.
  static Future<bool> _extend(AiHistoryEntry entry, MediaServerClient? Function(ServerId) clientFor) async {
    try {
      final result = await buildAiRow(
        request: entry.request,
        sentRequest: '${findMoreRequest(entry, atMost: 10)} Leave out anything they have already watched.',
        model: ClaudeModel.haiku,
        clientFor: clientFor,
        trakt: _trakt?.call(),
        id: entry.id,
        keepTitle: entry.title,
        excludeKeys: {for (final i in entry.items) i.globalKey},
      );
      await AiSpend.noteAutoRefresh(result.answer.cost);
      final found = result.entry;
      // Restart the clock either way, so a row with nothing new isn't retried hourly.
      await AiHistory.replace(
        found == null
            ? mergeFindMore(entry, entry, createdAt: DateTime.now())
            : mergeFindMore(entry, found, createdAt: DateTime.now()),
      );
      appLogger.i(
        'AI auto-refresh: "${entry.label}" gained ${found?.items.length ?? 0} picks '
        '(\$${result.answer.cost.toStringAsFixed(4)})',
      );
      return found != null;
    } catch (e) {
      appLogger.w('AI auto-refresh: "${entry.label}" failed; keeping the old picks', error: e);
      return false;
    }
  }
}
