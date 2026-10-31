import 'package:flutter/foundation.dart';

import '../../models/catalog/catalog_item.dart';
import '../../models/trakt/trakt_ids.dart';
import '../../models/trakt/trakt_user_list.dart';
import '../../utils/app_logger.dart';
import '../catalog/trakt_catalog_source.dart';
import 'comfort_list_description.dart';

/// The user's comfort shows, backed by one private Trakt list.
///
/// The list's items are the shows; its description records which are paused
/// (see [parsePausedTraktIds]). Both are re-read on every [load], so changes
/// made on trakt.tv or another device show up the next time the page loads.
class ComfortShowsController extends ChangeNotifier {
  static const String listName = 'Comfort Shows';
  static const String listSlug = 'comfort-shows';

  ComfortShowsController(this._source);

  final TraktCatalogSource _source;
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
      _paused = parsePausedTraktIds(list.description).intersection(onList);
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
  /// and rolls back if Trakt rejects the change.
  Future<void> setPaused(CatalogItem show, bool paused) async {
    final id = show.ids.trakt;
    final list = _list;
    if (id == null || list == null || isPaused(show) == paused) return;
    final previous = _paused;
    _paused = paused ? {..._paused, id} : ({..._paused}..remove(id));
    _notify();
    try {
      await _savePaused(list);
    } catch (e) {
      _paused = previous;
      _notify();
      rethrow;
    }
  }

  Future<void> _savePaused(TraktUserList list) async {
    final description = writePausedTraktIds(list.description, {
      for (final show in _shows)
        if (show.ids.trakt case final id? when _paused.contains(id)) id: show.title,
    });
    await _source.client.updateMyListDescription(list.traktId, description);
    _list = TraktUserList(traktId: list.traktId, slug: list.slug, name: list.name, description: description);
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
      await _savePaused(list);
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
