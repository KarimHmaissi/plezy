import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/catalog/catalog_item.dart';
import '../../models/trakt/trakt_user_list.dart';
import '../base_shared_preferences_service.dart';
import '../../utils/app_logger.dart';
import '../trackers/tracker_exceptions.dart';
import '../trackers/trakt/trakt_client.dart';
import 'catalog_source.dart';

/// One row the user added to Home: a row id (see [HomeRowIds]), its title,
/// and for Plex rows where to fetch it (`serverId|hub key`, one per server or
/// library the row merges).
typedef HomeRowEntry = ({String id, String title, List<String> sources});

/// The user's Home: the rows they added, in their order, and whether Home
/// shows only those ([curated]) or also every other row the servers offer.
typedef HomeLayout = ({List<HomeRowEntry> rows, bool curated});

/// Row ids. Any grouping of titles in Plezy maps to one, so it can be added
/// to Home from wherever it's shown and fetched again from Home.
abstract final class HomeRowIds {
  static const String continueWatching = 'cw';
  static const String pickBackUp = 'pb';
  static const String comfort = 'comfort';

  /// A Trakt Lists hub (chart or list). Lists are addressed by id alone, so
  /// the same list pinned from anywhere is one row.
  static String traktLists(String hubId) {
    final parts = hubId.split(':');
    if (parts.length == 3 && parts[0] == 'list' && int.tryParse(parts[2]) != null) {
      return 'tl:$anyOwnerListPrefix${parts[2]}';
    }
    return 'tl:$hubId';
  }

  static String catalogRow(CatalogSourceId source, CatalogRowId row) => 'cat:${source.name}:${row.name}';
  static String catalogHub(CatalogSourceId source, String hubId) => 'cath:${source.name}:$hubId';

  /// A Plex row, by title: the same row from several servers or libraries
  /// ("Oh, The Horror!" from five movie libraries) is one row.
  static String plex(String title) => 'px:${normalizeRowTitle(title)}';

  /// A Watchlist page shelf: `films`, `tv`, `films.Horror`, `tv.other`…
  static String watchlist(String shelfId) => 'wl:$shelfId';
}

/// Hub id prefix for a Trakt list addressed by its id alone (`/lists/{id}`).
const String anyOwnerListPrefix = 'list:*:';

/// Titles that differ only in case, punctuation or spacing name the same row
/// ("Recently Added in *Movies" on one server, "… in Movies" on another).
String normalizeRowTitle(String title) =>
    title.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

const HomeLayout defaultHomeLayout = (
  rows: [
    (id: HomeRowIds.continueWatching, title: 'Continue Watching', sources: <String>[]),
    (id: HomeRowIds.pickBackUp, title: 'Pick back up', sources: <String>[]),
  ],
  curated: true,
);

/// Stored in the description of the private Trakt list "Plezy" (one list
/// slot; its items are reserved for a future shortlist), so Home follows the
/// user across devices without a server of our own:
///
///     Plezy app settings [plezy:home2=<base64url JSON>]
///
/// Only the bracketed marker is read; any other description text is kept.
final RegExp _layoutMarker = RegExp(r'\[plezy:home2=([A-Za-z0-9_-]*)\]');

/// First-version markers: pinned Trakt Lists hubs, and hidden rows (dropped:
/// Home now only shows what was added).
final RegExp _v1PinnedMarker = RegExp(r'\[plezy:home=([^\]]*)\]');
final RegExp _v1HiddenMarker = RegExp(r'\[plezy:hide=([^\]]*)\]');
const String _settingsLine = 'Plezy app settings';

const Map<String, String> _v1ChartCodes = {
  'bo': 'chart:boxoffice',
  'wm': 'chart:watched:movies',
  'ws': 'chart:watched:shows',
  'am': 'chart:anticipated:movies',
  'as': 'chart:anticipated:shows',
};

String _v1HubId(String code) => _v1ChartCodes[code] ?? (int.tryParse(code) != null ? '$anyOwnerListPrefix$code' : code);

