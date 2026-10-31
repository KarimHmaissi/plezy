import '../../media/media_kind.dart';
import '../../models/catalog/catalog_item.dart';

/// A watchlist divided into the Watchlist page's shelves.
typedef WatchlistSplit = ({List<CatalogItem> films, List<CatalogItem> tv});

/// Split [items] into films and TV, keeping the provider's order.
///
/// Movies are films; shows and anything below or beside them (seasons,
/// episodes, a provider's untyped entries) are TV, so nothing on the
/// watchlist disappears from the page. A title listed twice — paged twice,
/// or returned by an overlapping request — appears once; entries with no ids
/// to compare are always kept.
WatchlistSplit splitWatchlist(Iterable<CatalogItem> items) {
  final seen = <String>{};
  final films = <CatalogItem>[];
  final tv = <CatalogItem>[];
  for (final item in items) {
    if (item.ids.canonicalKey != null && !seen.add(item.identityKey)) continue;
    (item.kind == MediaKind.movie ? films : tv).add(item);
  }
  return (films: films, tv: tv);
}
