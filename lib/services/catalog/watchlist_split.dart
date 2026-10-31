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

/// One genre shelf on the Watchlist page. [genre] is null for the "Other"
/// shelf (no genre, or a genre too small for its own row).
typedef WatchlistGenreGroup = ({bool films, String? genre, List<CatalogItem> items});

/// Group a split watchlist into genre shelves: all Films shelves, then all
/// TV shelves.
///
/// Each title appears once, under its first (primary) genre. Within each half
/// shelves are ordered by size, largest first (ties alphabetical), and a genre
/// with fewer than [minGroupSize] titles folds into that half's "Other" shelf,
/// which always comes last. Items keep their watchlist order inside a shelf.
List<WatchlistGenreGroup> groupWatchlistByGenre(
  WatchlistSplit split,
  List<String>? Function(CatalogItem item) genresFor, {
  int minGroupSize = 2,
}) {
  List<WatchlistGenreGroup> half(List<CatalogItem> items, {required bool films}) {
    final byGenre = <String, List<CatalogItem>>{};
    final other = <CatalogItem>[];
    for (final item in items) {
      final primary = genresFor(item)?.firstOrNull?.trim();
      if (primary == null || primary.isEmpty) {
        other.add(item);
      } else {
        byGenre.putIfAbsent(primary, () => []).add(item);
      }
    }
    final groups = <WatchlistGenreGroup>[];
    for (final MapEntry(key: genre, value: titles) in byGenre.entries) {
      if (titles.length < minGroupSize) {
        other.addAll(titles);
      } else {
        groups.add((films: films, genre: genre, items: titles));
      }
    }
    groups.sort((a, b) {
      final bySize = b.items.length.compareTo(a.items.length);
      return bySize != 0 ? bySize : a.genre!.compareTo(b.genre!);
    });
    if (other.isNotEmpty) {
      // Folded titles rejoin in watchlist order.
      final order = {for (var i = 0; i < items.length; i++) items[i]: i};
      other.sort((a, b) => order[a]!.compareTo(order[b]!));
      groups.add((films: films, genre: null, items: other));
    }
    return groups;
  }

  return [...half(split.films, films: true), ...half(split.tv, films: false)];
}
