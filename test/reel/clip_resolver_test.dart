import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_playback_profile.dart';
import 'package:plezy/services/reel/reel_store.dart';

class FakeServers implements ReelServers {
  final Map<String, List<PlexExtraClip>> extrasByKey = {};
  final Set<String> slow = {};

  /// Servers not connected (asleep, or still reconnecting after a wake).
  final Set<String> offline = {};

  /// Servers whose reads fail with this error (a 401, a 5xx).
  final Map<String, Object> failWith = {};
  final List<String> calls = [];

  /// Reads that answer only when the test completes their gate.
  final Map<String, Completer<void>> gates = {};

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    if (offline.contains(serverId)) throw ReelServerUnavailable(serverId);
    calls.add('$serverId:$ratingKey');
    await gates['$serverId:$ratingKey']?.future;
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

  ClipResolver make({
    ReelServerWait? wait,
    AniListLookup? aniList,
    ValueListenable<ReelPlaybackProfile>? profile,
    AnimeThemesFetch? animeThemes,
  }) => ClipResolver(
    servers: servers,
    store: store,
    aniList: aniList ?? (t) async => t.tvdbId == 1 ? 101 : null,
    waitForServer: wait,
    profile: profile,
    animeThemes:
        animeThemes ??
        (ids) async {
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
                  {
                    'id': 9,
                    'link': 'https://v.animethemes.moe/Show-OP1.webm',
                    'nc': true,
                    'resolution': 1080,
                    'overlap': 'NONE',
                  },
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
    expect(clip?.kind, ClipKind.opening);
    expect(clip?.number, 1);
    expect(servers.calls, isEmpty, reason: 'no server read when the opening is found');
  });

