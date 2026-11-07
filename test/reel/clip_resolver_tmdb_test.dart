import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/reel/clip_filter.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/feed_youtube.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/reel/reel_tmdb.dart';

/// The TMDB trailer rung (plan V2-63): after the Plex extras, the phone
/// only, cached in `src:` under the V2-56 rules.
class _Servers implements ReelServers {
  final Map<String, List<PlexExtraClip>> extrasByKey = {};
  final Set<String> offline = {};
  final List<String> calls = [];

  @override
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout}) async {
    if (offline.contains(serverId)) throw ReelServerUnavailable(serverId);
    calls.add('$serverId:$ratingKey');
    return extrasByKey['$serverId:$ratingKey'] ?? const [];
  }

  @override
  String? clipUrl(String serverId, String partKey) => 'https://$serverId.example$partKey';
}

Map<String, Object?> _video(
  String key, {
  String type = 'Trailer',
  bool official = true,
  String lang = 'en',
  String date = '2020-01-01T00:00:00.000Z',
  String name = 'Official Trailer',
}) => {
  'iso_639_1': lang,
  'iso_3166_1': 'US',
  'name': name,
  'key': key,
  'site': 'YouTube',
  'size': 1080,
  'type': type,
  'official': official,
  'published_at': date,
  'id': 'v-$key',
};

