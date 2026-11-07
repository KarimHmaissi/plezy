import 'dart:async';
import 'dart:convert';

import '../../media/media_item.dart';
import 'reel_store.dart';

/// Where a card's art and text come from: the app's server seam, kept as
/// narrow as `ReelServers` so the Reel never imports a server client.
abstract interface class ReelMetadataSource {
  /// The cache namespace for [serverId] (one per signed-in profile), or
  /// null when the app has no client for it.
  String? scope(String serverId);

  /// The app's own cached item for [ratingKey] when its row was written
  /// within [maxAge] (any age when null). Never reads the network.
  Future<MediaItem?> cached(String serverId, String ratingKey, {Duration? maxAge});

  /// One lean network read of the item (no file checks, no stream detail):
  /// its raw JSON, or null when the server has no such item. Throws when it
  /// couldn't be read. Never writes the app's shared metadata cache.
  Future<Map<String, dynamic>?> lean(String serverId, String ratingKey);

  /// The item a [lean] row describes.
  MediaItem parse(String serverId, Map<String, dynamic> json);
}

/// A card's metadata, cache-first (plan V2-03): the clip never waits for it,
/// and a guest server is asked at most one Reel metadata read at a time.
///
/// 1. The app's cached row, when one was written within [maxAge].
/// 2. The Reel's own lean row in reelCache, within [maxAge].
/// 3. One lean read, kept in reelCache only. The shared
///    `/library/metadata/{id}` row stays the app's: the file-info and play
///    paths would take a thin row there as incomplete and read it again.
///
/// When the read fails, an older row of either kind is better than none.
class ReelMetadata {
  ReelMetadata({required this.source, required this.store});

  final ReelMetadataSource source;
  final ReelStore store;

  /// How long a cached row is shown without asking the server again.
  static const Duration maxAge = Duration(days: 7);

  /// The Reel's own row for an item (per profile namespace).
  static String key(String scope, String ratingKey) => 'meta:$scope:$ratingKey';

  /// Per server, the tail of its queue of reads.
  final Map<String, Future<void>> _lanes = {};

  Future<MediaItem?> item(String serverId, String ratingKey) async {
    final scope = source.scope(serverId);
    if (scope == null) return null;
    final shared = await source.cached(serverId, ratingKey, maxAge: maxAge);
    if (shared != null) return shared;
    final k = key(scope, ratingKey);
    final kept = _parse(serverId, await store.cached(k, ttl: maxAge));
    if (kept != null) return kept;
    final Map<String, dynamic>? json;
    try {
      json = await _inLane(serverId, () => source.lean(serverId, ratingKey));
    } catch (_) {
      final stale = await source.cached(serverId, ratingKey) ?? _parse(serverId, await store.cached(k));
      if (stale != null) return stale;
      rethrow;
    }
    if (json == null) return null;
    await store.cache(k, jsonEncode(json));
    return source.parse(serverId, json);
  }

  /// The item from the caches alone (V2-14's warm start, which reads no
  /// server): the app's cached row, else the Reel's own row, of any age.
  /// Null when neither has it.
  Future<MediaItem?> cachedItem(String serverId, String ratingKey) async {
    final scope = source.scope(serverId);
    if (scope == null) return null;
    return await source.cached(serverId, ratingKey) ?? _parse(serverId, await store.cached(key(scope, ratingKey)));
  }

  MediaItem? _parse(String serverId, String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? source.parse(serverId, json) : null;
    } catch (_) {
      return null;
    }
  }

  /// Runs [read] after every earlier read for [serverId] has settled: one
  /// Reel metadata read in flight per server (§9). Other servers don't wait.
  Future<T> _inLane<T>(String serverId, Future<T> Function() read) {
    final before = _lanes[serverId] ?? Future<void>.value();
    final run = before.then((_) => read());
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _lanes[serverId] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_lanes[serverId], tail)) _lanes.remove(serverId);
      }),
    );
    return run;
  }
}