  test('films play their Plex trailer; the URL is built per session, the identity is cached', () async {
    servers.extrasByKey['a:1'] = [_x('77', 'Final Trailer', i: 0), _x('78', 'Official Trailer', i: 1)];
    final clip = await resolver.resolve(film());
    expect(clip?.assetId, 'plex:78');
    expect(clip?.source.uri, startsWith('https://a.example/services/iva/assets/78/'));
    expect(clip?.kind, ClipKind.trailer);
    expect(clip?.number, isNull);
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
    expect(clip?.kind, ClipKind.teaser);
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

  group('the clip kind is cached, never its English words', () {
    test('a new row stores the kind and the opening number, and no label text', () async {
      servers.extrasByKey['a:1'] = [_x('80', 'Teaser')];
      await resolver.resolve(film());
      final plex = jsonDecode((await store.cached('src:imdb:tt1'))!) as Map<String, dynamic>;
      expect(plex['lk'], 'teaser');
      expect(plex.containsKey('ln'), isFalse);
      expect(plex.containsKey('l'), isFalse);

      await resolver.resolve(
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
      final at = jsonDecode((await store.cached('src:tvdb:1'))!) as Map<String, dynamic>;
      expect(at['lk'], 'opening');
      expect(at['ln'], 1);
      expect(at.containsKey('l'), isFalse);
    });

    for (final (label, kind) in [
      ('Teaser', ClipKind.teaser),
      ('Trailer', ClipKind.trailer),
      (null, ClipKind.trailer),
    ]) {
      test('a Plex row written with the English label ${label ?? '(none)'} still reads as $kind', () async {
        await store.cache(
          'src:imdb:tt1',
          jsonEncode({
            'v': ClipResolver.sourceFormat,
            'k': 'plex',
            'sv': 'a',
            'pk': '/services/iva/assets/80/video.mp4',
            'a': 'plex:80',
            'l': ?label,
          }),
        );
        final clip = await resolver.resolve(film());
        expect(clip?.assetId, 'plex:80');
        expect(clip?.kind, kind);
        expect(servers.calls, isEmpty, reason: 'served from the older row, no server read');
      });
    }

    for (final (label, number) in [('Opening 1', 1), ('Opening 2', 2), ('Opening', 1), (null, 1)]) {
      test('an AnimeThemes row written with the English label ${label ?? '(none)'} reads as opening $number', () async {
        await store.cache(
          'src:tvdb:1',
          jsonEncode({
            'v': ClipResolver.sourceFormat,
            'k': 'at',
            'l': ?label,
            'c': [
              {
                'a': 'at:9',
                'u': 'https://v.animethemes.moe/Show-OP1.webm',
                'h': 1080,
                'sz': 1,
                'tr': false,
                'nc': true,
                'cc': false,
                'so': null,
              },
            ],
          }),
        );
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
        expect(clip?.assetId, 'at:9');
        expect(clip?.kind, ClipKind.opening);
        expect(clip?.number, number);
        expect(atCalls, isEmpty, reason: 'served from the older row');
      });
    }

    test('legacy labels parse whatever their case, and unknown words say nothing', () {
      expect(ClipKind.fromLegacyLabel('teaser'), (ClipKind.teaser, null));
      expect(ClipKind.fromLegacyLabel('OPENING 3'), (ClipKind.opening, 3));
      expect(ClipKind.fromLegacyLabel('Featurette'), isNull);
      expect(ClipKind.fromLegacyLabel(7), isNull);
    });
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
      expect(await store.cached('src:imdb:tt1'), ClipResolver.missRow);
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
      expect(await store.cached('src:tvdb:1'), ClipResolver.missRow);
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
      expect(await store.cached('src:imdb:tt1'), isNot(ClipResolver.missRow));
      expect((await resolver.lookup(film())).clip?.assetId, 'plex:78', reason: 'the exclusion was for one call');
    });
  });

  group('the playback profile picks the file at play time (V2-16)', () {
    const harbor = ReelTitle(
      titleId: 's:tvdb:1',
      groupKey: 'tvdb:1',
      title: 'Harbor Lights',
      isShow: true,
      anime: true,
      tvdbId: 1,
      copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
    );
    const cover = ReelPlaybackProfile(screen: ReelScreen.compactPortrait, maxHeight: 720);
    const inner = ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080);

    Map<String, dynamic> video(
      int id,
      int res, {
      bool nc = true,
      int size = 30,
      String overlap = 'NONE',
      bool lyrics = false,
      String? source,
    }) => {
      'id': id,
      'link': 'https://v.animethemes.moe/HarborLights-OP1-$id.webm',
      'nc': nc,
      'resolution': res,
      'size': size,
      'overlap': overlap,
      'lyrics': lyrics,
      'subbed': false,
      'source': source,
    };

    setUp(() {
      atRecords = {
        101: {
          'animethemes': [
            {
              'type': 'OP',
              'sequence': 1,
              'animethemeentries': [
                {
                  'episodes': '1-12',
                  'videos': [video(1, 480), video(2, 720), video(3, 1080), video(4, 1080, nc: false)],
                },
              ],
            },
          ],
        },
      };
    });

    test('every candidate is cached, and the profile picks among them without another read', () async {
      final profile = ValueNotifier<ReelPlaybackProfile>(inner);
      addTearDown(profile.dispose);
      resolver = make(profile: profile);
      final first = await resolver.lookup(harbor);
      expect(first.clip?.assetId, 'at:3');
      expect(first.clip?.height, 1080);
      expect(first.clip?.candidates.map((c) => c.assetId), ['at:1', 'at:2', 'at:3', 'at:4']);
      final row = jsonDecode((await store.cached('src:tvdb:1'))!) as Map<String, dynamic>;
      expect(row['v'], ClipResolver.sourceFormat);
      expect((row['c'] as List).length, 4);

      // The foldable folds: the cover screen's profile.
      profile.value = cover;
      final folded = await resolver.lookup(harbor);
      expect(folded.clip?.assetId, 'at:2');
      expect(folded.clip?.source.uri, endsWith('-2.webm'));
      expect(atCalls, hasLength(1), reason: 'served from the cached candidates');
    });

    test('repick follows the profile and returns the same clip when nothing changes', () async {
      final profile = ValueNotifier<ReelPlaybackProfile>(inner);
      addTearDown(profile.dispose);
      resolver = make(profile: profile);
      final clip = (await resolver.lookup(harbor)).clip!;
      expect(identical(resolver.repick(clip), clip), isTrue);
      profile.value = cover;
      final again = resolver.repick(clip);
      expect(again.assetId, 'at:2');
      expect(again.kind, clip.kind);
      expect(again.number, clip.number);
      expect(again.candidates, clip.candidates);
    });

    test('data saver takes the lowest height above its cap when none is at or below it', () async {
      atRecords = {
        101: {
          'animethemes': [
            {
              'type': 'OP',
              'sequence': 1,
              'animethemeentries': [
                {
                  'episodes': '1-12',
                  'videos': [video(2, 720), video(3, 1080)],
                },
              ],
            },
          ],
        },
      };
      resolver = make(
        profile: ValueNotifier(
          const ReelPlaybackProfile(
            screen: ReelScreen.large,
            maxHeight: 480,
            link: ReelLink.cellular,
            dataSaver: true,
            largerFileAtHeight: false,
          ),
        ),
      );
      expect((await resolver.lookup(harbor)).clip?.assetId, 'at:2');
    });

    test('a spoiled file bans the whole opening: its other files are the same clip', () async {
      await resolver.lookup(harbor);
      await store.spoiled('s:tvdb:1', 'at:1');
      servers.extrasByKey['a:5'] = [_x('90', 'Harbor Lights Trailer')];
      final r = await resolver.lookup(harbor);
      expect(r.clip?.assetId, 'plex:90');
    });

    for (final (name, row) in [
      ('a one-file opening', '{"k":"at","u":"https://v.animethemes.moe/Old.webm","a":"at:9","l":"Opening 1"}'),
      (
        'a trailer identity',
        '{"k":"plex","sv":"a","pk":"/services/iva/assets/1/video.mp4","a":"plex:1","l":"Trailer"}',
      ),
      ('a miss', '{"miss":true}'),
      (
        'candidates cached before overlap was read',
        '{"v":2,"k":"at","l":"Opening 1","c":[{"a":"at:9","u":"https://v.animethemes.moe/Old.webm","h":1080,"sz":1,"r":0}]}',
      ),
    ]) {
      test('a row in the older format ($name) reads as not cached and is resolved again', () async {
        await store.cache('src:tvdb:1', row);
        final r = await resolver.lookup(harbor);
        expect(r.clip?.assetId, 'at:3');
        expect(atCalls, hasLength(1));
        final saved = jsonDecode((await store.cached('src:tvdb:1'))!) as Map<String, dynamic>;
        expect(saved['v'], ClipResolver.sourceFormat);
      });
    }

    test('a cached row with a malformed candidate is resolved again', () async {
      await store.cache(
        'src:tvdb:1',
        jsonEncode({
          'v': ClipResolver.sourceFormat,
          'k': 'at',
          'l': 'Opening 1',
          'c': [
            {
              'a': 'at:3',
              'u': 'http://insecure.example/x.webm',
              'h': 1080,
              'sz': 1,
              'tr': false,
              'nc': true,
              'cc': false,
              'so': null,
            },
          ],
        }),
      );
      expect((await resolver.lookup(harbor)).clip?.assetId, 'at:3');
      expect(atCalls, hasLength(1));
    });

    test('an opening with the episode over it is never stored; a transition is, as the fallback', () async {
      atRecords = {
        101: {
          'animethemes': [
            {
              'type': 'OP',
              'sequence': 1,
              'animethemeentries': [
                {
                  'episodes': '1-12',
                  'videos': [video(1, 1080, overlap: 'OVER'), video(2, 1080, overlap: 'TRANS')],
                },
              ],
            },
          ],
        },
      };
      final clip = (await resolver.lookup(harbor)).clip;
      expect(clip?.assetId, 'at:2');
      expect(clip?.candidates.map((c) => c.assetId), ['at:2']);
      expect(clip?.candidates.single.transition, isTrue);
    });

    test('only episode footage over the opening: the title falls to the next rung', () async {
      atRecords = {
        101: {
          'animethemes': [
            {
              'type': 'OP',
              'sequence': 1,
              'animethemeentries': [
                {
                  'episodes': '1-12',
                  'videos': [video(1, 1080, overlap: 'OVER')],
                },
              ],
            },
          ],
        },
      };
      servers.extrasByKey['a:5'] = [_x('90', 'Harbor Lights Trailer')];
      expect((await resolver.lookup(harbor)).clip?.assetId, 'plex:90');
    });

    test('the captions pref re-picks from the cached candidates, with what ranks them kept', () async {
      atRecords = {
        101: {
          'animethemes': [
            {
              'type': 'OP',
              'sequence': 1,
              'animethemeentries': [
                {
                  'episodes': '1-12',
                  'videos': [video(1, 1080, source: 'BD'), video(2, 1080, lyrics: true, source: 'WEB')],
                },
              ],
            },
          ],
        },
      };
      final profile = ValueNotifier<ReelPlaybackProfile>(inner);
      addTearDown(profile.dispose);
      resolver = make(profile: profile);
      final clip = (await resolver.lookup(harbor)).clip!;
      expect(clip.assetId, 'at:1');
      final row = jsonDecode((await store.cached('src:tvdb:1'))!) as Map<String, dynamic>;
      expect((row['c'] as List).last, containsPair('cc', true));
      expect((row['c'] as List).first, containsPair('so', 'BD'));

      profile.value = const ReelPlaybackProfile(screen: ReelScreen.large, maxHeight: 1080, captions: true);
      expect(resolver.repick(clip).assetId, 'at:2');
      expect((await resolver.lookup(harbor)).clip?.assetId, 'at:2');
      expect(atCalls, hasLength(1), reason: 'served from the cached candidates');
    });

    test('Plex trailers are cached in the new format with their one file', () async {
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      final clip = (await resolver.lookup(film())).clip!;
      expect(clip.candidates, isEmpty);
      expect(identical(resolver.repick(clip), clip), isTrue);
      final row = jsonDecode((await store.cached('src:imdb:tt1'))!) as Map<String, dynamic>;
      expect(row, containsPair('v', ClipResolver.sourceFormat));
    });
  });

