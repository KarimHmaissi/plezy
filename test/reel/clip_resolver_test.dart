import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_store.dart';

class FakeServers implements ReelServers {
  final Map<String, List<PlexExtraClip>> extrasByKey = {};
  final Set<String> slow = {};

  /// Servers not connected (asleep, or still reconnecting after a wake).
  final Set<String> offline = {};

  /// Servers whose reads fail with this error (a 401, a 5xx).
  final Map<String, Object> failWith = {};
  final List<String> calls = [];

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    if (offline.contains(serverId)) throw ReelServerUnavailable(serverId);
    calls.add('$serverId:$ratingKey');
    if (slow.contains(serverId)) throw TimeoutException('slow', timeout);
    if (failWith[serverId] case final e?) throw e;
    return extrasByKey['$serverId:$ratingKey'] ?? const [];
  }

  @override
  String? clipUrl(String serverId, String partKey) =>
      offline.contains(serverId) ? null : 'https://$serverId.example$partKey?token=x';
}

PlexExtraClip _x(String rk, String title, {int i = 0}) => PlexExtraClip(
  ratingKey: rk,
  title: title,
  partKey: '/services/iva/assets/$rk/video.mp4',
  subtype: 'trailer',
  index: i,
);

void main() {
  late ForkDatabase db;
  late ReelStore store;
  late FakeServers servers;
  late List<List<int>> atCalls;
  late ClipResolver resolver;

  /// What the AnimeThemes fetch does instead of answering (null answers).
  Object? atFailure;
  late Map<int, Map<String, dynamic>> atRecords;

  ClipResolver make({ReelServerWait? wait, AniListLookup? aniList}) => ClipResolver(
    servers: servers,
    store: store,
    aniList: aniList ?? (t) async => t.tvdbId == 1 ? 101 : null,
    waitForServer: wait,
    animeThemes: (ids) async {
      atCalls.add(ids);
      if (atFailure case final e?) throw e;
      return atRecords;
    },
  );

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    servers = FakeServers();
    atCalls = [];
    atFailure = null;
    atRecords = {
      101: {
        'animethemes': [
          {
            'type': 'OP',
            'sequence': 1,
            'animethemeentries': [
              {
                'episodes': '1-12',
                'videos': [
                  {'id': 9, 'link': 'https://v.animethemes.moe/Show-OP1.webm', 'nc': true, 'resolution': 1080},
                ],
              },
            ],
          },
        ],
      },
    };
    resolver = make();
  });

  tearDown(() => db.close());

  ReelTitle film({List<ReelCopy>? copies}) => ReelTitle(
    titleId: 'm:imdb:tt1',
    groupKey: 'imdb:tt1',
    title: 'Film',
    isShow: false,
    copies: copies ?? const [ReelCopy(serverId: 'a', ratingKey: '1')],
  );

  test('anime shows play season 1 OP1 from AnimeThemes', () async {
    final clip = await resolver.resolve(
      const ReelTitle(
        titleId: 's:tvdb:1',
        groupKey: 'tvdb:1',
        title: 'Show',
        isShow: true,
        anime: true,
        tvdbId: 1,
        copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
      ),
    );
    expect(clip?.source.origin, ClipOrigin.animeTheme);
    expect(clip?.source.uri, 'https://v.animethemes.moe/Show-OP1.webm');
    expect(clip?.assetId, 'at:9');
    expect(servers.calls, isEmpty, reason: 'no server read when the opening is found');
  });

  test('films play their Plex trailer; the URL is built per session, the identity is cached', () async {
    servers.extrasByKey['a:1'] = [_x('77', 'Final Trailer', i: 0), _x('78', 'Official Trailer', i: 1)];
    final clip = await resolver.resolve(film());
    expect(clip?.assetId, 'plex:78');
    expect(clip?.source.uri, startsWith('https://a.example/services/iva/assets/78/'));
    expect(clip?.label, 'Trailer');
    final cached = await store.cached('src:imdb:tt1');
    expect(cached, isNot(contains('token')), reason: 'never cache a resolved URL');

    servers.calls.clear();
    final again = await resolver.resolve(film());
    expect(again?.assetId, 'plex:78');
    expect(servers.calls, isEmpty, reason: 'cached identity, no second read');
  });

  test('a server that times out gets one try, then is skipped; the next copy is used', () async {
    servers.slow.add('slow');
    servers.extrasByKey['b:2'] = [_x('80', 'Teaser')];
    final clip = await resolver.resolve(
      film(
        copies: const [
          ReelCopy(serverId: 'slow', ratingKey: '9'),
          ReelCopy(serverId: 'b', ratingKey: '2'),
        ],
      ),
    );
    expect(clip?.assetId, 'plex:80');
    expect(clip?.label, 'Teaser');
    expect(resolver.slowServers, {'slow'});

    servers.calls.clear();
    await resolver.resolve(
      const ReelTitle(
        titleId: 'm:imdb:tt2',
        groupKey: 'imdb:tt2',
        title: 'Other',
        isShow: false,
        copies: [ReelCopy(serverId: 'slow', ratingKey: '10')],
      ),
    );
    expect(servers.calls, isEmpty, reason: 'slow servers are not asked again this session');
  });

  test('a miss is cached (AI card) and not retried for 30 days', () async {
    expect(await resolver.resolve(film()), isNull);
    servers.calls.clear();
    expect(await resolver.resolve(film()), isNull);
    expect(servers.calls, isEmpty);
  });

  test('Spoiled me skips that asset and drops to the next trailer', () async {
    servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer', i: 0), _x('79', 'Trailer 2', i: 1)];
    await store.spoiled('m:imdb:tt1', 'plex:78');
    final clip = await resolver.resolve(film());
    expect(clip?.assetId, 'plex:79');
  });

  test('HD copies are tried before 4K', () async {
    servers.extrasByKey['b:2'] = [_x('81', 'Trailer')];
    await resolver.resolve(
      film(
        copies: const [
          ReelCopy(serverId: 'a', ratingKey: '1', is4k: true),
          ReelCopy(serverId: 'b', ratingKey: '2'),
        ],
      ),
    );
    expect(servers.calls.first, 'b:2');
  });

  group('transient failures are never cached as misses (V2-56)', () {
    ReelTitle animeShow({List<ReelCopy> copies = const [ReelCopy(serverId: 'a', ratingKey: '5')]}) => ReelTitle(
      titleId: 's:tvdb:1',
      groupKey: 'tvdb:1',
      title: 'Harbor Lights',
      isShow: true,
      anime: true,
      tvdbId: 1,
      copies: copies,
    );

    test('a server that is not connected leaves the title unknown, and asks again next time', () async {
      servers.offline.add('a');
      final first = await resolver.lookup(film());
      expect(first.answer, ClipAnswer.unknown);
      expect(await store.cached('src:imdb:tt1'), isNull, reason: 'no 30-day miss for an offline server');

      servers.offline.clear();
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      expect((await resolver.lookup(film())).clip?.assetId, 'plex:78');
    });

    test('a 401 from the server is unknown, not a miss', () async {
      servers.failWith['a'] = MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: 401,
        message: 'HTTP 401',
      );
      expect((await resolver.lookup(film())).answer, ClipAnswer.unknown);
      expect(await store.cached('src:imdb:tt1'), isNull);
    });

    test('a timeout is unknown, and so is the slow server skipped later', () async {
      servers.slow.add('a');
      expect((await resolver.lookup(film())).answer, ClipAnswer.unknown);
      expect((await resolver.lookup(film())).answer, ClipAnswer.unknown);
      expect(await store.cached('src:imdb:tt1'), isNull);
    });

    test('a server that answers with no trailer is a definitive miss, cached', () async {
      expect((await resolver.lookup(film())).answer, ClipAnswer.none);
      expect(await store.cached('src:imdb:tt1'), '{"miss":true}');
    });

    test('one copy offline and one answering with nothing is still unknown', () async {
      servers.offline.add('a');
      final r = await resolver.lookup(
        film(
          copies: const [
            ReelCopy(serverId: 'a', ratingKey: '1'),
            ReelCopy(serverId: 'b', ratingKey: '2'),
          ],
        ),
      );
      expect(r.answer, ClipAnswer.unknown);
      expect(await store.cached('src:imdb:tt1'), isNull);
    });

    for (final (name, failure) in [
      ('a 503', const AnimeThemesUnavailable('HTTP 503')),
      ('a 429', const AnimeThemesUnavailable('429')),
      ('a network error', http.ClientException('reset')),
    ]) {
      test('AnimeThemes failing with $name leaves an anime title unknown', () async {
        atFailure = failure;
        final r = await resolver.lookup(animeShow());
        expect(r.answer, ClipAnswer.unknown);
        expect(await store.cached('src:tvdb:1'), isNull);
      });
    }

    test('AnimeThemes failing still falls through to a Plex trailer', () async {
      atFailure = const AnimeThemesUnavailable('429');
      servers.extrasByKey['a:5'] = [_x('90', 'Harbor Lights Trailer')];
      final r = await resolver.lookup(animeShow());
      expect(r.clip?.assetId, 'plex:90');
      expect(await store.cached('src:tvdb:1'), contains('plex:90'));
    });

    test('no AnimeThemes record and no Plex trailer is a definitive miss', () async {
      atRecords = {};
      expect((await resolver.lookup(animeShow())).answer, ClipAnswer.none);
      expect(await store.cached('src:tvdb:1'), '{"miss":true}');
    });

    test('a mapping that could not be read is unknown', () async {
      resolver = make(aniList: (_) async => throw StateError('mapping unavailable'));
      expect((await resolver.lookup(animeShow())).answer, ClipAnswer.unknown);
      expect(await store.cached('src:tvdb:1'), isNull);
    });

    test('a cached identity is kept while its server is offline, and plays again once it is back', () async {
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      expect((await resolver.lookup(film())).clip?.assetId, 'plex:78');
      final saved = await store.cached('src:imdb:tt1');

      servers.offline.add('a');
      final away = await resolver.lookup(film());
      expect(away.answer, ClipAnswer.unknown);
      expect(await store.cached('src:imdb:tt1'), saved, reason: 'the identity is not overwritten by a miss');

      servers
        ..offline.clear()
        ..calls.clear();
      expect((await resolver.lookup(film())).clip?.assetId, 'plex:78');
      expect(servers.calls, isEmpty, reason: 'served from the kept identity');
    });

    test('an offline server is waited for once per resume, then the clip plays', () async {
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      await resolver.lookup(film());
      servers.offline.add('a');
      final waited = <String>[];
      resolver = make(
        wait: (id) async {
          waited.add(id);
          servers.offline.remove(id);
          return true;
        },
      );
      expect((await resolver.lookup(film())).clip?.assetId, 'plex:78');
      expect(waited, ['a']);

      // The same server dropping again later in the session is not waited
      // for a second time: the card is unknown at once.
      servers.offline.add('a');
      expect((await resolver.lookup(film())).answer, ClipAnswer.unknown);
      expect(waited, ['a'], reason: 'once per start or resume');

      servers.offline.add('a');
      resolver.resumed();
      await resolver.lookup(film());
      expect(waited, ['a', 'a']);
    });

    test('a fresh title whose only server is reconnecting resolves after the wait', () async {
      servers
        ..offline.add('a')
        ..extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      resolver = make(
        wait: (id) async {
          servers.offline.remove(id);
          return true;
        },
      );
      expect((await resolver.lookup(film())).clip?.assetId, 'plex:78');
    });

    test('a wait that runs out leaves the title unknown', () async {
      servers.offline.add('a');
      resolver = make(wait: (_) async => false);
      expect((await resolver.lookup(film())).answer, ClipAnswer.unknown);
      expect(await store.cached('src:imdb:tt1'), isNull);
    });

    test('a failed asset is skipped on the look-up after forget, and a miss then is not cached', () async {
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      await resolver.lookup(film());
      await resolver.forget(film());
      final r = await resolver.lookup(film(), exclude: {'plex:78'});
      expect(r.answer, ClipAnswer.none);
      expect(await store.cached('src:imdb:tt1'), isNot('{"miss":true}'));
      expect((await resolver.lookup(film())).clip?.assetId, 'plex:78', reason: 'the exclusion was for one call');
    });
  });

  group('AnimeThemesClient', () {
    test('a 503 throws instead of answering "no record"', () async {
      final client = AnimeThemesClient(client: MockClient((_) async => http.Response('down', 503)));
      await expectLater(client.fetch([101]), throwsA(isA<AnimeThemesUnavailable>()));
    });

    test('a 429 throws and blocks for Retry-After without another request', () async {
      var requests = 0;
      final client = AnimeThemesClient(
        client: MockClient((_) async {
          requests++;
          return http.Response('Too Many Attempts.', 429, headers: {'retry-after': '60'});
        }),
      );
      await expectLater(client.fetch([101]), throwsA(isA<AnimeThemesUnavailable>()));
      await expectLater(client.fetch([101]), throwsA(isA<AnimeThemesUnavailable>()));
      expect(requests, 1);
    });

    test('a response without the anime list throws', () async {
      final client = AnimeThemesClient(client: MockClient((_) async => http.Response('{"data":[]}', 200)));
      await expectLater(client.fetch([101]), throwsA(isA<AnimeThemesUnavailable>()));
    });

    test('an empty anime list is a sure "no record"', () async {
      final client = AnimeThemesClient(client: MockClient((_) async => http.Response('{"anime":[]}', 200)));
      expect(await client.fetch([101]), isEmpty);
    });
  });
}
