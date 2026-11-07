import 'dart:async';
import 'dart:math' as math;

import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_server_client.dart';
import '../utils/app_logger.dart';
import 'catalog/home_rows.dart';
import 'system_shelf_service.dart';
import 'reel/reel_store.dart';

/// The Reel's Saves as [ShelfSave]s for Android TV's Play Next row (V2-42,
/// D11): the same titles, in the same order, as the "From the Reel" Home
/// row, up to what the row can take. Android TV refuses a Watch Next sync of
/// more than [SystemShelf.maxItems] items, so only the newest that many are
/// published (a Save that can't be read gives its slot to the next older
/// one); the saved list itself (and the Home row) keeps every Save.
///
/// A launcher sync runs on every Continue Watching change, so each resolved
/// Save is kept until the Save itself changes: a server is asked about a
/// Save once, not once per sync. A Save whose server is offline, slow or
/// answers nothing is left out and asked about again on the next sync.
///
/// Launcher glue, not Reel code: it lives outside `lib/services/reel/`
/// because the shelf service reaches the Plex client, which the Reel's
/// no-reporting guard keeps every Reel file away from. It only calls
/// `fetchItem`, as the "From the Reel" Home row does.
class ReelShelfSaves {
  ReelShelfSaves({
    Future<List<ReelPick>> Function()? picks,
    this.fetchTimeout = HomeRowResolver.defaultPickFetchTimeout,
  }) : _picks = picks ?? ReelStore.instance.savedPicks;

  final Future<List<ReelPick>> Function() _picks;

  /// How long one Save's server may take before this sync goes on without it.
  final Duration fetchTimeout;

  final Map<String, MediaItem> _resolved = {};

  static String _key(ReelPick pick) => '${pick.titleId}@${pick.at.millisecondsSinceEpoch}';

  /// How far past [SystemShelf.maxItems] Saves a sync looks for ones it can
  /// read: Saves never expire, so one whose title is gone from its server
  /// (or whose server is) would otherwise hold a Play Next slot for good.
  static const int lookAhead = SystemShelf.maxItems * 2;

  /// The newest Saves (newest first, at most [SystemShelf.maxItems]: the
  /// most Play Next can show after Continue Watching) that [clientFor] can
  /// resolve. Saves that can't be read leave their slots to the next older
  /// ones, read only as many as are short, among the newest [lookAhead].
  Future<List<ShelfSave>> load(MediaServerClient? Function(ServerId serverId) clientFor) async {
    final picks = (await _picks()).take(lookAhead).toList();
    final current = {for (final pick in picks) _key(pick)};
    _resolved.removeWhere((key, _) => !current.contains(key));
    var fetched = 0;
    Future<ShelfSave?> resolve(ReelPick pick) async {
      final key = _key(pick);
      final known = _resolved[key];
      if (known != null) return ShelfSave(item: known, savedAt: pick.at);
      final client = clientFor(ServerId(pick.serverId));
      if (client == null) return null;
      try {
        fetched++;
        final item = await client.fetchItem(pick.ratingKey).timeout(fetchTimeout);
        if (item == null) return null;
        _resolved[key] = item;
        return ShelfSave(item: item, savedAt: pick.at);
      } catch (e) {
        appLogger.d('[ReelShelf] a Save could not be read for Play Next', error: e);
        return null;
      }
    }

    final saves = <ShelfSave>[];
    var next = 0;
    // Each round is older than the last, so the list stays newest first.
    while (saves.length < SystemShelf.maxItems && next < picks.length) {
      final round = picks.sublist(next, math.min(picks.length, next + SystemShelf.maxItems - saves.length));
      next += round.length;
      saves.addAll((await Future.wait(round.map(resolve))).nonNulls);
    }
    appLogger.i(
      '[ReelShelf] saves for Play Next: ${saves.length} of the $next newest looked at ($fetched read from a server)',
    );
    return saves;
  }
}
