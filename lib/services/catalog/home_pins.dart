import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/catalog/catalog_item.dart';
import '../base_shared_preferences_service.dart';
import '../../utils/app_logger.dart';
import '../trackers/trakt/trakt_client.dart';
import '../customisation/customisation_store.dart';
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

  /// Part-watched comfort-show episodes (Comfort's Carry on watching).
  static const String comfortCarryOn = 'comfort.carryon';

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

  /// A Watchlist page shelf (`films`, `tv`, `films.Horror`, `tv.other`…) of
  /// [source]'s watchlist; without a source, whichever watchlist the
  /// Watchlist page would show.
  /// A saved answer from the AI tab (its snapshot of picks).
  static String ai(String historyId) => 'ai:$historyId';

  static String watchlist(String shelfId, {CatalogSourceId? source}) =>
      source == null ? 'wl:$shelfId' : 'wl:${source.name}:$shelfId';
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

/// The user's Home layout, kept in the fork's local database (see
/// [CustomisationStore]) and moved between devices with Settings ▸ Backup &
/// transfer. One instance serves the whole app ([instance]).
///
/// The first time it runs on a device with an empty database it brings the
/// Home rows over once: from this device's earlier local copy, or else from
/// the private Trakt list "Plezy" that earlier versions saved to (read
/// only; that list is left as it is).
class HomePinsController extends ChangeNotifier {
  static const String listName = 'Plezy';
  static const String listSlug = 'plezy';
  static const String _legacyCacheKey = 'home_layout_cache_v2';
  static const String _v1CacheKey = 'home_layout_cache_v1';

  HomePinsController({Future<CustomisationStore>? store}) : _storeFuture = store;

  static HomePinsController? _instance;
  static HomePinsController get instance => _instance ??= HomePinsController();

  @visibleForTesting
  static set debugInstance(HomePinsController? controller) => _instance = controller;

  final Future<CustomisationStore>? _storeFuture;
  Future<CustomisationStore> get _store => _storeFuture ?? Customisation.store;

  TraktClient? _trakt;
  HomeLayout _layout = defaultHomeLayout;
  int _revision = 0;

  /// Whether the layout came from the database (or a migration) rather than
  /// the built-in default.
  bool _persisted = false;
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _writes = Future.value();

  HomeLayout get layout => _layout;
  List<HomeRowEntry> get rows => _layout.rows;

  /// Whether Home shows only the added rows.
  bool get curated => _layout.curated;
  bool get isLoaded => _loaded;

  bool contains(String id) => _layout.rows.any((r) => r.id == id);

  /// Whether the user has a Home layout of their own (saved, imported or
  /// brought over). Until then Home shows the servers' rows.
  bool get hasSavedLayout => _persisted;

  /// Trakt connected: rows saved there by earlier versions can be brought
  /// over if this device has none yet.
  void attachTrakt(TraktClient client) {
    if (identical(_trakt, client)) return;
    _trakt = client;
    if (_loaded && !_persisted) unawaited(_migrateFromTrakt());
  }

  /// Read the layout once (coalesced); [refresh] re-reads the database (after
  /// an import).
  Future<void> ensureLoaded({bool refresh = false}) {
    if (_loaded && !refresh) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final stored = await (await _store).readHomeLayout();
      if (stored != null) {
        _layout = (
          rows: [for (final r in stored.rows) (id: r.id, title: r.title, sources: r.sources)],
          curated: stored.curated,
        );
        _revision = stored.revision;
        _persisted = true;
      } else if (!_persisted) {
        await _migrateFromLocalCache();
      }
      _loaded = true;
      notifyListeners();
      if (!_persisted) await _migrateFromTrakt();
    } catch (e) {
      appLogger.w('Home layout: load failed', error: e);
      _loaded = true;
      notifyListeners();
    }
  }

  /// The local copy earlier versions kept beside their Trakt saves.
  Future<void> _migrateFromLocalCache() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final raw = prefs.getString(_legacyCacheKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is! Map) return;
      appLogger.i('Home layout: bringing rows over from the earlier local copy');
      await _replace(_layoutFromJson(decoded));
    } catch (e) {
      appLogger.w('Home layout: earlier local copy unreadable', error: e);
    }
  }

  /// The private Trakt list "Plezy" that earlier versions saved to (read
  /// only).
  Future<void> _migrateFromTrakt() async {
    final client = _trakt;
    if (client == null || _persisted) return;
    try {
      final lists = await client.getMyLists();
      final list =
          lists.where((l) => l.slug == listSlug).firstOrNull ?? lists.where((l) => l.name == listName).firstOrNull;
      final remote = parseHomeLayout(list?.description, titles: await _v1Titles());
      if (remote == null || _persisted) return;
      appLogger.i('Home layout: bringing ${remote.rows.length} rows over from the Trakt list "$listName"');
      await _replace(remote);
    } catch (e) {
      appLogger.w('Home layout: reading the Trakt list failed', error: e);
    }
  }

  Future<Map<String, String>> _v1Titles() async {
    final titles = <String, String>{};
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final raw = prefs.getString(_v1CacheKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map && decoded['titles'] is Map) {
        for (final entry in (decoded['titles'] as Map).entries) {
          if (entry.key is String && entry.value is String) {
            titles[HomeRowIds.traktLists(_v1HubId(entry.key as String))] = entry.value as String;
          }
        }
      }
    } catch (_) {}
    return titles;
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
    await _replace((rows: [..._layout.rows, ...fresh], curated: _layout.curated));
    return fresh.length;
  }

  Future<void> remove(Iterable<String> ids) async {
    await ensureLoaded();
    final drop = ids.toSet();
    if (!_layout.rows.any((r) => drop.contains(r.id))) return;
    await _replace((
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
    await _replace((rows: rows, curated: _layout.curated));
  }

  Future<void> setCurated(bool curated) async {
    await ensureLoaded();
    if (_layout.curated == curated) return;
    await _replace((rows: _layout.rows, curated: curated));
  }

  /// Apply [layout] at once, then save it; saves run one at a time in
  /// order, so the database always ends up with the latest layout.
  Future<void> _replace(HomeLayout layout) {
    _layout = layout;
    _revision++;
    _persisted = true;
    notifyListeners();
    final revision = _revision;
    final write = _writes.catchError((Object _) {}).then((_) async {
      await (await _store).writeHomeLayout(
        [for (final r in layout.rows) (id: r.id, title: r.title, sources: r.sources)],
        curated: layout.curated,
        revision: revision,
      );
    });
    _writes = write;
    return write;
  }
}
