import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/catalog/home_rows.dart';

void main() {
  coldStartTests();
  group('Home layout in the Plezy list description', () {
    test('round-trips ordered rows, their sources and curation', () {
      final layout = (
        rows: [
          (id: HomeRowIds.continueWatching, title: 'Continue Watching', sources: <String>[]),
          (id: HomeRowIds.traktLists('chart:boxoffice'), title: 'Box Office', sources: <String>[]),
          (id: HomeRowIds.plex('Hey, Spooky Picks!'), title: 'Hey, Spooky Picks!', sources: ['srv1|/hubs/items?x=1']),
          (id: HomeRowIds.watchlist('films.Horror'), title: 'Horror Films', sources: <String>[]),
        ],
        curated: false,
      );
      final description = writeHomeLayout('My notes', layout);
      expect(description, startsWith('My notes\nPlezy app settings [plezy:home2='));

      final parsed = parseHomeLayout(description)!;
      expect(parsed.curated, isFalse);
      expect([for (final r in parsed.rows) r.id], [for (final r in layout.rows) r.id]);
      expect(parsed.rows[2].sources, ['srv1|/hubs/items?x=1']);
      expect(parsed.rows[1].title, 'Box Office');
    });

    test('a first-version description migrates to Continue Watching, Pick back up, then its pins', () {
      final parsed = parseHomeLayout(
        'Plezy app settings [plezy:home=bo,41][plezy:hide=home.movies.recent]',
        titles: {HomeRowIds.traktLists('list:*:41'): 'James Bond Collection'},
      )!;
      expect(parsed.curated, isTrue);
      expect([for (final r in parsed.rows) r.id], ['cw', 'pb', 'tl:chart:boxoffice', 'tl:list:*:41']);
      expect(parsed.rows.last.title, 'James Bond Collection');
      expect(isLegacyHomeLayout('x [plezy:home=bo]'), isTrue);

      // Rewriting drops the old markers.
      final rewritten = writeHomeLayout('x [plezy:home=bo]\nkeep me', parsed);
      expect(rewritten, isNot(contains('plezy:home=')));
      expect(rewritten, startsWith('keep me\n'));
      expect(isLegacyHomeLayout(rewritten), isFalse);
    });

    test('no marker, or an unreadable one, means no layout', () {
      expect(parseHomeLayout(null), isNull);
      expect(parseHomeLayout('just a description'), isNull);
      expect(parseHomeLayout('[plezy:home2=!!!]'), isNull);
    });

    test('Watchlist shelves of each source are their own Home rows', () {
      expect(HomeRowIds.watchlist('films.Horror', source: CatalogSourceId.trakt), 'wl:trakt:films.Horror');
      expect(HomeRowIds.watchlist('films', source: CatalogSourceId.plex), 'wl:plex:films');
      expect(HomeRowIds.watchlist('films'), 'wl:films');
    });

    test('the same Trakt list from anywhere is one row', () {
      expect(HomeRowIds.traktLists('list:donxy:99'), HomeRowIds.traktLists('list:*:99'));
      expect(HomeRowIds.traktLists('list:me:99'), isNot(HomeRowIds.traktLists('list:me:100')));
      expect(HomeRowIds.catalogRow(CatalogSourceId.trakt, CatalogRowId.trendingMovies), 'cat:trakt:trendingMovies');
    });

    test('row titles that differ only in case and punctuation are the same row', () {
      expect(HomeRowIds.plex('Recently Added in *Movies'), HomeRowIds.plex('Recently added in Movies'));
      expect(HomeRowIds.plex('Hey, Spooky Picks!'), HomeRowIds.plex('hey spooky picks'));
      expect(HomeRowIds.plex('Movies (4K)'), isNot(HomeRowIds.plex('Movies')));
    });

    test('hundreds of rows fit easily in a description', () {
      final layout = (
        rows: [
          for (var i = 0; i < 300; i++) (id: 'tl:list:*:${10000000 + i}', title: 'List number $i', sources: <String>[]),
        ],
        curated: true,
      );
      // Trakt stored a 65,000-character description intact.
      expect(writeHomeLayout(null, layout).length, lessThan(65000));
    });
  });

  group('mergePlexHubs', () {
    MediaItem movie(String id, String title, {String? guid, String server = 's1'}) =>
        MediaItem.plex(id: id, kind: MediaKind.movie, title: title, guid: guid, serverId: server);

    MediaHub hub(String id, String title, List<MediaItem> items, {String server = 's1'}) =>
        MediaHub(id: id, title: title, type: 'movie', items: items, serverId: server);

    test('same-title rows from several libraries become one row without repeated titles', () {
      final merged = mergePlexHubs([
        hub('/a', 'Hey, Spooky Picks!', [movie('1', 'Deep Hull', guid: 'g1'), movie('2', 'Night Caller', guid: 'g2')]),
        hub('/b', 'Recently Added in Movies', [movie('3', 'Up', guid: 'g3')]),
        hub('/c', 'Hey, Spooky Picks!', [movie('9', 'Deep Hull', guid: 'g1'), movie('4', 'Puzzle Trap', guid: 'g4')]),
        hub('/d', 'Recently Added in *Movies', [movie('5', 'Hard Pursuit', guid: 'g5')], server: 's2'),
        hub('/e', 'Empty', []),
      ]);
      expect([for (final m in merged) m.hub.title], ['Hey, Spooky Picks!', 'Recently Added in Movies']);
      expect([for (final i in merged.first.hub.items) i.title], ['Deep Hull', 'Night Caller', 'Puzzle Trap']);
      expect(merged.first.sources, ['s1|/a', 's1|/c']);
      expect(merged.last.sources, ['s1|/b', 's2|/d']);
    });
  });
}

/// A provider like Plex Discover: a hub can only be fetched once the hub
/// list has been read this session.
class _ListFirstHubSource implements CatalogHubSource {
  bool listed = false;
  final CatalogItem item = CatalogItem(
    source: CatalogSourceId.plex,
    kind: MediaKind.movie,
    ids: const CatalogItemIds(plex: 'p1'),
    title: 'Released This Week',
  );

  @override
  Future<CatalogPage> fetchHub(String id, {int page = 1, int limit = 25}) async =>
      listed && id == 'home.historical-week' ? CatalogPage(items: [item]) : const CatalogPage(items: []);

  @override
  Future<List<CatalogHub>> fetchHubs({int limit = 25}) async {
    listed = true;
    return [
      CatalogHub(
        id: 'home.historical-week',
        title: 'Released This Week in History',
        page: CatalogPage(items: [item]),
      ),
    ];
  }
}

void coldStartTests() {
  test('a Plex Discover row added to Home loads on a cold start, before Explore was opened', () async {
    final source = _ListFirstHubSource();
    final page = await HomeRowResolver.fetchCatalogHub(source, 'home.historical-week', limit: 50);
    expect([for (final i in page.items) i.title], ['Released This Week']);
  });
}
