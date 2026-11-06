import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_store.dart';

class FakeServers implements ReelServers {
  final Map<String, List<PlexExtraClip>> extrasByKey = {};
  final Set<String> slow = {};

  /// Servers whose extras read fails outright (not a timeout).
  final Set<String> broken = {};

  /// Servers that are not connected: no clip URL.
  final Set<String> away = {};
  final List<String> calls = [];

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    calls.add('$serverId:$ratingKey');
    if (slow.contains(serverId)) throw TimeoutException('slow', timeout);
    if (broken.contains(serverId)) throw const FormatException('bad extras response');
    return extrasByKey['$serverId:$ratingKey'] ?? const [];
  }

  @override
  String? clipUrl(String serverId, String partKey) =>
      away.contains(serverId) ? null : 'https://$serverId.example$partKey?token=x';
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

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    servers = FakeServers();
    atCalls = [];
    resolver = ClipResolver(
      servers: servers,
      store: store,
      aniList: (t) async => t.tvdbId == 1 ? 101 : null,
      animeThemes: (ids) async {
        atCalls.add(ids);
        return {
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
      },
    );
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

  group('resolver failures (V2-62)', () {
    test('a server whose extras read fails is not marked slow; the next copy is used', () async {
      servers.broken.add('a');
      servers.extrasByKey['b:2'] = [_x('82', 'Trailer')];
      final clip = await resolver.resolve(
        film(
          copies: const [
            ReelCopy(serverId: 'a', ratingKey: '1'),
            ReelCopy(serverId: 'b', ratingKey: '2'),
          ],
        ),
      );
      expect(clip?.assetId, 'plex:82');
      expect(resolver.slowServers, isEmpty, reason: 'only a timeout marks a server slow');
    });

    test('a trailer on a server that is not connected falls to the next copy', () async {
      servers.away.add('a');
      servers.extrasByKey['a:1'] = [_x('83', 'Trailer')];
      servers.extrasByKey['b:2'] = [_x('84', 'Trailer')];
      final clip = await resolver.resolve(
        film(
          copies: const [
            ReelCopy(serverId: 'a', ratingKey: '1'),
            ReelCopy(serverId: 'b', ratingKey: '2'),
          ],
        ),
      );
      expect(clip?.assetId, 'plex:84');
      expect(clip?.serverId, 'b');
    });

    test('an AnimeThemes failure falls back to the Plex trailer', () async {
      final failing = ClipResolver(
        servers: servers,
        store: store,
        aniList: (_) async => 101,
        animeThemes: (_) async => throw http.ClientException('offline'),
      );
      servers.extrasByKey['a:5'] = [_x('86', 'Trailer')];
      final clip = await failing.resolve(
        const ReelTitle(
          titleId: 's:tvdb:7',
          groupKey: 'tvdb:7',
          title: 'Harbor Lights',
          isShow: true,
          anime: true,
          tvdbId: 7,
          copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
        ),
      );
      expect(clip?.source.origin, ClipOrigin.plexExtra);
    });

    test('an unreadable cache entry is resolved again', () async {
      await store.cache('src:imdb:tt1', '{not json');
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      expect((await resolver.resolve(film()))?.assetId, 'plex:87');
      expect(servers.calls, ['a:1']);
    });
  });

  group('AnimeThemesClient (V2-62)', () {
    late List<Uri> requests;

    AnimeThemesClient client(http.Response Function(http.Request r) answer) => AnimeThemesClient(
      client: MockClient((r) async {
        requests.add(r.url);
        return answer(r);
      }),
    );

    setUp(() => requests = []);

    http.Response anime(List<int> ids) => http.Response(
      jsonEncode({
        'anime': [
          for (final id in ids)
            {
              'name': 'Harbor Lights',
              'resources': [
                {'site': 'AniList', 'external_id': id},
                {'site': 'MyAnimeList', 'external_id': id + 1000},
              ],
            },
        ],
      }),
      200,
    );

    test('one batched request by AniList id, keyed back by AniList id', () async {
      final at = client((_) => anime([101, 102]));
      final out = await at.fetch([101, 102]);
      expect(out.keys, unorderedEquals([101, 102]));
      expect(requests, hasLength(1));
      final q = requests.single.queryParameters;
      expect(requests.single.host, 'api.animethemes.moe');
      expect(q['filter[site]'], 'AniList');
      expect(q['filter[external_id]'], '101,102');
      expect(q['page[size]'], '2');
    });

    test('no ids, no request', () async {
      final at = client((_) => anime(const []));
      expect(await at.fetch(const []), isEmpty);
      expect(requests, isEmpty);
    });

    test('a page never asks for more than 50', () async {
      final at = client((_) => anime(const []));
      await at.fetch([for (var i = 1; i <= 60; i++) i]);
      expect(requests.single.queryParameters['page[size]'], '50');
    });

    test('429 honours Retry-After: nothing more is sent until it passes', () async {
      final at = client((_) => http.Response('', 429, headers: {'retry-after': '30'}));
      expect(await at.fetch([101]), isEmpty);
      expect(await at.fetch([102]), isEmpty);
      expect(await at.fetch([103]), isEmpty);
      expect(requests, hasLength(1), reason: 'blocked for 30 s after the 429');
    });

    test('429 without Retry-After still backs off', () async {
      final at = client((_) => http.Response('', 429));
      await at.fetch([101]);
      await at.fetch([102]);
      expect(requests, hasLength(1));
    });

    test('at most ${AnimeThemesClient.perMinute} requests a minute; the rest get nothing', () async {
      final at = client((_) => anime([101]));
      var answered = 0;
      for (var i = 0; i < AnimeThemesClient.perMinute + 5; i++) {
        if ((await at.fetch([101])).isNotEmpty) answered++;
      }
      expect(requests, hasLength(AnimeThemesClient.perMinute));
      expect(answered, AnimeThemesClient.perMinute);
      expect(AnimeThemesClient.perMinute, lessThan(90), reason: 'under the API\'s 90 a minute');
    });

    test('another error status or an odd body gives no records', () async {
      expect(await client((_) => http.Response('', 503)).fetch([101]), isEmpty);
      expect(await client((_) => http.Response(jsonEncode({'links': {}}), 200)).fetch([101]), isEmpty);
      expect(
        await client(
          (_) => http.Response(
            jsonEncode({
              'anime': [
                {
                  'resources': [
                    {'site': 'AniList', 'external_id': '101'},
                  ],
                },
              ],
            }),
            200,
          ),
        ).fetch([101]),
        isEmpty,
        reason: 'external_id is an int in the live response',
      );
    });
  });

  group('captions (V2-54)', () {
    late bool captions;
    late ClipResolver ccResolver;

    Map<String, dynamic> video(int id, String name, {bool lyrics = false}) => {
      'id': id,
      'link': 'https://v.animethemes.moe/$name.webm',
      'nc': true,
      'lyrics': lyrics,
      'subbed': false,
      'resolution': 1080,
    };

    setUp(() {
      captions = false;
      atCalls = [];
      ccResolver = ClipResolver(
        servers: servers,
        store: store,
        aniList: (t) async => t.tvdbId == 1 ? 101 : null,
        captions: () => captions,
        animeThemes: (ids) async {
          atCalls.add(ids);
          return {
            101: {
              'animethemes': [
                {
                  'type': 'OP',
                  'sequence': 1,
                  'animethemeentries': [
                    {
                      'episodes': '1-12',
                      'videos': [video(9, 'Harbor-OP1'), video(10, 'Harbor-OP1-Lyrics', lyrics: true)],
                    },
                  ],
                },
              ],
            },
          };
        },
      );
    });

    const show = ReelTitle(
      titleId: 's:tvdb:1',
      groupKey: 'tvdb:1',
      title: 'Harbor Lights',
      isShow: true,
      anime: true,
      tvdbId: 1,
      copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
    );

    test('off picks the clean opening; on picks the one with lyrics; each choice keeps its own entry', () async {
      expect((await ccResolver.resolve(show))?.assetId, 'at:9');
      captions = true;
      expect((await ccResolver.resolve(show))?.assetId, 'at:10', reason: 'the switch re-picks, not the cached one');
      expect(atCalls, hasLength(2));

      // Both choices are cached now: switching back and forth asks nobody.
      captions = false;
      expect((await ccResolver.resolve(show))?.assetId, 'at:9');
      captions = true;
      expect((await ccResolver.resolve(show))?.assetId, 'at:10');
      expect(atCalls, hasLength(2));
    });

    test('a film keeps one entry whatever the choice', () async {
      servers.extrasByKey['a:1'] = [_x('70', 'Trailer')];
      expect((await ccResolver.resolve(film()))?.assetId, 'plex:70');
      captions = true;
      expect((await ccResolver.resolve(film()))?.assetId, 'plex:70');
      expect(servers.calls, ['a:1'], reason: 'no second server read for a choice that only touches openings');
    });
  });
}
