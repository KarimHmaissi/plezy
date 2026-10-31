import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/catalog/catalog_item.dart';
import '../../utils/app_logger.dart';
import '../base_shared_preferences_service.dart';
import 'catalog_source.dart';

/// Genres looked up for watchlist titles, persisted so a reopened Watchlist
/// page groups instantly instead of re-fetching every title.
///
/// Purely an optimisation: entries are keyed by [CatalogItem.identityKey],
/// expire after [maxAge], and a title with no fresh entry is always fetched.
class WatchlistGenreCache {
  static const String prefsKey = 'watchlist_genre_cache_v1';
  static const Duration maxAge = Duration(days: 7);

  WatchlistGenreCache(this._entries, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Map<String, ({List<String> genres, DateTime fetchedAt})> _entries;
  final DateTime Function() _now;
  bool _dirty = false;

  static Future<WatchlistGenreCache> load() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    return WatchlistGenreCache(_decode(prefs.getString(prefsKey)));
  }

  static Map<String, ({List<String> genres, DateTime fetchedAt})> _decode(String? raw) {
    final entries = <String, ({List<String> genres, DateTime fetchedAt})>{};
    if (raw == null) return entries;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return entries;
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final genres = value['g'];
        final at = value['t'];
        if (genres is! List || at is! int) return;
        entries[key] = (genres: [for (final g in genres) ?(g is String ? g : null)], fetchedAt: _fromMs(at));
      });
    } catch (e) {
      appLogger.w('Watchlist genre cache unreadable, starting fresh', error: e);
    }
    return entries;
  }

  static DateTime _fromMs(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  /// Fresh cached genres for [key], or null when missing or expired.
  List<String>? lookup(String key) {
    final entry = _entries[key];
    if (entry == null || _now().difference(entry.fetchedAt) > maxAge) return null;
    return entry.genres;
  }

  void store(String key, List<String> genres) {
    _entries[key] = (genres: genres, fetchedAt: _now());
    _dirty = true;
  }

  Future<void> save([SharedPreferencesWithCache? preferences]) async {
    if (!_dirty) return;
    final now = _now();
    _entries.removeWhere((_, entry) => now.difference(entry.fetchedAt) > maxAge);
    final prefs = preferences ?? await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(
      prefsKey,
      jsonEncode({
        for (final MapEntry(:key, :value) in _entries.entries)
          key: {'g': value.genres, 't': value.fetchedAt.millisecondsSinceEpoch},
      }),
    );
    _dirty = false;
  }
}

/// Resolve every watchlist title's genres, keyed by the item itself (an
/// identity map: titles without ids share an [CatalogItem.identityKey]).
///
/// Titles whose list entry already carries genres use those. The rest come
/// from [cache] when fresh, otherwise from [lookup], [concurrency] at a time.
/// A failed or impossible lookup leaves the title out of the result (it
/// groups under "Other") and is not cached, so the next load retries it.
/// Titles without comparable ids are fetched but never cached.
Future<Map<CatalogItem, List<String>>> resolveWatchlistGenres(
  Iterable<CatalogItem> items, {
  required CatalogGenreLookup? lookup,
  required WatchlistGenreCache cache,
  int concurrency = 6,
}) async {
  final result = Map<CatalogItem, List<String>>.identity();
  final pending = <CatalogItem>[];
  for (final item in items) {
    final key = item.identityKey;
    final listed = item.genres;
    if (listed != null && listed.isNotEmpty) {
      result[item] = listed;
      continue;
    }
    final cached = item.ids.canonicalKey == null ? null : cache.lookup(key);
    if (cached != null) {
      result[item] = cached;
    } else if (lookup != null) {
      pending.add(item);
    }
  }
  if (lookup == null || pending.isEmpty) return result;

  var next = 0;
  var failures = 0;
  Future<void> worker() async {
    while (next < pending.length) {
      final item = pending[next++];
      try {
        final genres = await lookup.fetchGenres(item);
        if (genres == null) continue;
        result[item] = genres;
        if (item.ids.canonicalKey != null) cache.store(item.identityKey, genres);
      } catch (e) {
        failures++;
        appLogger.d('Watchlist genre lookup failed for ${item.title}', error: e);
      }
    }
  }

  await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  if (failures > 0) appLogger.w('Watchlist: $failures of ${pending.length} genre lookups failed');
  return result;
}
