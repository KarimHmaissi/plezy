import 'package:flutter/foundation.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_kind.dart';
import '../../models/catalog/catalog_item.dart';
import '../../models/trakt/trakt_catalog_entry.dart';
import '../../models/trakt/trakt_user_list.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../comfort/comfort_shows_controller.dart';
import '../trackers/tracker_page.dart';
import '../trackers/trakt/trakt_client.dart';
import '../trackers/trakt/trakt_constants.dart';
import 'catalog_source.dart';
import 'trakt_catalog_source.dart';

/// Explore's "Trakt Lists" source: Trakt charts that change on their own
/// (Box Office, Most Watched This Week, Most Anticipated), then the lists the
/// user has liked on Trakt (newest like first), then their own lists.
///
/// Every row is a provider hub, so Explore renders them like Plex Discover's
/// shelves with View all. Items are plain Trakt catalog items, so detail,
/// library matching and the watchlist all go through [TraktCatalogSource].
class TraktListsCatalogSource implements CatalogSource, CatalogHubSource {
  TraktListsCatalogSource(this._trakt);

  final TraktCatalogSource _trakt;

  TraktClient get _client => _trakt.client;

  /// The wrapped Trakt source (detail, search, watchlist).
  TraktCatalogSource get trakt => _trakt;

  static const String _boxOffice = 'chart:boxoffice';
  static const String _watchedMovies = 'chart:watched:movies';
  static const String _watchedShows = 'chart:watched:shows';
  static const String _anticipatedMovies = 'chart:anticipated:movies';
  static const String _anticipatedShows = 'chart:anticipated:shows';

  /// Hub id for a list row: `list:{owner slug}:{trakt id}`.
  static String listHubId(TraktUserList list) => 'list:${list.userSlug ?? 'me'}:${list.traktId}';

  @override
  CatalogSourceId get id => CatalogSourceId.traktLists;

  @override
  String get displayName => 'Trakt Lists';

  @override
  List<CatalogRowId> get supportedRows => const [];

  @override
  bool get supportsWatchlist => false;

  @override
  Future<CatalogPage> fetchRow(CatalogRowId row, {int page = 1, int limit = 25}) =>
      throw ArgumentError('Trakt Lists serves hubs, not ${row.name}');

  /// Items fetched per row (Explore asks for its default 25; lists read
  /// better with more). View all pages through the rest.
  static const int rowItemLimit = 50;

  @override
  Future<List<CatalogHub>> fetchHubs({int limit = rowItemLimit}) async {
    if (limit < rowItemLimit) limit = rowItemLimit;
    // Charts and the user's lists in parallel; one failing row never hides
    // the others.
    Future<CatalogHub?> safe(String hubId, String title) async {
      try {
        final page = await fetchHub(hubId, limit: limit);
        return page.items.isEmpty ? null : CatalogHub(id: hubId, title: title, page: page);
      } catch (e) {
        appLogger.w('Trakt Lists: $hubId failed', error: e);
        return null;
      }
    }

    final lists = await _listsForRows();
    final hubs = await Future.wait([
      safe(_boxOffice, t.explore.traktLists.boxOffice),
      safe(_watchedMovies, t.explore.traktLists.mostWatchedMovies),
      safe(_watchedShows, t.explore.traktLists.mostWatchedShows),
      safe(_anticipatedMovies, t.explore.traktLists.anticipatedMovies),
      safe(_anticipatedShows, t.explore.traktLists.anticipatedShows),
      for (final list in lists) safe(listHubId(list), list.name),
    ]);
    return [for (final hub in hubs) ?hub];
  }

  /// Liked lists (newest like first), then the user's own lists except the
  /// Comfort list, without repeats.
  Future<List<TraktUserList>> _listsForRows() async {
    final liked = await _client.getLikedLists().catchError((Object e) {
      appLogger.w('Trakt Lists: liked lists failed', error: e);
      return <TraktUserList>[];
    });
    final own = await _client.getMyLists().catchError((Object e) {
      appLogger.w('Trakt Lists: own lists failed', error: e);
      return <TraktUserList>[];
    });
    final seen = <int>{};
    return [
      for (final list in [...liked, ...own])
        if (list.slug != ComfortShowsController.listSlug && seen.add(list.traktId)) list,
    ];
  }

