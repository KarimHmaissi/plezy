import 'package:flutter/foundation.dart';

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
class ComfortShowsController extends ChangeNotifier {
  static const String listName = 'Comfort Shows';
  static const String listSlug = 'comfort-shows';

  ComfortShowsController(this._source, {Future<CustomisationStore>? store}) : _storeFuture = store;

  static const String _migratedKey = 'comfort.pausedMigrated';

  final TraktCatalogSource _source;
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
      final client = _source.client;
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
      final shows = _source.showsFromListEntries(await client.getMyListShows(list.traktId));
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
    final list = _list;
    if (id == null || list == null || isPaused(show) == paused) return;
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
    final list = _list;
    if (list == null) return;
    await _source.client.addShowsToMyList(list.traktId, [_traktIds(show)]);
    await load();
  }

  Future<void> removeShow(CatalogItem show) async {
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