/// The layout in [description] and the revision it was saved at, or null
/// when it has none. A first-version description is migrated: Continue
/// Watching, Pick back up, then its pins (revision 0).
({HomeLayout layout, int revision})? parseHomeLayoutWithRevision(
  String? description, {
  Map<String, String> titles = const {},
}) {
  if (description == null) return null;
  final match = _layoutMarker.firstMatch(description);
  if (match != null) {
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(match.group(1)!))));
      if (json is Map) return (layout: _layoutFromJson(json), revision: _revisionOf(json));
    } catch (e) {
      appLogger.w('Home layout: unreadable marker', error: e);
    }
    return null;
  }
  final v1 = _v1PinnedMarker.firstMatch(description);
  if (v1 == null) return null;
  final seen = <String>{};
  final pins = <HomeRowEntry>[];
  for (final raw in v1.group(1)!.split(',')) {
    final code = raw.trim();
    if (code.isEmpty) continue;
    final hubId = _v1HubId(code);
    final id = HomeRowIds.traktLists(hubId);
    if (!seen.add(id)) continue;
    pins.add((id: id, title: titles[id] ?? hubId, sources: const []));
  }
  return (layout: (rows: [...defaultHomeLayout.rows, ...pins], curated: true), revision: 0);
}

/// The layout in [description], or null when it has none.
HomeLayout? parseHomeLayout(String? description, {Map<String, String> titles = const {}}) =>
    parseHomeLayoutWithRevision(description, titles: titles)?.layout;

/// Whether [description] still needs rewriting in the current format.
bool isLegacyHomeLayout(String? description) =>
    description != null && !_layoutMarker.hasMatch(description) && _v1PinnedMarker.hasMatch(description);

int _revisionOf(Map json) => json['n'] is int ? json['n'] as int : 0;

HomeLayout _layoutFromJson(Map json) {
  final rows = <HomeRowEntry>[];
  final seen = <String>{};
  for (final raw in json['r'] is List ? json['r'] as List : const []) {
    if (raw is! List || raw.isEmpty || raw[0] is! String) continue;
    final id = raw[0] as String;
    if (!seen.add(id)) continue;
    rows.add((
      id: id,
      title: raw.length > 1 && raw[1] is String ? raw[1] as String : id,
      sources: raw.length > 2 && raw[2] is List ? (raw[2] as List).whereType<String>().toList() : const [],
    ));
  }
  return (rows: rows, curated: json['c'] != 0);
}

Map<String, Object> _layoutToJson(HomeLayout layout, {int revision = 0}) => {
  'v': 2,
  'n': revision,
  'c': layout.curated ? 1 : 0,
  'r': [
    for (final row in layout.rows) [row.id, row.title, if (row.sources.isNotEmpty) row.sources],
  ],
};

/// [description] with its settings line replaced by one for [layout]; other
/// lines are kept.
String writeHomeLayout(String? description, HomeLayout layout, {int revision = 0}) {
  final kept = [
    for (final line in (description ?? '').split('\n'))
      if (!_layoutMarker.hasMatch(line) &&
          !_v1PinnedMarker.hasMatch(line) &&
          !_v1HiddenMarker.hasMatch(line) &&
          line.trim() != _settingsLine)
        line,
  ];
  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  final encoded = base64Url
      .encode(utf8.encode(jsonEncode(_layoutToJson(layout, revision: revision))))
      .replaceAll('=', '');
  kept.add('$_settingsLine [plezy:home2=$encoded]');
  return kept.join('\n');
}

/// Thrown when saving needs a new Trakt list but the account is at its
/// personal-list limit.
class HomePinsListLimitException implements Exception {
  final int limit;
  const HomePinsListLimitException(this.limit);
  @override
  String toString() => 'Trakt personal list limit reached ($limit)';
}