  group('AnimeThemesClient (GraphQL)', () {
    // A live findAnimeByExternalSite response, recorded once with the
    // client's query; ids, title, link and size replaced with invented ones.
    final fixture = File('test/reel/fixtures/animethemes_graphql_op.json').readAsStringSync();

    test('posts the query to the GraphQL endpoint with the AniList ids as variables', () async {
      late http.Request sent;
      final client = AnimeThemesClient(
        client: MockClient((req) async {
          sent = req;
          return http.Response(fixture, 200);
        }),
      );
      await client.fetch([101, 102]);
      expect(sent.method, 'POST');
      expect(sent.url, Uri.parse('https://graphql.animethemes.moe/'));
      expect(sent.headers['Content-Type'], startsWith('application/json'));
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['query'], contains('findAnimeByExternalSite(site: ANILIST, id: \$ids)'));
      expect(body['variables'], {
        'ids': [101, 102],
      });
    });

    test('the recorded response maps to its AniList id and yields the opening', () async {
      final client = AnimeThemesClient(client: MockClient((_) async => http.Response(fixture, 200)));
      final records = await client.fetch([101, 102]);
      expect(records.keys, [101], reason: 'an id missing from the answer has no record');
      final op = ClipFilter.firstOpening(records[101]!);
      expect(op?.url, 'https://v.animethemes.moe/HarborLights-OP1.webm');
      expect(op?.videoId, 9001);
      expect(op?.song, 'Harbor Lights');
      expect(op?.resolution, 720);
      final video = (((records[101]!['animethemes'] as List).single as Map)['animethemeentries'] as List).single as Map;
      expect((video['videos'] as List).single, containsPair('overlap', 'NONE'));
    });

    test('the recorded response resolves an anime title end to end', () async {
      final client = AnimeThemesClient(client: MockClient((_) async => http.Response(fixture, 200)));
      final r = await ClipResolver(servers: servers, store: store, aniList: (_) async => 101, animeThemes: client.fetch)
          .lookup(
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
      expect(r.clip?.assetId, 'at:9001');
      expect(servers.calls, isEmpty);
    });

    for (final status in [404, 410, 503]) {
      test('a $status throws instead of answering "no record"', () async {
        final client = AnimeThemesClient(client: MockClient((_) async => http.Response('gone', status)));
        await expectLater(client.fetch([101]), throwsA(isA<AnimeThemesUnavailable>()));
      });
    }

    test('a retired endpoint leaves an anime title unknown, never a cached miss', () async {
      final client = AnimeThemesClient(client: MockClient((_) async => http.Response('gone', 410)));
      final r = await ClipResolver(servers: servers, store: store, aniList: (_) async => 101, animeThemes: client.fetch)
          .lookup(
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
      expect(r.answer, ClipAnswer.unknown);
      expect(await store.cached('src:tvdb:7'), isNull);
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

    test('GraphQL errors on a 200 throw, even with partial data', () async {
      final client = AnimeThemesClient(
        client: MockClient(
          (_) async => http.Response(
            '{"errors":[{"message":"Max query complexity should be 10000"}],"data":{"findAnimeByExternalSite":[]}}',
            200,
          ),
        ),
      );
      await expectLater(client.fetch([101]), throwsA(isA<AnimeThemesUnavailable>()));
    });

    for (final (name, body) in [
      ('without the anime list', '{"data":{}}'),
      ('in the old JSON:API shape', '{"anime":[]}'),
      ('with an anime without its themes list', '{"data":{"findAnimeByExternalSite":[{"resources":{"nodes":[]}}]}}'),
      (
        'with videos not shaped as a connection',
        '{"data":{"findAnimeByExternalSite":[{"resources":{"nodes":[{"site":"ANILIST","externalId":101}]},'
            '"animethemes":[{"type":"OP","sequence":1,"animethemeentries":[{"episodes":"1","videos":[]}]}]}]}}',
      ),
      ('that is not JSON', '<html>'),
      (
        'with an overlap this build cannot read',
        '{"data":{"findAnimeByExternalSite":[{"resources":{"nodes":[{"site":"ANILIST","externalId":101}]},'
            '"animethemes":[{"type":"OP","sequence":1,"animethemeentries":[{"episodes":"1","videos":{"nodes":'
            '[{"id":1,"link":"https://v.animethemes.moe/HarborLights-OP1.webm","nc":true,"overlap":"SOMETIMES"}]}}]}]}]}}',
      ),
    ]) {
      test('a response $name throws (a changed schema is never "no opening")', () async {
        final client = AnimeThemesClient(client: MockClient((_) async => http.Response(body, 200)));
        await expectLater(client.fetch([101]), throwsA(isA<AnimeThemesUnavailable>()));
      });
    }

    test('an empty anime list is a sure "no record"', () async {
      final client = AnimeThemesClient(
        client: MockClient((_) async => http.Response('{"data":{"findAnimeByExternalSite":[]}}', 200)),
      );
      expect(await client.fetch([101]), isEmpty);
    });

    test('more than 50 ids go in requests of 50; none makes no request', () async {
      final batches = <List<Object?>>[];
      final client = AnimeThemesClient(
        client: MockClient((req) async {
          batches.add(((jsonDecode(req.body) as Map)['variables'] as Map)['ids'] as List<Object?>);
          return http.Response('{"data":{"findAnimeByExternalSite":[]}}', 200);
        }),
      );
      expect(await client.fetch(const []), isEmpty);
      expect(batches, isEmpty);
      await client.fetch([for (var i = 1; i <= 120; i++) i]);
      expect(batches.map((b) => b.length), [50, 50, 20]);
    });
  });

  group('a deck asks AnimeThemes in one batch (V2-12)', () {
    ReelTitle anime(int n, {bool show = true}) => ReelTitle(
      titleId: 's:tvdb:$n',
      groupKey: 'tvdb:$n',
      title: 'Harbor Lights $n',
      isShow: show,
      anime: true,
      tvdbId: n,
      copies: [ReelCopy(serverId: 'a', ratingKey: '$n')],
    );
    ReelTitle plain(int n) => ReelTitle(
      titleId: 's:tvdb:$n',
      groupKey: 'tvdb:$n',
      title: 'Quiet Valley $n',
      isShow: true,
      tvdbId: n,
      copies: [ReelCopy(serverId: 'a', ratingKey: '$n')],
    );
    Map<String, dynamic> record(int id) => {
      'animethemes': [
        {
          'type': 'OP',
          'sequence': 1,
          'animethemeentries': [
            {
              'episodes': '1-12',
              'videos': [
                {
                  'id': id,
                  'link': 'https://v.animethemes.moe/OP$id.webm',
                  'nc': true,
                  'resolution': 1080,
                  'overlap': 'NONE',
                },
              ],
            },
          ],
        },
      ],
    };

    /// AniList id = 100 + tvdb id; AnimeThemes has a record for every id
    /// except those in [without].
    late Set<int> without;
    late List<List<int>> batches;
    late Completer<void>? gate;
    ClipResolver batched() => make(
      aniList: (t) async => t.tvdbId == null ? null : 100 + t.tvdbId!,
      animeThemes: (ids) async {
        batches.add(ids);
        if (gate case final g?) await g.future;
        if (atFailure case final e?) throw e;
        return {
          for (final id in ids)
            if (!without.contains(id)) id: record(id),
        };
      },
    );

    setUp(() {
      without = {};
      batches = [];
      gate = null;
    });

    test('one request for the deck\'s anime shows; their openings are cached without another', () async {
      final r = batched();
      await r.warm([anime(1), plain(2), anime(3), anime(4, show: false), anime(1), anime(5)]);
      expect(batches, [
        [101, 103, 105],
      ], reason: 'anime shows only, each once, in deck order');
      expect(await store.cached('src:tvdb:1'), contains('at:101'));
      expect(await store.cached('src:tvdb:2'), isNull);

      for (final n in [1, 3, 5]) {
        expect((await r.lookup(anime(n))).clip?.assetId, 'at:${100 + n}');
      }
      expect(batches, hasLength(1), reason: 'every card plays from the batch');
      expect(servers.calls, isEmpty);
    });

    test('more than 50 shows go in requests of 50, in deck order', () async {
      final r = batched();
      await r.warm([for (var n = 1; n <= 120; n++) anime(n)]);
      expect(batches.map((b) => b.length), [50, 50, 20]);
      expect(batches.first.first, 101);
      expect(await store.cached('src:tvdb:120'), contains('at:220'));
    });

    test('a show already cached is not asked about again', () async {
      final r = batched();
      await r.warm([anime(1)]);
      await r.warm([anime(1), anime(2)]);
      expect(batches, [
        [101],
        [102],
      ]);
      await batched().warm([anime(1), anime(2)]);
      expect(batches, hasLength(2), reason: 'a fresh session reads the cached rows');
    });

    test('a show with no opening writes no miss: its Plex extras are still read per title', () async {
      without = {102};
      final r = batched();
      await r.warm([anime(2)]);
      expect(await store.cached('src:tvdb:2'), isNull, reason: 'the Plex rung has not answered yet');

      expect((await r.lookup(anime(2))).answer, ClipAnswer.none);
      expect(batches, hasLength(1), reason: 'the batch answered AnimeThemes for this show');
      expect(servers.calls, ['a:2']);
      expect(await store.cached('src:tvdb:2'), ClipResolver.missRow);
    });

    test('a show with no opening plays its Plex trailer', () async {
      without = {102};
      servers.extrasByKey['a:2'] = [_x('90', 'Harbor Lights 2 Trailer')];
      final r = batched();
      await r.warm([anime(2)]);
      expect((await r.lookup(anime(2))).clip?.assetId, 'plex:90');
      expect(batches, hasLength(1));
    });

    test('a blocked batch writes and keeps nothing; the card asks on its own', () async {
      atFailure = const AnimeThemesUnavailable('429');
      final r = batched();
      await r.warm([anime(1), anime(2)]);
      expect(await store.cached('src:tvdb:1'), isNull);
      expect(await store.cached('src:tvdb:2'), isNull);

      atFailure = null;
      expect((await r.lookup(anime(1))).clip?.assetId, 'at:101');
      expect(batches, [
        [101, 102],
        [101],
      ]);
    });

    test('a card resolving while the batch is in flight waits for it', () async {
      gate = Completer<void>();
      final r = batched();
      final warming = r.warm([anime(1), anime(2)]);
      final card = r.lookup(anime(1));
      await Future<void>.delayed(Duration.zero);
      gate!.complete();
      await warming;
      expect((await card).clip?.assetId, 'at:101');
      expect(batches, [
        [101, 102],
      ], reason: 'no request of its own');
    });

    test('a mapping that could not be read leaves that show to its own lookup', () async {
      final r = make(
        aniList: (t) async => t.tvdbId == 1 ? throw StateError('mapping unavailable') : 100 + t.tvdbId!,
        animeThemes: (ids) async {
          batches.add(ids);
          return {for (final id in ids) id: record(id)};
        },
      );
      await r.warm([anime(1), anime(2)]);
      expect(batches, [
        [102],
      ]);
      expect(await store.cached('src:tvdb:1'), isNull);
    });

    test('an opening marked as a spoiler is not cached by the batch', () async {
      await store.spoiled('s:tvdb:1', 'at:101');
      without = {};
      servers.extrasByKey['a:1'] = [_x('91', 'Harbor Lights 1 Trailer')];
      final r = batched();
      await r.warm([anime(1)]);
      expect(await store.cached('src:tvdb:1'), isNull);
      expect((await r.lookup(anime(1))).clip?.assetId, 'plex:91');
      expect(batches, hasLength(1));
    });
  });

  group('one request at a time per server, AnimeThemes apart (V2-11)', () {
    ReelTitle on(String server, String rk) => ReelTitle(
      titleId: 'm:$server$rk',
      groupKey: 'g:$server$rk',
      title: 'Harbor Lights $rk',
      isShow: false,
      copies: [ReelCopy(serverId: server, ratingKey: rk)],
    );

    test('a second title on a server waits for the read in flight; another server does not', () async {
      for (final k in ['a:1', 'a:2', 'b:3']) {
        servers.extrasByKey[k] = [_x('x${k.substring(2)}', 'Official Trailer')];
      }
      final gate = servers.gates['a:1'] = Completer<void>();
      final first = resolver.resolve(on('a', '1'));
      final second = resolver.resolve(on('a', '2'));
      expect((await resolver.resolve(on('b', '3')))?.assetId, 'plex:x3');
      await pumpEventQueue();
      expect(servers.calls, containsAll(['a:1', 'b:3']));
      expect(servers.calls, isNot(contains('a:2')), reason: 'one read in flight per server');

      gate.complete();
      expect((await first)?.assetId, 'plex:x1');
      expect((await second)?.assetId, 'plex:x2');
      expect(servers.calls.last, 'a:2');
    });

    test('an anime opening never waits behind a server read in flight', () async {
      final gate = servers.gates['a:1'] = Completer<void>();
      final film = resolver.resolve(on('a', '1'));
      final opening = await resolver.resolve(
        const ReelTitle(
          titleId: 's:tvdb:1',
          groupKey: 'tvdb:1',
          title: 'Harbor Lights',
          isShow: true,
          anime: true,
          tvdbId: 1,
          copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
        ),
      );
      expect(opening?.assetId, 'at:9');
      gate.complete();
      await film;
    });

    test('a clip on a server marked slow is not preloadable; one elsewhere is', () async {
      servers.extrasByKey['b:2'] = [_x('80', 'Teaser')];
      servers.extrasByKey['c:4'] = [_x('81', 'Teaser')];
      expect((await resolver.resolve(on('b', '2')))?.source.preloadable, isTrue);

      // Another title's read on the same server times out: it is slow now.
      servers.slow.add('b');
      await resolver.resolve(on('b', '3'));
      expect(resolver.slowServers, {'b'});

      final cached = await resolver.resolve(on('b', '2'));
      expect(cached?.assetId, 'plex:80', reason: 'its cached identity still plays');
      expect(cached?.source.preloadable, isFalse, reason: 'but only once its card is on screen');
      expect((await resolver.resolve(on('c', '4')))?.source.preloadable, isTrue);
    });
  });

  group('resolver failures (V2-62)', () {
    test('a server whose extras read fails is not marked slow; the next copy is used', () async {
      servers.failWith['a'] = const FormatException('bad extras response');
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
      servers.offline.add('a');
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

    test('an unreadable cache entry is resolved again', () async {
      await store.cache('src:imdb:tt1', '{not json');
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      expect((await resolver.resolve(film()))?.assetId, 'plex:87');
      expect(servers.calls, ['a:1']);
    });

    test('at most ${AnimeThemesClient.perMinute} AnimeThemes requests a minute; the rest are unknown', () async {
      var requests = 0;
      final client = AnimeThemesClient(
        client: MockClient((_) async {
          requests++;
          return http.Response('{"data":{"findAnimeByExternalSite":[]}}', 200);
        }),
      );
      var refused = 0;
      for (var i = 0; i < AnimeThemesClient.perMinute + 5; i++) {
        try {
          await client.fetch([101]);
        } on AnimeThemesUnavailable {
          refused++;
        }
      }
      expect(requests, AnimeThemesClient.perMinute);
      expect(refused, 5, reason: 'past the cap a lookup is unknown, never "no record"');
      expect(AnimeThemesClient.perMinute, lessThan(90), reason: "under the API's 90 a minute");
    });
  });

  group('a neighbouring deck head, without a Plex read (V2-09, D15)', () {
    const anime = ReelTitle(
      titleId: 's:tvdb:1',
      groupKey: 'tvdb:1',
      title: 'Harbor Lights',
      isShow: true,
      anime: true,
      tvdbId: 1,
      copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
    );

    test('an anime show with no row asks AnimeThemes only, and caches the opening it finds', () async {
      final clip = await resolver.lookupWithoutServers(anime);
      expect(clip?.source.origin, ClipOrigin.animeTheme);
      expect(clip?.source.uri, 'https://v.animethemes.moe/Show-OP1.webm');
      expect(servers.calls, isEmpty, reason: 'no Plex read');
      expect(atCalls, [
        [101],
      ]);
      // The real lookup then plays the same clip from the row.
      expect((await resolver.resolve(anime))?.source.uri, clip?.source.uri);
      expect(servers.calls, isEmpty);
      expect(atCalls, hasLength(1));
    });

    test('an anime show with no opening is no head, and nothing is cached', () async {
      atRecords = {};
      expect(await resolver.lookupWithoutServers(anime), isNull);
      expect(servers.calls, isEmpty);
      expect(await store.cached('src:tvdb:1', ttl: ReelStore.sourceTtl), isNull, reason: 'Plex was never asked');
    });

    test('a title with no row that is not an anime show is no head, and nothing is read', () async {
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      expect(await resolver.lookupWithoutServers(film()), isNull);
      expect(servers.calls, isEmpty);
      expect(atCalls, isEmpty);
    });

    test('a Plex clip carries a disk cache key with no token or address; an opening none (V2-10)', () async {
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      final clip = await resolver.resolve(film());
      expect(clip?.source.cacheKey, 'plex:a:/services/iva/assets/87/video.mp4');
      expect(clip?.source.uri, contains('token='));
      expect(clip?.source.cacheKey, isNot(contains('token')));
      expect(clip?.source.cacheKey, isNot(contains('.example')));
      // Read back from the row: the same key.
      expect(
        (await resolver.lookupWithoutServers(film(), onDisk: (_) async => true))?.source.cacheKey,
        clip?.source.cacheKey,
      );
      final opening = await resolver.resolve(anime);
      expect(opening?.source.origin, ClipOrigin.animeTheme);
      expect(opening?.source.cacheKey, isNull);
    });

    test('a cached Plex clip is a head only when its bytes are on disk', () async {
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      await resolver.resolve(film());
      servers.calls.clear();
      expect(await resolver.lookupWithoutServers(film()), isNull);
      final onDisk = await resolver.lookupWithoutServers(film(), onDisk: (c) async => c.assetId == 'plex:87');
      expect(onDisk?.assetId, 'plex:87');
      expect(servers.calls, isEmpty);
    });

    test('a cached miss, or a spoiled or failed asset, is no head', () async {
      await resolver.resolve(anime);
      expect(await resolver.lookupWithoutServers(anime, exclude: {'at:9'}), isNull);
      await store.cache('src:imdb:tt1', ClipResolver.missRow);
      expect(await resolver.lookupWithoutServers(film()), isNull);
    });

    test('a cached opening needs no AnimeThemes call either', () async {
      await resolver.resolve(anime);
      atCalls.clear();
      expect((await resolver.lookupWithoutServers(anime))?.source.origin, ClipOrigin.animeTheme);
      expect(atCalls, isEmpty);
    });
  });

  group('offline, a clip from this device alone (V2-15)', () {
    const anime = ReelTitle(
      titleId: 's:tvdb:1',
      groupKey: 'tvdb:1',
      title: 'Harbor Lights',
      isShow: true,
      anime: true,
      tvdbId: 1,
      copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
    );
    Future<bool> anyOnDisk(ResolvedClip _) async => true;

    test('a Plex clip on disk opens at an address that never resolves, by its cache key, with no token', () async {
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      final online = await resolver.resolve(film());
      servers
        ..calls.clear()
        ..offline.add('a');
      final row = await store.cached('src:imdb:tt1', ttl: ReelStore.sourceTtl);

      final clip = await resolver.lookupOnDisk(film(), onDisk: (c) async => c.assetId == 'plex:87');
      expect(clip?.source.uri, 'https://reel-offline.invalid/services/iva/assets/87/video.mp4');
      expect(clip?.source.uri, isNot(contains('token')));
      expect(clip?.source.cacheKey, online?.source.cacheKey);
      expect(clip?.assetId, 'plex:87');
      expect(servers.calls, isEmpty, reason: 'no server read');
      expect(await store.cached('src:imdb:tt1', ttl: ReelStore.sourceTtl), row, reason: 'nothing written');
    });

    test('a connected server still gives its own address (the uncached rest can stream)', () async {
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      await resolver.resolve(film());
      final clip = await resolver.lookupOnDisk(film(), onDisk: anyOnDisk);
      expect(clip?.source.uri, 'https://a.example/services/iva/assets/87/video.mp4?token=x');
    });

    test('a Plex clip not on disk is a still', () async {
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      await resolver.resolve(film());
      servers.offline.add('a');
      expect(await resolver.lookupOnDisk(film(), onDisk: (_) async => false), isNull);
    });

    test('no row asks nobody and writes no miss', () async {
      servers.offline.add('a');
      var asked = 0;
      expect(
        await resolver.lookupOnDisk(
          film(),
          onDisk: (_) async {
            asked++;
            return true;
          },
        ),
        isNull,
      );
      expect(await resolver.lookupOnDisk(anime, onDisk: anyOnDisk), isNull, reason: 'AnimeThemes is not asked');
      expect(asked, 0);
      expect(servers.calls, isEmpty);
      expect(atCalls, isEmpty);
      expect(await store.cached('src:imdb:tt1', ttl: ReelStore.sourceTtl), isNull);
      expect(await store.cached('src:tvdb:1', ttl: ReelStore.sourceTtl), isNull);
    });

    test('a cached opening (memory only, D1), a miss or a spoiled asset is a still', () async {
      await resolver.resolve(anime);
      atCalls.clear();
      expect(await resolver.lookupOnDisk(anime, onDisk: anyOnDisk), isNull);
      expect(atCalls, isEmpty);
      await store.cache('src:imdb:tt1', ClipResolver.missRow);
      expect(await resolver.lookupOnDisk(film(), onDisk: anyOnDisk), isNull);
      servers.extrasByKey['a:1'] = [_x('87', 'Trailer')];
      await store.cache('src:imdb:tt1', '');
      await resolver.resolve(film());
      expect(await resolver.lookupOnDisk(film(), exclude: {'plex:87'}, onDisk: anyOnDisk), isNull);
    });
  });

  group('a trailer\'s lead-in rides on its src: row (V2-23)', () {
    Future<Map<String, dynamic>> row() async =>
        jsonDecode((await store.cached('src:imdb:tt1'))!) as Map<String, dynamic>;

    Future<void> writeRow(Map<String, dynamic> extra) async {
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      await resolver.resolve(film());
      final j = await row()
        ..remove('li')
        ..remove('lv')
        ..remove('lr');
      await store.cache('src:imdb:tt1', jsonEncode({...j, ...extra}));
    }

    test('a row with li and lv gives the clip its start; 0 is measured with no lead-in', () async {
      await writeRow({'li': 6006, 'lv': ClipResolver.leadInVersion});
      expect((await make().resolve(film()))?.source.startAt, const Duration(milliseconds: 6006));
      await writeRow({'li': 0, 'lv': ClipResolver.leadInVersion});
      expect((await make().resolve(film()))?.source.startAt, Duration.zero);
    });

    test('offline, a clip on disk keeps its lead-in like the online lookup (V2-15)', () async {
      Future<bool> anyOnDisk(ResolvedClip _) async => true;
      await writeRow({'li': 6006, 'lv': ClipResolver.leadInVersion});
      servers.offline.add('a');
      final clip = await make().lookupOnDisk(film(), onDisk: anyOnDisk);
      expect(clip?.source.uri, startsWith('https://reel-offline.invalid/'));
      expect(clip?.source.startAt, const Duration(milliseconds: 6006));
      servers.offline.remove('a');
      await writeRow({'li': 6006});
      servers.offline.add('a');
      expect((await make().lookupOnDisk(film(), onDisk: anyOnDisk))?.source.startAt, isNull, reason: 'not measured');
    });

    test('an out-of-range li, another lv or the wrong type reads as not measured', () async {
      for (final extra in [
        {'li': 16000, 'lv': ClipResolver.leadInVersion},
        {'li': 200, 'lv': ClipResolver.leadInVersion},
        {'li': 6006, 'lv': ClipResolver.leadInVersion + 1},
        {'li': '6006', 'lv': ClipResolver.leadInVersion},
        {'li': 6006},
      ]) {
        await writeRow(extra);
        expect((await make().resolve(film()))?.source.startAt, isNull, reason: '$extra');
      }
    });

    test('an older row with no li still resolves from the cache, in the same format', () async {
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      await resolver.resolve(film());
      expect((await row()).containsKey('li'), isFalse);
      expect((await row())['v'], ClipResolver.sourceFormat);
      servers.calls.clear();
      final again = await make().resolve(film());
      expect(again?.source.startAt, isNull);
      expect(servers.calls, isEmpty, reason: 'no re-resolve for an older row');
    });

    test('rememberLeadIn writes only on the measured clip\'s row and keeps its age', () async {
      var now = DateTime(2026, 1, 10);
      final settings = LocalCustomisationStore(db);
      store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
      resolver = make();
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      final clip = (await resolver.resolve(film()))!;
      final writtenAt = await store.cachedAt('src:imdb:tt1');

      now = now.add(const Duration(days: 29));
      expect(await resolver.rememberLeadIn(film(), clip, const Duration(milliseconds: 6006)), isTrue);
      expect((await row())['li'], 6006);
      expect((await row())['lv'], ClipResolver.leadInVersion);
      expect(await store.cachedAt('src:imdb:tt1'), writtenAt, reason: 'the 30-day identity TTL is never extended');
      now = now.add(const Duration(days: 2));
      expect(await store.cached('src:imdb:tt1', ttl: ReelStore.sourceTtl), isNull, reason: 'it still expires on time');

      // Another file under the same title: never written.
      now = DateTime(2026, 1, 10);
      await store.cache('src:imdb:tt1', jsonEncode({...await row(), 'a': 'plex:79'}));
      expect(await resolver.rememberLeadIn(film(), clip, const Duration(milliseconds: 4000)), isFalse);
      expect((await row())['li'], 6006);
    });

    test('a 0 keeps its reason; an AnimeThemes clip is never written', () async {
      servers.extrasByKey['a:1'] = [_x('78', 'Official Trailer')];
      final clip = (await resolver.resolve(film()))!;
      await resolver.rememberLeadIn(film(), clip, Duration.zero, reason: 'hdr');
      expect((await row())['li'], 0);
      expect((await row())['lr'], 'hdr');
      final theme = ResolvedClip(
        source: const ClipSource(uri: 'https://v.example/op.webm', origin: ClipOrigin.animeTheme),
        assetId: 'at:9',
        kind: ClipKind.opening,
      );
      expect(await resolver.rememberLeadIn(film(), theme, const Duration(milliseconds: 6006)), isFalse);
    });
  });
}
