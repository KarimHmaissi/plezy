import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/catalog/home_pins.dart';
import 'package:plezy/services/catalog/home_rows.dart';

void main() {
  group('Home layout in the Plezy list description', () {
    test('round-trips ordered rows, their sources and curation', () {
      final layout = (
        rows: [
          (id: HomeRowIds.continueWatching, title: 'Continue Watching', sources: <String>[]),
          (id: HomeRowIds.traktLists('chart:boxoffice'), title: 'Box Office', sources: <String>[]),
          (id: HomeRowIds.plex('Oh, The Horror!'), title: 'Oh, The Horror!', sources: ['srv1|/hubs/items?x=1']),
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

    test('the same Trakt list from anywhere is one row', () {
      expect(HomeRowIds.traktLists('list:donxy:99'), HomeRowIds.traktLists('list:*:99'));
      expect(HomeRowIds.traktLists('list:me:99'), isNot(HomeRowIds.traktLists('list:me:100')));
      expect(HomeRowIds.catalogRow(CatalogSourceId.trakt, CatalogRowId.trendingMovies), 'cat:trakt:trendingMovies');
    });

    test('row titles that differ only in case and punctuation are the same row', () {
      expect(HomeRowIds.plex('Recently Added in *Movies'), HomeRowIds.plex('Recently added in Movies'));
      expect(HomeRowIds.plex('Oh, The Horror!'), HomeRowIds.plex('oh the horror'));
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
        hub('/a', 'Oh, The Horror!', [movie('1', 'Alien', guid: 'g1'), movie('2', 'Scream', guid: 'g2')]),
        hub('/b', 'Recently Added in Movies', [movie('3', 'Up', guid: 'g3')]),
        hub('/c', 'Oh, The Horror!', [movie('9', 'Alien', guid: 'g1'), movie('4', 'Saw', guid: 'g4')]),
        hub('/d', 'Recently Added in *Movies', [movie('5', 'Heat', guid: 'g5')], server: 's2'),
        hub('/e', 'Empty', []),
      ]);
      expect([for (final m in merged) m.hub.title], ['Oh, The Horror!', 'Recently Added in Movies']);
      expect([for (final i in merged.first.hub.items) i.title], ['Alien', 'Scream', 'Saw']);
      expect(merged.first.sources, ['s1|/a', 's1|/c']);
      expect(merged.last.sources, ['s1|/b', 's2|/d']);
    });
  });
}
