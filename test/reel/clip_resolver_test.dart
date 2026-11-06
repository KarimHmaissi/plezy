import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_store.dart';

class FakeServers implements ReelServers {
  final Map<String, List<PlexExtraClip>> extrasByKey = {};
  final Set<String> slow = {};
  final List<String> calls = [];

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    calls.add('$serverId:$ratingKey');
    if (slow.contains(serverId)) throw TimeoutException('slow', timeout);
    return extrasByKey['$serverId:$ratingKey'] ?? const [];
  }

  @override
  String? clipUrl(String serverId, String partKey) => 'https://$serverId.example$partKey?token=x';
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
}
