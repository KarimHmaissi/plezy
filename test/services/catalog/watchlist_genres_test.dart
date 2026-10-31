import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/catalog/watchlist_genres.dart';
import 'package:plezy/services/catalog/watchlist_split.dart';

import '../../test_helpers/prefs.dart';

CatalogItem _item(String title, MediaKind kind, {String? plex, List<String>? genres}) => CatalogItem(
  source: CatalogSourceId.plex,
  kind: kind,
  title: title,
  genres: genres,
  ids: CatalogItemIds(plex: plex),
);

class _FakeLookup implements CatalogGenreLookup {
  _FakeLookup(this.genresByTitle, {this.failing = const {}});

  final Map<String, List<String>> genresByTitle;
  final Set<String> failing;
  final List<String> calls = [];

  @override
  Future<List<String>?> fetchGenres(CatalogItem item) async {
    calls.add(item.title);
    if (failing.contains(item.title)) throw Exception('boom');
    return genresByTitle[item.title];
  }
}

void main() {
  group('groupWatchlistByGenre', () {
    final genres = <String, List<String>>{
      'Alien': ['Horror', 'Sci-Fi'],
      'Carrie': ['Horror'],
      'Tenet': ['Action', 'Sci-Fi'],
      'Dune': ['Sci-Fi', 'Adventure'],
      'Heat': ['Action'],
      'John Wick': ['Action'],
      'Picard': ['Drama'],
      'Severance': ['Drama'],
      'Bluey': ['Animation'],
    };
    List<String>? genresFor(CatalogItem item) => genres[item.title];

    test('one shelf per primary genre, largest first, Films before TV, small genres in Other', () {
      final split = splitWatchlist([
        for (final title in ['Alien', 'Tenet', 'Carrie', 'Dune', 'Heat', 'Mystery Film', 'John Wick'])
          _item(title, MediaKind.movie, plex: title),
        for (final title in ['Picard', 'Bluey', 'Severance']) _item(title, MediaKind.show, plex: title),
      ]);

      final groups = groupWatchlistByGenre(split, genresFor);

      expect(
        [
          for (final g in groups)
            '${g.films ? 'Films' : 'TV'} ${g.genre ?? 'Other'}: ${g.items.map((i) => i.title).join(', ')}',
        ],
        [
          'Films Action: Tenet, Heat, John Wick',
          'Films Horror: Alien, Carrie',
          // Dune is the only title whose primary genre is Sci-Fi (Alien and
          // Tenet list it second), so it rejoins the genre-less film in Other.
          'Films Other: Dune, Mystery Film',
          'TV Drama: Picard, Severance',
          'TV Other: Bluey',
        ],
      );
    });

    test('every title appears exactly once', () {
      final items = [for (final title in genres.keys) _item(title, MediaKind.movie, plex: title)];
      final groups = groupWatchlistByGenre(splitWatchlist(items), genresFor);

      final placed = [for (final g in groups) ...g.items];
      expect(placed, hasLength(items.length));
      expect(placed.toSet(), hasLength(items.length));
    });

    test('ties are ordered alphabetically', () {
      final split = splitWatchlist([
        _item('Heat', MediaKind.movie, plex: 'h'),
        _item('John Wick', MediaKind.movie, plex: 'j'),
        _item('Alien', MediaKind.movie, plex: 'a'),
        _item('Carrie', MediaKind.movie, plex: 'c'),
      ]);
      final groups = groupWatchlistByGenre(split, genresFor);
      expect([for (final g in groups) g.genre], ['Action', 'Horror']);
    });
  });

  group('resolveWatchlistGenres', () {
    test('uses listed genres, then fresh cache, then fetches the rest', () async {
      final now = DateTime(2026, 10, 31);
      final cache = WatchlistGenreCache({}, now: () => now);
      cache.store('movie/plex:cached', ['Horror']);
      final lookup = _FakeLookup({
        'Fetched': const ['Comedy'],
        'Cached': const ['Wrong'],
      });

      final listed = _item('Listed', MediaKind.movie, plex: 'listed', genres: const ['Drama']);
      final cached = _item('Cached', MediaKind.movie, plex: 'cached');
      final fetched = _item('Fetched', MediaKind.movie, plex: 'fetched');

      final result = await resolveWatchlistGenres([listed, cached, fetched], lookup: lookup, cache: cache);

      expect(result[listed], ['Drama']);
      expect(result[cached], ['Horror']);
      expect(result[fetched], ['Comedy']);
      expect(lookup.calls, ['Fetched']);
      expect(cache.lookup(fetched.identityKey), ['Comedy']);
    });

    test('expired cache entries are fetched again', () async {
      var now = DateTime(2026, 10, 1);
      final cache = WatchlistGenreCache({}, now: () => now);
      cache.store('movie/plex:old', ['Horror']);
      now = now.add(WatchlistGenreCache.maxAge + const Duration(hours: 1));
      final lookup = _FakeLookup({
        'Old': const ['Thriller'],
      });

      final old = _item('Old', MediaKind.movie, plex: 'old');
      final result = await resolveWatchlistGenres([old], lookup: lookup, cache: cache);

      expect(lookup.calls, ['Old']);
      expect(result[old], ['Thriller']);
    });

    test('failed lookups are left out and not cached, so the next load retries', () async {
      final cache = WatchlistGenreCache({});
      final lookup = _FakeLookup({}, failing: {'Flaky'});
      final flaky = _item('Flaky', MediaKind.movie, plex: 'flaky');

      final result = await resolveWatchlistGenres([flaky], lookup: lookup, cache: cache);

      expect(result.containsKey(flaky), isFalse);
      expect(cache.lookup(flaky.identityKey), isNull);
    });

    test('titles without ids are fetched but never cached or confused with each other', () async {
      final cache = WatchlistGenreCache({});
      final lookup = _FakeLookup({
        'A': const ['Comedy'],
        'B': const ['Horror'],
      });
      final a = _item('A', MediaKind.movie);
      final b = _item('B', MediaKind.movie);

      final result = await resolveWatchlistGenres([a, b], lookup: lookup, cache: cache);

      expect(result[a], ['Comedy']);
      expect(result[b], ['Horror']);
      expect(cache.lookup(a.identityKey), isNull);
    });

    test('runs at most [concurrency] lookups at once', () async {
      var inFlight = 0;
      var peak = 0;
      final lookup = _CountingLookup(() => inFlight, (v) {
        inFlight = v;
        if (v > peak) peak = v;
      });
      final items = [for (var i = 0; i < 20; i++) _item('T$i', MediaKind.movie, plex: '$i')];

      await resolveWatchlistGenres(items, lookup: lookup, cache: WatchlistGenreCache({}), concurrency: 3);

      expect(peak, 3);
    });
  });

  group('WatchlistGenreCache persistence', () {
    setUp(resetSharedPreferencesForTest);

    test('save and load round-trip fresh entries', () async {
      final cache = WatchlistGenreCache({});
      cache.store('movie/plex:1', ['Action', 'Sci-Fi']);
      await cache.save(await BaseSharedPreferencesService.sharedCache());

      final reloaded = await WatchlistGenreCache.load();
      expect(reloaded.lookup('movie/plex:1'), ['Action', 'Sci-Fi']);
      expect(reloaded.lookup('movie/plex:2'), isNull);
    });
  });
}

class _CountingLookup implements CatalogGenreLookup {
  _CountingLookup(this._get, this._set);

  final int Function() _get;
  final void Function(int) _set;

  @override
  Future<List<String>?> fetchGenres(CatalogItem item) async {
    _set(_get() + 1);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    _set(_get() - 1);
    return const ['Drama'];
  }
}
