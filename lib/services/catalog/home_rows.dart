import 'package:flutter/foundation.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../models/catalog/catalog_item.dart';
import '../../providers/catalog_sources_provider.dart';
import '../../utils/app_logger.dart';
import '../ai/ai_history.dart';
import '../comfort/comfort_shows_controller.dart';
import '../reel/reel_store.dart';
import 'catalog_source.dart';
import 'home_pins.dart';
import 'trakt_catalog_source.dart';
import 'trakt_lists_catalog_source.dart';
import 'watchlist_genres.dart';
import 'watchlist_split.dart';

/// A Plex row as Home shows it: same-title rows from every server and
/// library merged into one (see [mergePlexHubs]), with where each part came
/// from (`serverId|hub key`) so it can be added to Home and fetched again.
typedef MergedPlexHub = ({String rowId, MediaHub hub, List<String> sources});

/// Key that identifies one title across servers and libraries.
String _itemKey(MediaItem item) => item.guid ?? '${item.kind.name}|${item.title}|${item.year}';

/// Merge rows with the same title ("Oh, The Horror!" from five movie
/// libraries, two "Halloween Movies" collections) into one row, in first
/// appearance order. Items repeated across the parts appear once.
List<MergedPlexHub> mergePlexHubs(Iterable<MediaHub> hubs) {
  final order = <String>[];
  final parts = <String, List<MediaHub>>{};
  for (final hub in hubs) {
    if (hub.items.isEmpty) continue;
    final id = HomeRowIds.plex(hub.title);
    parts
        .putIfAbsent(id, () {
          order.add(id);
          return [];
        })
        .add(hub);
  }
  return [for (final id in order) _merge(id, parts[id]!)];
}

MergedPlexHub _merge(String rowId, List<MediaHub> parts) {
  final sources = [
    for (final part in parts)
      if (part.serverId != null) '${part.serverId}|${part.id}',
  ];
  final first = parts.first;
  if (parts.length == 1) return (rowId: rowId, hub: first, sources: sources);
  final seen = <String>{};
  final items = <MediaItem>[
    for (final part in parts)
      for (final item in part.items)
        if (seen.add(_itemKey(item))) item,
  ];
  return (
    rowId: rowId,
    hub: MediaHub(
      id: first.id,
      identifier: first.identifier,
      title: first.title,
      type: parts.every((p) => p.type == first.type) ? first.type : 'mixed',
      items: items,
      size: items.length,
      more: parts.any((p) => p.more),
      serverId: first.serverId,
      serverName: first.serverName,
    ),
    sources: sources,
  );
}

/// The Watchlist page's shelves for [source]: Films and TV, then each genre
/// shelf (`films.Horror`, `tv.other`…), with their titles.
typedef WatchlistShelf = ({String id, String title, List<CatalogItem> items});

String watchlistShelfTitle({required bool films, String? genre}) => switch ((films, genre)) {
  (true, final String genre) => t.watchlist.genreFilms(genre: displayGenre(genre)),
  (false, final String genre) => t.watchlist.genreTv(genre: displayGenre(genre)),
  (true, null) => t.watchlist.otherFilms,
  (false, null) => t.watchlist.otherTv,
};

Future<List<WatchlistShelf>> loadWatchlistShelves(CatalogSource source, {int minGenreShelfSize = 6}) async {
  final items = <CatalogItem>[];
  for (var page = 1; page <= 5; page++) {
    final result = await source.fetchRow(CatalogRowId.watchlist, page: page, limit: 100);
    items.addAll(result.items);
    if (!result.hasMore) break;
  }
  final split = splitWatchlist(items);
  final cache = await WatchlistGenreCache.load();
  final genres = await resolveWatchlistGenres(
    [...split.films, ...split.tv],
    lookup: source is CatalogGenreLookup ? source as CatalogGenreLookup : null,
    cache: cache,
  );
  await cache.save();
  final groups = groupWatchlistByGenre(split, (item) => genres[item], minGroupSize: minGenreShelfSize);
  return [
    (id: 'films', title: t.watchlist.films, items: split.films),
    (id: 'tv', title: t.watchlist.tv, items: split.tv),
    for (final group in groups)
      (
        id: '${group.films ? 'films' : 'tv'}.${group.genre ?? 'other'}',
        title: watchlistShelfTitle(films: group.films, genre: group.genre),
        items: group.items,
      ),
  ];
}

/// How an added row last loaded on Home, for Manage Home.
enum HomeRowLoadState { loading, loaded, empty, unavailable }

/// Load state of each added row that Home fetches itself, by row id.
final ValueNotifier<Map<String, HomeRowLoadState>> homeRowLoadStates = ValueNotifier(const {});

/// Fetches the rows added to Home that Home doesn't already have loaded:
/// Trakt charts and lists, Explore rows of any source, Watchlist shelves,
/// Comfort shows, and Plex rows Home's own hubs don't include (library rows,
/// collections).
class HomeRowResolver {
  HomeRowResolver({required this.sources, required this.clientFor});

