import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../media/media_kind.dart';

import '../../models/catalog/catalog_item.dart';
import '../../models/trakt/trakt_ids.dart';
import '../../models/trakt/trakt_user_list.dart';
import '../../utils/app_logger.dart';
import '../catalog/trakt_catalog_source.dart';
import '../customisation/customisation_store.dart';
import 'comfort_list_description.dart';

/// The user's comfort shows: the items of one private Trakt list (curated on
/// trakt.tv or here), re-read on every [load]. Which shows are out of the
/// Random episode mix is kept in the fork's local database (moved between
/// devices with Settings ▸ Backup & transfer). Earlier versions kept that in
/// the list's description (see [parsePausedTraktIds]); it's brought over
/// once and the description is no longer written.
///
/// Each Trakt load also keeps the list in the local database
/// ([showsCacheKey]), so a phone mirroring this device sees the same shows
/// without Trakt of its own. With no Trakt source ([ComfortShowsController.cached])
/// the controller reads that copy: read-only, but Random episode and pausing
/// work.
class ComfortShowsController extends ChangeNotifier {
  static const String listName = 'Comfort Shows';
  static const String listSlug = 'comfort-shows';

  ComfortShowsController(TraktCatalogSource this._source, {Future<CustomisationStore>? store}) : _storeFuture = store {
    hostSource = _source;
  }

  /// The Trakt source this device last used for Comfort: a host applies a
  /// mirroring phone's list edits through it.
  static TraktCatalogSource? hostSource;

  /// Sends a list edit to the connected TV/Mac (set by the phone's mirror);
  /// false when not connected.
  static bool Function(Map<String, Object?> op)? sendMirrorEdit;
  static bool Function()? mirrorCanEdit;

  /// The last list a Trakt-connected device saw (this device's, or the
  /// mirrored TV/Mac's on a phone).
  ComfortShowsController.cached({Future<CustomisationStore>? store}) : _source = null, _storeFuture = store;

  static const String showsCacheKey = 'comfort.shows';

  static const String _migratedKey = 'comfort.pausedMigrated';

  final TraktCatalogSource? _source;

  /// Whether this controller reads Trakt itself (false: the cached copy).
  bool get isLive => _source != null;

  /// Whether shows can be added or removed: with Trakt here, or on a phone
  /// connected to the TV/Mac that has it (the edit goes there).
  bool get canEditList => _source != null || (Customisation.isMirror && (mirrorCanEdit?.call() ?? false));
  final Future<CustomisationStore>? _storeFuture;
  Future<CustomisationStore> get _store => _storeFuture ?? Customisation.store;
  TraktUserList? _list;
  List<CatalogItem> _shows = const [];
  Set<int> _paused = {};
  bool _loading = false;
  bool _loaded = false;
  Object? _error;
  bool _disposed = false;

  List<CatalogItem> get shows => _shows;
  bool get isLoading => _loading;
  bool get isLoaded => _loaded;
  Object? get error => _error;

  bool isPaused(CatalogItem show) => _paused.contains(show.ids.trakt);

  /// Shows in the random-episode pool, in list order.
  List<CatalogItem> get activeShows => [
    for (final show in _shows)
      if (!isPaused(show)) show,
  ];

