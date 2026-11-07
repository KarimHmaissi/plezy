import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/services/catalog/watchlist_split.dart';

CatalogItem _item(String title, MediaKind kind, {int? tmdb}) => CatalogItem(
  source: CatalogSourceId.trakt,
  kind: kind,
  title: title,
  ids: CatalogItemIds(tmdb: tmdb),
);

void main() {
  test('genre slugs read as titles; proper names are kept', () {
    expect(displayGenre('drama'), 'Drama');
    expect(displayGenre('science-fiction'), 'Science Fiction');
    expect(displayGenre('Sci-Fi & Fantasy'), 'Sci-Fi & Fantasy');
  });

  group('splitWatchlist', () {
    test('puts movies in films and everything else in TV, keeping order', () {
      final split = splitWatchlist([
        _item('Reverse Run', MediaKind.movie, tmdb: 1),
        _item('Old Captain', MediaKind.show, tmdb: 2),
        _item('Sand Sea', MediaKind.movie, tmdb: 3),
        _item('Old Captain S2', MediaKind.season, tmdb: 4),
        _item('Mystery', MediaKind.unknown, tmdb: 5),
      ]);

      expect(split.films.map((i) => i.title), ['Reverse Run', 'Sand Sea']);
      expect(split.tv.map((i) => i.title), ['Old Captain', 'Old Captain S2', 'Mystery']);
    });

    test('drops repeated titles but keeps a movie and show that share an id', () {
      final split = splitWatchlist([
        _item('Reverse Run', MediaKind.movie, tmdb: 1),
        _item('Tenet again', MediaKind.movie, tmdb: 1),
        _item('Same id, a show', MediaKind.show, tmdb: 1),
      ]);

      expect(split.films.map((i) => i.title), ['Reverse Run']);
      expect(split.tv.map((i) => i.title), ['Same id, a show']);
    });

    test('keeps entries that have no ids to compare', () {
      final split = splitWatchlist([_item('A', MediaKind.movie), _item('B', MediaKind.movie)]);

      expect(split.films.map((i) => i.title), ['A', 'B']);
    });

    test('an empty watchlist gives two empty shelves', () {
      final split = splitWatchlist(const []);

      expect(split.films, isEmpty);
      expect(split.tv, isEmpty);
    });
  });
}