  @override
  Future<CatalogPage> fetchHub(String id, {int page = 1, int limit = 25}) async {
    switch (id) {
      case _boxOffice:
        // A fixed top 10; no paging.
        if (page > 1) return const CatalogPage(items: []);
        return CatalogPage(items: _trakt.itemsFromEntries(await _client.getBoxOffice(), kind: MediaKind.movie));
      case _watchedMovies:
        return _page(await _client.getMostWatched(TraktCatalogType.movies, page: page, limit: limit), MediaKind.movie);
      case _watchedShows:
        return _page(await _client.getMostWatched(TraktCatalogType.shows, page: page, limit: limit), MediaKind.show);
      case _anticipatedMovies:
        return _page(await _client.getAnticipated(TraktCatalogType.movies, page: page, limit: limit), MediaKind.movie);
      case _anticipatedShows:
        return _page(await _client.getAnticipated(TraktCatalogType.shows, page: page, limit: limit), MediaKind.show);
    }
    final list = parseListHubId(id);
    if (list == null) throw ArgumentError('Unknown Trakt Lists hub $id');
    final items = await _client.getListItems(list.user, list.listId, page: page, limit: limit);
    return CatalogPage(
      items: _trakt.itemsFromEntries(showsForSeasonsAndEpisodes(items.items)),
      hasMore: items.hasMore,
      totalResults: items.itemCount,
    );
  }

  /// Lists can hold seasons and episodes (e.g. a franchise timeline). A
  /// browse row shows titles, so each becomes its show, once, at its first
  /// position; movies and shows pass through unchanged.
  @visibleForTesting
  static List<TraktCatalogEntry> showsForSeasonsAndEpisodes(List<TraktCatalogEntry> entries) {
    final seenShows = <int>{};
    final result = <TraktCatalogEntry>[];
    for (final entry in entries) {
      final show = entry.show;
      final isPart = entry.type == 'season' || entry.type == 'episode';
      if (show != null && (isPart || entry.type == 'show')) {
        final id = show.ids.trakt;
        if (id != null && !seenShows.add(id)) continue;
        result.add(isPart ? TraktCatalogEntry(listedAt: entry.listedAt, type: 'show', show: show) : entry);
        continue;
      }
      result.add(entry);
    }
    return result;
  }

  /// `(owner slug, trakt id)` from a [listHubId], or null for other ids.
  @visibleForTesting
  static ({String user, int listId})? parseListHubId(String id) {
    final parts = id.split(':');
    if (parts.length != 3 || parts[0] != 'list') return null;
    final listId = int.tryParse(parts[2]);
    if (listId == null || parts[1].isEmpty) return null;
    return (user: parts[1], listId: listId);
  }

  CatalogPage _page(TrackerPage<TraktCatalogEntry> page, MediaKind? kind) => CatalogPage(
    items: _trakt.itemsFromEntries(page.items, kind: kind),
    hasMore: page.hasMore,
    totalResults: page.itemCount,
  );

  @override
  Future<List<CatalogItem>> search(String query, {int limit = 30}) => _trakt.search(query, limit: limit);

  @override
  Future<CatalogDetail> fetchDetail(CatalogItem item, {int castLimit = 20, int relatedLimit = 20}) =>
      _trakt.fetchDetail(item, castLimit: castLimit, relatedLimit: relatedLimit);

  // The watchlist belongs to the wrapped Trakt source.
  @override
  Future<void> ensureWatchlistLoaded() => Future.value();

  @override
  bool? isOnWatchlist(MediaKind kind, CatalogItemIds ids) => null;

  @override
  Future<CatalogItemIds?> resolveItemIds(MediaKind kind, ExternalIds external) async => null;

  @override
  Future<void> addToWatchlist(MediaKind kind, CatalogItemIds ids) =>
      throw UnsupportedError('Use the Trakt source for the watchlist');

  @override
  Future<void> removeFromWatchlist(MediaKind kind, CatalogItemIds ids) =>
      throw UnsupportedError('Use the Trakt source for the watchlist');

  @override
  Listenable get watchlistChanges => _trakt.watchlistChanges;

  /// The wrapped Trakt source owns the client and its watchlist state.
  @override
  void dispose() {}
}