  /// Paused shows, in list order.
  List<CatalogItem> get pausedShows => [
    for (final show in _shows)
      if (isPaused(show)) show,
  ];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Fetch the list and its shows, creating the list the first time unless
  /// [createIfMissing] is false (read-only callers such as Home).
  Future<void> load({bool createIfMissing = true}) async {
    _loading = true;
    _error = null;
    _notify();
    try {
      final source = _source;
      if (source == null) {
        final store = await _store;
        _shows = decodeShows(await store.readSetting(showsCacheKey));
        final onList = {for (final show in _shows) ?show.ids.trakt};
        _paused = (await store.readComfortPaused()).keys.toSet().intersection(onList);
        _loaded = true;
        return;
      }
      final client = source.client;
      final lists = await client.getMyLists();
      // Reuse the user's existing list (matched by slug, then name); create
      // one only when neither exists.
      var list =
          lists.where((l) => l.slug == listSlug).firstOrNull ?? lists.where((l) => l.name == listName).firstOrNull;
      if (list == null && !createIfMissing) {
        _shows = const [];
        _paused = {};
        _loaded = true;
        return;
      }
      list ??= await client.createMyList(listName, description: '');
      if (list == null) throw StateError('Trakt did not return the created list');
      final shows = source.showsFromListEntries(await client.getMyListShows(list.traktId));
      final onList = {for (final show in shows) ?show.ids.trakt};
      _list = list;
      _shows = shows;
      final store = await _store;
      if (await store.readSetting(_migratedKey) == null) {
        final fromDescription = parsePausedTraktIds(list.description);
        await store.writeComfortPaused({
          for (final show in shows)
            if (show.ids.trakt case final id? when fromDescription.contains(id)) id: show.title,
        });
        await store.writeSetting(_migratedKey, '1');
      }
      _paused = (await store.readComfortPaused()).keys.toSet().intersection(onList);
      // Keep a copy for phones mirroring this device (never written from a
      // phone's mirror, which would overwrite the TV's).
      if (!Customisation.isMirror) {
        final encoded = encodeShows(shows);
        if (await store.readSetting(showsCacheKey) != encoded) await store.writeSetting(showsCacheKey, encoded);
      }
      _loaded = true;
    } catch (e) {
      appLogger.w('Comfort shows: load failed', error: e);
      _error = e;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Move [show] in or out of the random-episode pool. Updates optimistically
  /// and rolls back if the save fails.
  Future<void> setPaused(CatalogItem show, bool paused) async {
    final id = show.ids.trakt;
    if (id == null || (_list == null && _source != null) || isPaused(show) == paused) return;
    final previous = _paused;
    _paused = paused ? {..._paused, id} : ({..._paused}..remove(id));
    _notify();
    try {
      await _savePaused();
    } catch (e) {
      _paused = previous;
      _notify();
      rethrow;
    }
  }

  Future<void> _savePaused() async {
    await (await _store).writeComfortPaused({
      for (final show in _shows)
        if (show.ids.trakt case final id? when _paused.contains(id)) id: show.title,
    });
  }

  Future<void> addShow(CatalogItem show) async {
    if (_source == null) return _sendEdit('add', show);
    final list = _list;
    if (list == null) return;
    await _source.client.addShowsToMyList(list.traktId, [_traktIds(show)]);
    await load();
  }

  Future<void> removeShow(CatalogItem show) async {
    if (_source == null) return _sendEdit('remove', show);
    final list = _list;
    if (list == null) return;
    await _source.client.removeShowsFromMyList(list.traktId, [_traktIds(show)]);
    if (show.ids.trakt case final id? when _paused.contains(id)) {
      _paused = {..._paused}..remove(id);
      _shows = [
        for (final s in _shows)
          if (s.ids.trakt != id) s,
      ];
      await _savePaused();
    }
    await load();
  }

  /// Phone: ask the TV/Mac to change its list; its new snapshot updates
  /// this one. Optimistic, like the other mirrored edits.
  Future<void> _sendEdit(String action, CatalogItem show) async {
    final sent =
        sendMirrorEdit?.call({'op': 'comfortList', 'action': action, 'show': _encodeShow(show)}) ?? false;
    if (!sent) throw StateError('Not connected to the TV');
    _shows = action == 'add'
        ? [..._shows, show]
        : [
            for (final s in _shows)
              if (s.identityKey != show.identityKey) s,
          ];
    _notify();
  }

  /// Host: apply a mirroring phone's list edit through Trakt. The reload
  /// saves the new copy, which goes back to the phone in the next snapshot.
  static Future<void> applyMirrorEdit(Map<String, dynamic> op) async {
    final source = hostSource;
    final show = decodeShows(json.encode([op['show']])).firstOrNull;
    if (source == null || show == null) {
      appLogger.w('Comfort: a phone edit arrived but Trakt is not connected here');
      return;
    }
    final controller = ComfortShowsController(source);
    try {
      await controller.load();
      if (op['action'] == 'add') {
        await controller.addShow(show);
      } else if (op['action'] == 'remove') {
        final match = controller.shows.where((s) => _sameShow(s, show)).firstOrNull;
        if (match != null) await controller.removeShow(match);
      }
    } finally {
      controller.dispose();
    }
  }

  static bool _sameShow(CatalogItem a, CatalogItem b) =>
      (a.ids.trakt != null && a.ids.trakt == b.ids.trakt) ||
      (a.ids.tmdb != null && a.ids.tmdb == b.ids.tmdb) ||
      (a.ids.tvdb != null && a.ids.tvdb == b.ids.tvdb) ||
      (a.ids.imdb != null && a.ids.imdb == b.ids.imdb);

  /// The fields Comfort needs from each show (ids to match the library,
  /// title, year, poster), as stored under [showsCacheKey].
  @visibleForTesting
  static String encodeShows(List<CatalogItem> shows) => json.encode([for (final s in shows) _encodeShow(s)]);

  static Map<String, Object?> _encodeShow(CatalogItem s) => {
    'title': s.title,
    'year': ?s.year,
    'poster': ?s.posterUrl,
    'trakt': ?s.ids.trakt,
    'slug': ?s.ids.slug,
    'imdb': ?s.ids.imdb,
    'tmdb': ?s.ids.tmdb,
    'tvdb': ?s.ids.tvdb,
  };

  static List<CatalogItem> decodeShows(String? encoded) {
    if (encoded == null) return const [];
    try {
      return [
        for (final m in (json.decode(encoded) as List).whereType<Map>())
          CatalogItem(
            source: CatalogSourceId.trakt,
            kind: MediaKind.show,
            title: m['title'] as String? ?? '',
            year: m['year'] as int?,
            posterUrl: m['poster'] as String?,
            ids: CatalogItemIds(
              trakt: m['trakt'] as int?,
              slug: m['slug'] as String?,
              imdb: m['imdb'] as String?,
              tmdb: m['tmdb'] as int?,
              tvdb: m['tvdb'] as int?,
            ),
          ),
      ];
    } catch (e) {
      appLogger.w('Comfort shows: cached list unreadable', error: e);
      return const [];
    }
  }

  static TraktIds _traktIds(CatalogItem show) => TraktIds(
    trakt: show.ids.trakt,
    slug: show.ids.slug,
    imdb: show.ids.imdb,
    tmdb: show.ids.tmdb,
    tvdb: show.ids.tvdb,
  );

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
