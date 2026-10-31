import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/trakt/trakt_catalog_entry.dart';
import 'package:plezy/models/trakt/trakt_catalog_media.dart';
import 'package:plezy/models/trakt/trakt_ids.dart';
import 'package:plezy/models/trakt/trakt_user_list.dart';
import 'package:plezy/services/catalog/trakt_lists_catalog_source.dart';

void main() {
  group('Trakt Lists hub ids', () {
    test('round-trip a list through its hub id', () {
      const list = TraktUserList(traktId: 1234, name: 'StarWars', userSlug: 'some-user');
      final id = TraktListsCatalogSource.listHubId(list);
      expect(id, 'list:some-user:1234');
      expect(TraktListsCatalogSource.parseListHubId(id), (user: 'some-user', listId: 1234));
    });

    test('own lists without an owner slug address /users/me', () {
      const list = TraktUserList(traktId: 7, name: 'Mine');
      expect(TraktListsCatalogSource.parseListHubId(TraktListsCatalogSource.listHubId(list)), (user: 'me', listId: 7));
    });

    test('chart and malformed ids are not lists', () {
      expect(TraktListsCatalogSource.parseListHubId('chart:boxoffice'), isNull);
      expect(TraktListsCatalogSource.parseListHubId('list::5'), isNull);
      expect(TraktListsCatalogSource.parseListHubId('list:user:abc'), isNull);
      expect(TraktListsCatalogSource.parseListHubId('list:user'), isNull);
    });
  });

  group('showsForSeasonsAndEpisodes', () {
    TraktCatalogMedia media(int id, String title) => TraktCatalogMedia(
      title: title,
      ids: TraktIds(trakt: id),
    );

    test('seasons and episodes become their show once, in first position; movies pass through', () {
      final clone = media(1, 'The Clone Wars');
      final mando = media(2, 'The Mandalorian');
      final result = TraktListsCatalogSource.showsForSeasonsAndEpisodes([
        TraktCatalogEntry(type: 'movie', movie: media(10, 'Episode I')),
        TraktCatalogEntry(type: 'season', show: clone),
        TraktCatalogEntry(type: 'season', show: clone),
        TraktCatalogEntry(type: 'movie', movie: media(11, 'Episode II')),
        TraktCatalogEntry(type: 'episode', show: mando),
        TraktCatalogEntry(type: 'show', show: mando),
      ]);

      expect(
        [for (final e in result) '${e.type}:${e.media?.title}'],
        ['movie:Episode I', 'show:The Clone Wars', 'movie:Episode II', 'show:The Mandalorian'],
      );
    });
  });

  group('TraktUserList.fromJson', () {
    test('reads owner, counts and ids from a liked/trending list payload', () {
      final list = TraktUserList.fromJson({
        'name': 'MARVEL Cinematic Universe',
        'description': 'Chronological order',
        'item_count': 215,
        'likes': 67,
        'ids': {'trakt': 99, 'slug': 'marvel-cinematic-universe'},
        'user': {
          'ids': {'slug': 'donxy'},
        },
      })!;
      expect(list.traktId, 99);
      expect(list.slug, 'marvel-cinematic-universe');
      expect(list.userSlug, 'donxy');
      expect(list.itemCount, 215);
      expect(list.likeCount, 67);
    });

    test('a payload without a numeric id is rejected', () {
      expect(TraktUserList.fromJson({'name': 'x', 'ids': <String, dynamic>{}}), isNull);
    });
  });
}