void main() {
  late ForkDatabase db;
  late ReelStore store;
  late _Servers servers;
  late List<({int id, bool show, String language})> tmdbCalls;
  late List<dynamic>? tmdbResults;
  late Object? tmdbFailure;
  late bool rungOn;

  ClipResolver make({bool withRung = true}) => ClipResolver(
    servers: servers,
    store: store,
    aniList: (_) async => null,
    animeThemes: (_) async => const {},
    tmdb: withRung
        ? ReelTmdbRung(
            fetch: ({required id, required show, required language}) async {
              tmdbCalls.add((id: id, show: show, language: language));
              if (tmdbFailure case final e?) throw e;
              return tmdbResults;
            },
            on: () => rungOn,
            language: () => 'en',
          )
        : null,
  );

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    store = ReelStore(database: () async => db, settings: () async => settings);
    servers = _Servers();
    tmdbCalls = [];
    tmdbResults = [_video('AbCdEfGhIj1')];
    tmdbFailure = null;
    rungOn = true;
  });

  tearDown(() => db.close());

  const show = ReelTitle(
    titleId: 's:tvdb:7',
    groupKey: 'tvdb:7',
    title: 'Harbor Lights',
    isShow: true,
    tmdbId: 4242,
    copies: [ReelCopy(serverId: 'a', ratingKey: '5')],
  );

  Future<Map<String, dynamic>?> row() async {
    final raw = await store.cached('src:${show.groupKey}', ttl: ReelStore.sourceTtl);
    return raw == null || raw.isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  test('a title with no server trailer plays TMDB\'s, as a YouTube clip that is never preloaded', () async {
    final r = make();
    final found = await r.lookup(show);
    expect(found.answer, ClipAnswer.found);
    final clip = found.clip!;
    expect(clip.source.origin, ClipOrigin.youtube);
    expect(clip.source.preloadable, isFalse);
    expect(clip.assetId, 'yt:AbCdEfGhIj1');
    expect(clip.kind, ClipKind.trailer);
    expect(clip.number, isNull);
    expect(ReelYouTube.idOf(Uri.parse(clip.source.uri)), 'AbCdEfGhIj1');
    expect(tmdbCalls.single, (id: 4242, show: true, language: 'en'));
    expect(await row(), {
      'v': ClipResolver.sourceFormat,
      'k': 'yt',
      'a': 'yt:AbCdEfGhIj1',
      'lk': 'trailer',
      'yk': 'AbCdEfGhIj1',
    });

    // Cached: the next lookup asks nobody.
    servers.calls.clear();
    final again = await make().lookup(show);
    expect(again.clip!.assetId, 'yt:AbCdEfGhIj1');
    expect(servers.calls, isEmpty);
    expect(tmdbCalls, hasLength(1));
  });

  test('a cached YouTube trailer is never a neighbouring deck head: it has nothing to preload (V2-09)', () async {
    await make().lookup(show);
    expect((await row())?['k'], 'yt');
    servers.calls.clear();
    tmdbCalls.clear();
    expect(await make().lookupWithoutServers(show, onDisk: (_) async => true), isNull);
    expect(servers.calls, isEmpty);
    expect(tmdbCalls, isEmpty);
  });

  test('a server trailer comes first: TMDB is not asked', () async {
    servers.extrasByKey['a:5'] = [
      const PlexExtraClip(ratingKey: '9', title: 'Trailer', partKey: '/p/9.mp4', subtype: 'trailer'),
    ];
    final found = await make().lookup(show);
    expect(found.clip!.source.origin, ClipOrigin.plexExtra);
    expect(tmdbCalls, isEmpty);
  });

  test('TMDB is asked only once every server answered: an offline server leaves the title unknown', () async {
    servers.offline.add('a');
    final found = await make().lookup(show);
    expect(found.answer, ClipAnswer.unknown);
    expect(tmdbCalls, isEmpty);
    expect(await row(), isNull);
  });

  test('TMDB with no trailer to play is a miss that says TMDB answered', () async {
    tmdbResults = [_video('ClipOnly0001', type: 'Clip'), _video('Unofficial01', official: false)];
    final found = await make().lookup(show);
    expect(found.answer, ClipAnswer.none);
    expect(await store.cached('src:${show.groupKey}', ttl: ReelStore.sourceTtl), ClipResolver.missRowWithTmdb);

    // A miss TMDB answered is never asked again.
    tmdbCalls.clear();
    expect((await make().lookup(show)).answer, ClipAnswer.none);
    expect(tmdbCalls, isEmpty);
  });

  test('a TMDB that can\'t answer leaves the title unknown, keeping the servers\' no', () async {
    tmdbFailure = const TmdbUnavailable('HTTP 503');
    final found = await make().lookup(show);
    expect(found.answer, ClipAnswer.unknown);
    // The servers' answer is kept (TMDB not marked as asked), never a
    // 30-day miss for TMDB.
    expect(await store.cached('src:${show.groupKey}', ttl: ReelStore.sourceTtl), ClipResolver.missRow);

    // Next time only TMDB is asked: no server read.
    tmdbFailure = null;
    servers.calls.clear();
    final later = await make().lookup(show);
    expect(later.clip!.assetId, 'yt:AbCdEfGhIj1');
    expect(servers.calls, isEmpty);
  });

  test('a miss cached before the rung (or while it was off) asks TMDB alone', () async {
    await store.cache('src:${show.groupKey}', ClipResolver.missRow);
    final found = await make().lookup(show);
    expect(found.clip!.source.origin, ClipOrigin.youtube);
    expect(servers.calls, isEmpty);
    expect((await row())!['k'], 'yt');
  });

  test('with the rung off (Data saver, Stills only) TMDB is not asked and the miss leaves it unasked', () async {
    rungOn = false;
    final found = await make().lookup(show);
    expect(found.answer, ClipAnswer.none);
    expect(tmdbCalls, isEmpty);
    expect(await store.cached('src:${show.groupKey}', ttl: ReelStore.sourceTtl), ClipResolver.missRow);

    // Back on: the trailer is found without a server read.
    rungOn = true;
    servers.calls.clear();
    expect((await make().lookup(show)).clip!.assetId, 'yt:AbCdEfGhIj1');
    expect(servers.calls, isEmpty);
  });

  test('a cached YouTube trailer while the rung is off is an AI card for now; the row is kept', () async {
    await make().lookup(show);
    rungOn = false;
    final found = await make().lookup(show);
    expect(found.answer, ClipAnswer.unknown);
    expect((await row())!['k'], 'yt');
  });

  test('the TV has no rung: a server miss is a miss, as before', () async {
    final found = await make(withRung: false).lookup(show);
    expect(found.answer, ClipAnswer.none);
    expect(tmdbCalls, isEmpty);
    expect(await store.cached('src:${show.groupKey}', ttl: ReelStore.sourceTtl), ClipResolver.missRow);
  });

  test('no TMDB key: the rung is skipped and the servers\' no stands', () async {
    tmdbResults = null;
    final found = await make().lookup(show);
    expect(found.answer, ClipAnswer.none);
    expect(await store.cached('src:${show.groupKey}', ttl: ReelStore.sourceTtl), ClipResolver.missRow);
  });

  test('no TMDB id is a sure no', () async {
    const noId = ReelTitle(
      titleId: 'm:imdb:tt9',
      groupKey: 'imdb:tt9',
      title: 'Quiet Meadow',
      isShow: false,
      copies: [ReelCopy(serverId: 'a', ratingKey: '6')],
    );
    expect((await make().lookup(noId)).answer, ClipAnswer.none);
    expect(tmdbCalls, isEmpty);
    expect(await store.cached('src:${noId.groupKey}', ttl: ReelStore.sourceTtl), ClipResolver.missRowWithTmdb);
  });

  test('a failed trailer is excluded and TMDB alone picks the next one, with no server read', () async {
    tmdbResults = [
      _video('First000001', date: '2019-01-01T00:00:00.000Z'),
      _video('Second00002', date: '2020-01-01T00:00:00.000Z'),
    ];
    final r = make();
    expect((await r.lookup(show)).clip!.assetId, 'yt:First000001');
    servers.calls.clear();
    final next = await r.lookup(show, exclude: {'yt:First000001'});
    expect(next.clip!.assetId, 'yt:Second00002');
    expect(servers.calls, isEmpty);
    expect((await row())!['yk'], 'Second00002');
  });

  test('keys that are not YouTube ids never reach the player page', () async {
    tmdbResults = [_video('bad"key<script>'), _video('Good0000001', date: '2021-01-01T00:00:00.000Z')];
    expect((await make().lookup(show)).clip!.assetId, 'yt:Good0000001');
  });

  test('a cached row whose key is not a YouTube id is resolved again', () async {
    await store.cache(
      'src:${show.groupKey}',
      jsonEncode({'v': ClipResolver.sourceFormat, 'k': 'yt', 'a': 'yt:x"y', 'l': 'Trailer', 'yk': 'x"y'}),
    );
    expect((await make().lookup(show)).clip!.assetId, 'yt:AbCdEfGhIj1');
  });

  test('a teaser is a teaser, and its row keeps the kind, never the words', () async {
    tmdbResults = [_video('Teaser00001', type: 'Teaser', name: 'Teaser')];
    expect((await make().lookup(show)).clip!.kind, ClipKind.teaser);
    expect((await row())!['lk'], 'teaser');
    expect((await row())!.containsKey('l'), isFalse);
    expect((await make().lookup(show)).clip!.kind, ClipKind.teaser);
  });

  test('a YouTube row cached with the older English label still reads its kind', () async {
    await store.cache(
      'src:${show.groupKey}',
      jsonEncode({
        'v': ClipResolver.sourceFormat,
        'k': 'yt',
        'a': 'yt:Teaser00001',
        'l': 'Teaser',
        'yk': 'Teaser00001',
      }),
    );
    final clip = (await make().lookup(show)).clip!;
    expect(clip.assetId, 'yt:Teaser00001');
    expect(clip.kind, ClipKind.teaser);
    expect(tmdbCalls, isEmpty);
  });

  test('known misses: a miss TMDB hasn\'t answered is not one while the rung is on', () async {
    await store.cache('src:${show.groupKey}', ClipResolver.missRow);
    expect(await make().knownMisses([show]), isEmpty);
    rungOn = false;
    expect(await make().knownMisses([show]), {show.groupKey});
    expect(await make(withRung: false).knownMisses([show]), {show.groupKey});
    rungOn = true;
    await store.cache('src:${show.groupKey}', ClipResolver.missRowWithTmdb);
    expect(await make().knownMisses([show]), {show.groupKey});
  });
}