/// The user's Home layout. Every change is kept on this device first (so a
/// change is never lost to a slow or failed save) and then synced to the
/// description of the private Trakt list "Plezy" (see [parseHomeLayout]),
/// one write at a time, retrying when Trakt rate-limits. Each save carries a
/// revision number, so an older copy read back from Trakt (its list reads
/// can lag behind writes) never replaces newer local changes; a newer one,
/// saved on another device, does. The list is only created on the first
/// change, and only if the account has a free list slot.
class HomePinsController extends ChangeNotifier {
  static const String listName = 'Plezy';
  static const String listSlug = 'plezy';
  static const String _cacheKey = 'home_layout_cache_v2';
  static const String _v1CacheKey = 'home_layout_cache_v1';
  static const int _maxRateLimitRetries = 5;

  HomePinsController(this._client, {@visibleForTesting Duration Function(int? retryAfterSeconds)? retryDelay})
    : _retryDelay = retryDelay ?? ((seconds) => Duration(seconds: (seconds ?? 2).clamp(1, 30)));

  final TraktClient _client;
  final Duration Function(int? retryAfterSeconds) _retryDelay;
  TraktUserList? _list;
  HomeLayout _layout = defaultHomeLayout;
  int _revision = 0;

  /// Local changes Trakt doesn't have yet.
  bool _dirty = false;
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _syncChain = Future.value();
  bool _disposed = false;

  HomeLayout get layout => _layout;
  List<HomeRowEntry> get rows => _layout.rows;

  /// Whether Home shows only the added rows.
  bool get curated => _layout.curated;
  bool get isLoaded => _loaded;

  /// Whether some changes are still waiting to reach Trakt.
  bool get hasUnsyncedChanges => _dirty;

  bool contains(String id) => _layout.rows.any((r) => r.id == id);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Read the layout once (coalesced); [refresh] re-reads Trakt so changes
  /// made on another device show up.
  Future<void> ensureLoaded({bool refresh = false}) {
    if (_loaded && !refresh) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final v1Titles = <String, String>{};
    if (!_loaded) await _readCache(v1Titles);
    try {
      final lists = await _client.getMyLists();
      _list = lists.where((l) => l.slug == listSlug).firstOrNull ?? lists.where((l) => l.name == listName).firstOrNull;
      final description = _list?.description;
      final remote = parseHomeLayoutWithRevision(description, titles: v1Titles);
      // Trakt's copy wins only when it's at least as new and nothing local
      // is waiting to be synced.
      if (remote != null && !_dirty && remote.revision >= _revision) {
        _layout = remote.layout;
        _revision = remote.revision;
      }
      _loaded = true;
      _notify();
      // Push local changes Trakt is missing (or an older copy, or the
      // first-version format) back up.
      if (_dirty || (remote != null && remote.revision < _revision) || isLegacyHomeLayout(description)) {
        _dirty = true;
      }
      await _writeCache();
      if (_dirty) await _scheduleSync().catchError((Object _) {});
    } catch (e) {
      appLogger.w('Home layout: load failed', error: e);
    }
  }

