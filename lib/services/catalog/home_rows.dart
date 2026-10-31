import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../models/catalog/catalog_item.dart';
import '../../providers/catalog_sources_provider.dart';
import '../comfort/comfort_shows_controller.dart';
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
  (true, final String genre) => t.watchlist.genreFilms(genre: genre),
  (false, final String genre) => t.watchlist.genreTv(genre: genre),
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
  static bool needsFetch(String id) => id != HomeRowIds.continueWatching && id != HomeRowIds.pickBackUp;

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
          items = _catalog((await (source as CatalogHubSource).fetchHub(key, limit: itemLimit)).items);
        }
      case 'wl':
        final source = sources.activeSource?.supportsWatchlist == true
            ? sources.activeSource
            : sources.watchlistCapableSource;
        if (source == null) return null;
        final shelf = (await loadWatchlistShelves(source)).where((s) => s.id == rest).firstOrNull;
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

  static List<MediaItem> _catalog(List<CatalogItem> items) => [for (final item in items) item.toMediaItem()];
}
