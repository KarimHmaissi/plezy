import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/catalog/catalog_item.dart';
import '../../models/trakt/trakt_user_list.dart';
import '../base_shared_preferences_service.dart';
import '../../utils/app_logger.dart';
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

/// The layout in [description], or null when it has none. A first-version
/// description is migrated: Continue Watching, Pick back up, then its pins.
HomeLayout? parseHomeLayout(String? description, {Map<String, String> titles = const {}}) {
  if (description == null) return null;
  final match = _layoutMarker.firstMatch(description);
  if (match != null) {
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(match.group(1)!))));
      if (json is Map) return _layoutFromJson(json);
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
  return (rows: [...defaultHomeLayout.rows, ...pins], curated: true);
}

/// Whether [description] still needs rewriting in the current format.
bool isLegacyHomeLayout(String? description) =>
    description != null && !_layoutMarker.hasMatch(description) && _v1PinnedMarker.hasMatch(description);

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

Map<String, Object> _layoutToJson(HomeLayout layout) => {
  'v': 2,
  'c': layout.curated ? 1 : 0,
  'r': [
    for (final row in layout.rows) [row.id, row.title, if (row.sources.isNotEmpty) row.sources],
  ],
};

/// [description] with its settings line replaced by one for [layout]; other
/// lines are kept.
String writeHomeLayout(String? description, HomeLayout layout) {
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
  final encoded = base64Url.encode(utf8.encode(jsonEncode(_layoutToJson(layout)))).replaceAll('=', '');
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

/// The user's Home layout. Trakt (see [parseHomeLayout]) is the source of
/// truth; a local copy lets Home apply it immediately and offline. The
/// "Plezy" list is only created on the first change, and only if the
/// account has a free list slot.
class HomePinsController extends ChangeNotifier {
  static const String listName = 'Plezy';
  static const String listSlug = 'plezy';
  static const String _cacheKey = 'home_layout_cache_v2';
  static const String _v1CacheKey = 'home_layout_cache_v1';

  HomePinsController(this._client);

  final TraktClient _client;
  TraktUserList? _list;
  HomeLayout _layout = defaultHomeLayout;
  bool _loaded = false;
  Future<void>? _loading;
  bool _disposed = false;

  HomeLayout get layout => _layout;
  List<HomeRowEntry> get rows => _layout.rows;

  /// Whether Home shows only the added rows.
  bool get curated => _layout.curated;
  bool get isLoaded => _loaded;

  bool contains(String id) => _layout.rows.any((r) => r.id == id);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Read the layout once (coalesced); [refresh] forces a re-read so changes
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
      final parsed = parseHomeLayout(description, titles: v1Titles);
      if (parsed != null) _layout = parsed;
      _loaded = true;
      _notify();
      await _writeCache();
      // A first-version description is rewritten in the current format once.
      if (parsed != null && isLegacyHomeLayout(description)) await _save(parsed);
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
      await prefs.setString(_cacheKey, jsonEncode(_layoutToJson(_layout)));
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
    await _save((rows: [..._layout.rows, ...fresh], curated: _layout.curated));
    return fresh.length;
  }

  Future<void> remove(Iterable<String> ids) async {
    await ensureLoaded();
    final drop = ids.toSet();
    if (!_layout.rows.any((r) => drop.contains(r.id))) return;
    await _save((
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
    await _save((rows: rows, curated: _layout.curated));
  }

  Future<void> setCurated(bool curated) async {
    await ensureLoaded();
    if (_layout.curated == curated) return;
    await _save((rows: _layout.rows, curated: curated));
  }

  Future<void> _save(HomeLayout layout) async {
    final previous = _layout;
    _layout = layout;
    _notify();
    try {
      var list = _list;
      if (list == null) {
        // Creating the list uses one of the account's personal-list slots.
        final own = await _client.getMyLists();
        final existing =
            own.where((l) => l.slug == listSlug).firstOrNull ?? own.where((l) => l.name == listName).firstOrNull;
        if (existing != null) {
          list = existing;
        } else {
          final limit = await _client.getPersonalListLimit();
          if (limit != null && own.length >= limit) throw HomePinsListLimitException(limit);
          list = await _client.createMyList(listName, description: writeHomeLayout(null, layout));
          if (list == null) throw StateError('Trakt did not return the created list');
          _list = list;
          await _writeCache();
          return;
        }
      }
      final description = writeHomeLayout(list.description, layout);
      await _client.updateMyListDescription(list.traktId, description);
      _list = TraktUserList(traktId: list.traktId, slug: list.slug, name: list.name, description: description);
      await _writeCache();
    } catch (e) {
      _layout = previous;
      _notify();
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