  final CatalogSourcesProvider sources;
  final MediaServerClient? Function(ServerId serverId) clientFor;

  static const int itemLimit = TraktListsCatalogSource.rowItemLimit;

  /// Whether Home fetches [id] itself (Continue Watching rows come from Home).
  static bool needsFetch(String id) =>
      id != HomeRowIds.continueWatching && id != HomeRowIds.pickBackUp && id != HomeRowIds.comfortCarryOn;

  CatalogSource? _source(String name) => sources.connectedSources.where((s) => s.id.name == name).firstOrNull;

  Future<MediaHub?> fetch(HomeRowEntry row) async {
    final id = row.id;
    final colon = id.indexOf(':');
    final kind = colon < 0 ? id : id.substring(0, colon);
    final rest = colon < 0 ? '' : id.substring(colon + 1);
    List<MediaItem>? items;
    switch (kind) {
      case 'tl':
        final lists = sources.connectedSources.whereType<TraktListsCatalogSource>().firstOrNull;
        if (lists == null) return null;
        items = _catalog((await lists.fetchHub(rest, limit: itemLimit)).items);
      case 'cat' || 'cath':
        final sep = rest.indexOf(':');
        if (sep < 0) return null;
        final source = _source(rest.substring(0, sep));
        final key = rest.substring(sep + 1);
        if (source == null) return null;
        if (kind == 'cat') {
          final rowId = CatalogRowId.values.where((r) => r.name == key).firstOrNull;
          if (rowId == null) return null;
          items = _catalog((await source.fetchRow(rowId, limit: itemLimit)).items);
        } else {
          if (source is! CatalogHubSource) return null;
          items = _catalog((await fetchCatalogHub(source as CatalogHubSource, key, limit: itemLimit)).items);
        }
      case 'wl':
        // `wl:{source}:{shelf}`, or `wl:{shelf}` from before shelves named
        // their source.
        final sep = rest.indexOf(':');
        final named = sep < 0 ? null : _source(rest.substring(0, sep));
        final shelfId = sep < 0 ? rest : rest.substring(sep + 1);
        final source =
            named ??
            (sources.activeSource?.supportsWatchlist == true ? sources.activeSource : sources.watchlistCapableSource);
        if (source == null || !source.supportsWatchlist) return null;
        final shelf = (await loadWatchlistShelves(source)).where((s) => s.id == shelfId).firstOrNull;
        items = _catalog(shelf?.items ?? const []);
      case HomeRowIds.comfort:
        final trakt = sources.connectedSources.whereType<TraktCatalogSource>().firstOrNull;
        if (trakt == null) return null;
        final controller = ComfortShowsController(trakt);
        try {
          await controller.load(createIfMissing: false);
          items = _catalog(controller.shows);
        } finally {
          controller.dispose();
        }
      case 'px':
        final parts = <MediaHub>[];
        for (final source in row.sources) {
          final sep = source.indexOf('|');
          if (sep < 0) continue;
          final client = clientFor(ServerId(source.substring(0, sep)));
          if (client == null) continue;
          final partItems = await client.fetchMoreHubItems(source.substring(sep + 1), limit: itemLimit);
          parts.add(MediaHub(id: source, title: row.title, type: 'mixed', items: partItems));
        }
        final merged = mergePlexHubs(parts).firstOrNull;
        items = merged?.hub.items.take(itemLimit).toList();
      case 'ai':
        // A saved AI answer: its stored picks, no server calls.
        items = (await AiHistory.get(rest))?.items;
      case HomeRowIds.reelPicks:
        // Fork: the Reel's fresh Saves, newest first, from the copy saved.
        items = [];
        for (final pick in await ReelStore.instance.freshPicks()) {
          final client = clientFor(ServerId(pick.serverId));
          if (client == null) continue;
          try {
            final item = await client.fetchItem(pick.ratingKey);
            if (item != null) items.add(item);
          } catch (e) {
            appLogger.d('Home: Reel pick unavailable', error: e);
          }
        }
      default:
        return null;
    }
    if (items == null) return null;
    return MediaHub(
      id: 'home:$id',
      identifier: 'home:$id',
      title: row.title,
      type: 'mixed',
      items: items,
      size: items.length,
    );
  }

  /// One provider hub by id. Some providers (Plex Discover) can only fetch
  /// a hub once their hub list has been read this session, which only
  /// Explore did; when the direct fetch comes back empty, the list is read
  /// here so Home works from a cold start.
  @visibleForTesting
  static Future<CatalogPage> fetchCatalogHub(CatalogHubSource source, String id, {required int limit}) async {
    final page = await source.fetchHub(id, limit: limit);
    if (page.items.isNotEmpty) return page;
    final listed = (await source.fetchHubs(limit: limit)).where((h) => h.id == id).firstOrNull;
    return listed?.page ?? page;
  }

  static List<MediaItem> _catalog(List<CatalogItem> items) => [for (final item in items) item.toMediaItem()];
}