  Future<void> _readCache(Map<String, String> v1Titles) async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final raw = prefs.getString(_cacheKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _layout = _layoutFromJson(decoded);
          _revision = _revisionOf(decoded);
          _dirty = decoded['dirty'] == true;
          _loaded = true;
          _notify();
        }
        return;
      }
      // Titles remembered by the first version, for migrating its pins.
      final v1 = prefs.getString(_v1CacheKey);
      final decoded = v1 == null ? null : jsonDecode(v1);
      if (decoded is Map && decoded['titles'] is Map) {
        for (final entry in (decoded['titles'] as Map).entries) {
          if (entry.key is String && entry.value is String) {
            v1Titles[HomeRowIds.traktLists(_v1HubId(entry.key as String))] = entry.value as String;
          }
        }
      }
    } catch (e) {
      appLogger.d('Home layout: cache unreadable', error: e);
    }
  }

  Future<void> _writeCache() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(_cacheKey, jsonEncode({..._layoutToJson(_layout, revision: _revision), 'dirty': _dirty}));
    } catch (e) {
      appLogger.d('Home layout: cache write failed', error: e);
    }
  }

  /// Add [rows] to the end of Home; rows already on it are skipped. Returns
  /// how many were added.
  Future<int> add(List<HomeRowEntry> rows) async {
    await ensureLoaded();
    final fresh = <HomeRowEntry>[];
    for (final row in rows) {
      if (!contains(row.id) && !fresh.any((r) => r.id == row.id)) fresh.add(row);
    }
    if (fresh.isEmpty) return 0;
    await _change((rows: [..._layout.rows, ...fresh], curated: _layout.curated));
    return fresh.length;
  }

  Future<void> remove(Iterable<String> ids) async {
    await ensureLoaded();
    final drop = ids.toSet();
    if (!_layout.rows.any((r) => drop.contains(r.id))) return;
    await _change((
      rows: [
        for (final row in _layout.rows)
          if (!drop.contains(row.id)) row,
      ],
      curated: _layout.curated,
    ));
  }

  /// Move row [id] by [delta] places.
  Future<void> move(String id, int delta) async {
    final rows = [..._layout.rows];
    final from = rows.indexWhere((r) => r.id == id);
    if (from < 0) return;
    final to = (from + delta).clamp(0, rows.length - 1);
    if (to == from) return;
    rows.insert(to, rows.removeAt(from));
    await _change((rows: rows, curated: _layout.curated));
  }

  Future<void> setCurated(bool curated) async {
    await ensureLoaded();
    if (_layout.curated == curated) return;
    await _change((rows: _layout.rows, curated: curated));
  }

  /// Apply [layout] locally (kept even if Trakt can't be reached), then sync.
  /// Only a missing list slot is reported; other sync failures retry later.
  Future<void> _change(HomeLayout layout) async {
    _layout = layout;
    _revision++;
    _dirty = true;
    _notify();
    await _writeCache();
    await _scheduleSync();
  }

  /// Queue a sync behind any running one, so writes reach Trakt one at a
  /// time and the last one always carries the latest layout.
  Future<void> _scheduleSync() {
    final next = _syncChain.catchError((Object _) {}).then((_) => _sync());
    _syncChain = next;
    return next;
  }

  Future<void> _sync() async {
    var rateLimited = 0;
    while (_dirty && !_disposed) {
      final revision = _revision;
      final layout = _layout;
      try {
        await _write(layout, revision);
        if (_revision == revision) _dirty = false;
        await _writeCache();
      } on TrackerRateLimitException catch (e) {
        if (++rateLimited > _maxRateLimitRetries) {
          appLogger.w('Home layout: still rate-limited, will sync later');
          return;
        }
        await Future<void>.delayed(_retryDelay(e.retryAfterSeconds));
      } on HomePinsListLimitException {
        rethrow;
      } catch (e) {
        appLogger.w('Home layout: sync failed, kept on this device', error: e);
        return;
      }
    }
  }

  Future<void> _write(HomeLayout layout, int revision) async {
    var list = _list;
    if (list == null) {
      // Creating the list uses one of the account's personal-list slots.
      final own = await _client.getMyLists();
      list = own.where((l) => l.slug == listSlug).firstOrNull ?? own.where((l) => l.name == listName).firstOrNull;
      if (list == null) {
        final limit = await _client.getPersonalListLimit();
        if (limit != null && own.length >= limit) throw HomePinsListLimitException(limit);
        list = await _client.createMyList(listName, description: writeHomeLayout(null, layout, revision: revision));
        if (list == null) throw StateError('Trakt did not return the created list');
        _list = list;
        return;
      }
    }
    final description = writeHomeLayout(list.description, layout, revision: revision);
    await _client.updateMyListDescription(list.traktId, description);
    _list = TraktUserList(traktId: list.traktId, slug: list.slug, name: list.name, description: description);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
