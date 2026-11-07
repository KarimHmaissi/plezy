import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart' show EpisodePosterMode;
import 'package:plezy/services/system_shelf_service.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';

class _ShelfClient implements MediaServerClient {
  _ShelfClient({this.throwOnThumbnail = false});

  final bool throwOnThumbnail;
  final List<({String? path, int? width, int? height})> thumbnailRequests = [];

  @override
  ServerId get serverId => ServerId('server-a');

  @override
  String get serverName => 'Server';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (throwOnThumbnail) throw StateError('conversion failed');
    thumbnailRequests.add((path: path, width: width, height: height));
    return 'https://media.invalid$path?token=transient';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/system_shelf');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // The real Plex/Jellyfin client fixtures used by the updateSources tests
  // construct their API caches at creation time.
  setUpAll(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    addTearDown(db.close);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('delayed support result is dropped after synchronous owner invalidation', () async {
    final support = Completer<bool>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isSupported: () => support.future);
    service.beginProfileSession('owner-a');

    final delayed = service.syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient());
    final ended = service.endProfileSession('owner-a');
    support.complete(true);

    expect(await delayed, isFalse);
    await ended;
    expect(calls.map((call) => call.method), ['clear']);
    expect(calls.single.arguments, {
      'schemaVersion': SystemShelfService.schemaVersion,
      'ownerId': 'owner-a',
      'generation': 2,
    });
    expect(await service.syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient()), isFalse);
  });

  test('dispatched old sync settles before clear and new owner sync', () async {
    final syncDispatched = Completer<void>();
    final releaseOldSync = Completer<void>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'sync' && !syncDispatched.isCompleted) {
        syncDispatched.complete();
        await releaseOldSync.future;
      }
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isSupported: () async => true);
    service.beginProfileSession('owner-a');
    final oldSync = service.syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient());
    await syncDispatched.future;

    final oldEnd = service.endProfileSession('owner-a');
    service.beginProfileSession('owner-b');
    final newSync = service.syncFromContinueWatching('owner-b', const [], (_) => _ShelfClient());
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((call) => call.method), ['sync']);

    releaseOldSync.complete();
    expect(await oldSync, isTrue);
    await oldEnd;
    expect(await newSync, isTrue);
    expect(calls.map((call) => call.method), ['sync', 'clear', 'sync']);
    expect((calls.last.arguments as Map)['ownerId'], 'owner-b');
  });

  test('native failure is contained and the ordered tail accepts a later sync', () async {
    var syncCount = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'sync' && syncCount++ == 0) {
        throw PlatformException(code: 'first-failed');
      }
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isSupported: () async => true);
    service.beginProfileSession('owner-a');

    expect(await service.syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient()), isFalse);
    expect(await service.syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient()), isTrue);
    expect(syncCount, 2);
  });

  test('versioned payload carries transient source only and conversion failure keeps metadata', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isSupported: () async => true);
    service.beginProfileSession('owner-a');
    final item = testMediaItem(
      id: 'item-a',
      backend: MediaBackend.plex,
      title: 'Private title',
      summary: 'Private summary',
      thumbPath: '/poster',
      serverId: 'server-a',
      serverName: 'Server',
    );

    final client = _ShelfClient();
    expect(await service.syncFromContinueWatching('owner-a', [item], (_) => client), isTrue);
    final envelope = calls.single.arguments as Map;
    expect(envelope['schemaVersion'], 3);
    expect(envelope['schemaVersion'], SystemShelfService.schemaVersion);
    expect(envelope['ownerId'], 'owner-a');
    expect(envelope['sectionTitle'], 'Continue Watching');
    final sent = (envelope['items'] as List).single as Map;
    expect(sent['posterSourceUri'], startsWith('https://media.invalid/'));
    expect(sent, isNot(contains('posterUri')));
    expect(client.thumbnailRequests.single, (path: '/poster', width: 1280, height: 720));

    calls.clear();
    expect(
      await service.syncFromContinueWatching('owner-a', [item], (_) => _ShelfClient(throwOnThumbnail: true)),
      isTrue,
    );
    final fallback = (((calls.single.arguments as Map)['items'] as List).single as Map);
    expect(fallback['title'], 'Private title');
    expect(fallback['posterSourceUri'], isNull);
  });

  test('unsupported integration completes without native mutation', () async {
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls++;
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isSupported: () async => false);
    service.beginProfileSession('owner-a');
    expect(await service.syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient()), isFalse);
    expect(nativeCalls, 0);
  });

  MediaItem shelfEpisode({String? parentThumbPath, String? grandparentThumbPath}) => testMediaItem(
    id: 'ep-1',
    backend: MediaBackend.plex,
    kind: MediaKind.episode,
    title: 'Finale',
    grandparentTitle: 'Show',
    parentThumbPath: parentThumbPath,
    grandparentThumbPath: grandparentThumbPath,
    grandparentArtPath: '/spoiler-safe-art',
    thumbPath: '/episode-still',
    serverId: 'server-a',
    serverName: 'Server',
  );

  for (final (mode, posters) in [
    (EpisodePosterMode.seasonPoster, ['/season-poster', '/series-poster', '/episode-still']),
    // Every other setting gets the series poster, as in Plex's own Top Shelf
    // (#2377): an episode still cannot fill a 2:3 slot.
    (EpisodePosterMode.seriesPoster, ['/series-poster', '/series-poster', '/episode-still']),
    (EpisodePosterMode.episodeThumbnail, ['/series-poster', '/series-poster', '/episode-still']),
  ]) {
    test('tvOS target with ${mode.name} walks its poster chain at 600x900 and skips the spoiler override', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => true);
      final client = _ShelfClient();
      final service = SystemShelfService.forTesting(
        channel: channel,
        isSupported: () async => true,
        isTvosTarget: () => true,
      );
      service.beginProfileSession('owner-a');

      expect(
        await service.syncFromContinueWatching(
          'owner-a',
          [
            shelfEpisode(parentThumbPath: '/season-poster', grandparentThumbPath: '/series-poster'),
            shelfEpisode(grandparentThumbPath: '/series-poster'),
            shelfEpisode(),
          ],
          (_) => client,
          // Unwatched episodes would take the spoiler-safe art on Android;
          // posters cannot spoil, so tvOS must ignore the flag entirely.
          hideSpoilers: true,
          episodePosterMode: mode,
        ),
        isTrue,
      );

      expect(client.thumbnailRequests.map((request) => request.path), posters);
      for (final request in client.thumbnailRequests) {
        expect((request.width, request.height), (600, 900));
      }
    });
  }

  test('non-tvOS target publishes 1280x720 episode thumbnails and the spoiler-safe override', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => true);
    final client = _ShelfClient();
    final service = SystemShelfService.forTesting(
      channel: channel,
      isSupported: () async => true,
      isTvosTarget: () => false,
    );
    service.beginProfileSession('owner-a');
    final episode = shelfEpisode(parentThumbPath: '/season-poster', grandparentThumbPath: '/series-poster');

    expect(await service.syncFromContinueWatching('owner-a', [episode], (_) => client, hideSpoilers: true), isTrue);
    expect(await service.syncFromContinueWatching('owner-a', [episode], (_) => client), isTrue);

    expect(client.thumbnailRequests.map((request) => request.path), ['/spoiler-safe-art', '/episode-still']);
    for (final request in client.thumbnailRequests) {
      expect((request.width, request.height), (1280, 720));
    }
  });

  test('updateSources publishes per-kind descriptors and skips unusable clients', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isTvosTarget: () => true);
    service.beginProfileSession('owner-a');

    final plex = testPlexClient(
      serverId: ServerId('plex-1'),
      serverName: 'Plex Server',
      baseUrl: 'https://plex.example.com',
      token: 'plex-token',
    );
    final jellyfin = testJellyfinClient(
      connection: testJellyfinConnection(
        machineId: 'jf-1',
        userId: 'user-7',
        serverName: 'Jellyfin Server',
        baseUrl: 'https://jf.example.com',
        accessToken: 'jf-token',
      ),
    );
    final emby = testEmbyClient(
      connection: testEmbyConnection(machineId: 'emby-1', userId: 'emby-user', accessToken: 'emby-token'),
    );
    final tokenlessPlex = testPlexClient(serverId: ServerId('plex-2'), token: null);
    final tokenlessJellyfin = testJellyfinClient(
      connection: testJellyfinConnection(machineId: 'jf-2', accessToken: ''),
    );
    final unknownBackend = _ShelfClient();

    expect(
      await service.syncServerSources('owner-a', [
        plex,
        jellyfin,
        emby,
        tokenlessPlex,
        tokenlessJellyfin,
        unknownBackend,
      ]),
      isTrue,
    );

    expect(calls.single.method, 'updateSources');
    final envelope = calls.single.arguments as Map;
    expect(envelope['schemaVersion'], 3);
    expect(envelope['ownerId'], 'owner-a');
    expect(envelope['generation'], 1);
    expect(envelope['maxItems'], 20);
    expect(envelope['sectionTitle'], 'Continue Watching');
    expect(envelope['episodePoster'], 'series');
    final servers = (envelope['servers'] as List).cast<Map>();
    expect(servers, hasLength(3));
    expect(servers[0], {
      'serverId': 'plex-1',
      'kind': 'plex',
      'name': 'Plex Server',
      'baseUrl': 'https://plex.example.com',
      'token': 'plex-token',
    });
    expect(servers[1], {
      'serverId': 'jf-1',
      'kind': 'jellyfin',
      'name': 'Jellyfin Server',
      'baseUrl': 'https://jf.example.com',
      'token': 'jf-token',
      'userId': 'user-7',
    });
    expect(servers[2]['kind'], 'emby');
    expect(servers[2]['userId'], 'emby-user');
    expect(servers[2]['token'], 'emby-token');
  });

  test('updateSources tells the extension to use season posters only under that setting', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isTvosTarget: () => true);
    service.beginProfileSession('owner-a');
    final plex = testPlexClient(baseUrl: 'https://plex.example.com', token: 'plex-token');

    for (final mode in EpisodePosterMode.values) {
      expect(await service.syncServerSources('owner-a', [plex], episodePosterMode: mode), isTrue);
    }

    expect(calls.map((call) => (call.arguments as Map)['episodePoster']), ['series', 'season', 'series']);
  });

  test('syncServerSources is a no-op off tvOS', () async {
    var nativeCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls++;
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isTvosTarget: () => false);
    service.beginProfileSession('owner-a');

    expect(await service.syncServerSources('owner-a', [testPlexClient()]), isFalse);
    expect(nativeCalls, 0);
  });

  test('sources built for an invalidated owner are never dispatched', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = SystemShelfService.forTesting(channel: channel, isTvosTarget: () => true);
    service.beginProfileSession('owner-a');

    final pending = service.syncServerSources('owner-a', [testPlexClient()]);
    final ended = service.endProfileSession('owner-a');

    expect(await pending, isFalse);
    await ended;
    expect(calls.map((call) => call.method), ['clear']);
  });

  group('Watch Next cap and stable engagement (A1)', () {
    List<Map> sentItems(List<MethodCall> calls) =>
        ((calls.lastWhere((c) => c.method == 'sync').arguments as Map)['items'] as List).cast<Map>();

    MediaItem onDeck(int i, {int? lastViewedAt}) => testMediaItem(
      id: 'ep-$i',
      kind: MediaKind.episode,
      title: 'Episode $i',
      grandparentTitle: 'Show $i',
      serverId: 'server-a',
      serverName: 'Server',
      lastViewedAt: lastViewedAt,
    );

    test('61 on-deck items publish one sync of at most 20, in the original order', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final service = SystemShelfService.forTesting(channel: channel, isSupported: () async => true);
      service.beginProfileSession('owner-a');
      final items = [for (var i = 0; i < 61; i++) onDeck(i, lastViewedAt: 1700000000 - i)];

      expect(await service.syncFromContinueWatching('owner-a', items, (_) => _ShelfClient()), isTrue);

      expect(calls.where((c) => c.method == 'sync'), hasLength(1));
      final sent = sentItems(calls);
      expect(sent, hasLength(SystemShelf.maxItems));
      expect(SystemShelf.maxItems, 20);
      expect(sent.map((m) => m['episodeTitle']), [for (var i = 0; i < 20; i++) 'Episode $i']);
    });

    test('next-up episodes without lastViewedAt inside the top 20 survive the cut', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final service = SystemShelfService.forTesting(channel: channel, isSupported: () async => true);
      service.beginProfileSession('owner-a');
      final items = [
        onDeck(0), // next-up: never viewed
        for (var i = 1; i < 30; i++) onDeck(i, lastViewedAt: 1800000000 + i), // newer views, but later in order
      ];
      items.insert(5, onDeck(99));

      await service.syncFromContinueWatching('owner-a', items, (_) => _ShelfClient());

      final ids = sentItems(calls).map((m) => m['episodeTitle']).toList();
      expect(ids, hasLength(20));
      expect(ids.first, 'Episode 0');
      expect(ids[5], 'Episode 99');
    });

    test('two syncs of identical data publish identical lastEngagementTime values', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      var now = DateTime.utc(2026, 11, 5, 19);
      final store = MemoryShelfFirstPublishedStore();
      final service = SystemShelfService.forTesting(
        channel: channel,
        isSupported: () async => true,
        firstPublishedStore: store,
        clock: () => now,
      );
      service.beginProfileSession('owner-a');
      final items = [onDeck(0), onDeck(1, lastViewedAt: 1700000000), onDeck(2)];

      await service.syncFromContinueWatching('owner-a', items, (_) => _ShelfClient());
      final first = sentItems(calls).map((m) => m['lastEngagementTime']).toList();
      now = now.add(const Duration(hours: 2));
      await service.syncFromContinueWatching('owner-a', items, (_) => _ShelfClient());
      final second = sentItems(calls).map((m) => m['lastEngagementTime']).toList();

      expect(second, first);
      expect(first[0], DateTime.utc(2026, 11, 5, 19).millisecondsSinceEpoch);
      expect(first[1], 1700000000 * 1000);

      // A fresh service (app restart) reads the same times back from the store.
      final restarted = SystemShelfService.forTesting(
        channel: channel,
        isSupported: () async => true,
        firstPublishedStore: store,
        clock: () => now.add(const Duration(days: 1)),
      );
      restarted.beginProfileSession('owner-a');
      await restarted.syncFromContinueWatching('owner-a', items, (_) => _ShelfClient());
      expect(sentItems(calls).map((m) => m['lastEngagementTime']).toList(), first);
    });

    test('a newly published next-up episode gets now; the store is pruned to current items', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      var now = DateTime.utc(2026, 11, 5, 19);
      final store = MemoryShelfFirstPublishedStore();
      final service = SystemShelfService.forTesting(
        channel: channel,
        isSupported: () async => true,
        firstPublishedStore: store,
        clock: () => now,
      );
      service.beginProfileSession('owner-a');
      await service.syncFromContinueWatching('owner-a', [onDeck(0), onDeck(1)], (_) => _ShelfClient());
      now = now.add(const Duration(minutes: 50));
      await service.syncFromContinueWatching('owner-a', [onDeck(2), onDeck(1)], (_) => _ShelfClient());

      final sent = sentItems(calls);
      expect(sent[0]['lastEngagementTime'], now.millisecondsSinceEpoch);
      expect(sent[1]['lastEngagementTime'], DateTime.utc(2026, 11, 5, 19).millisecondsSinceEpoch);
      expect(store.value.keys, unorderedEquals([sent[0]['contentId'], sent[1]['contentId']]));
    });

    test('exact duplicate contentIds keep the first occurrence', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final service = SystemShelfService.forTesting(channel: channel, isSupported: () async => true);
      service.beginProfileSession('owner-a');
      await service.syncFromContinueWatching('owner-a', [onDeck(0), onDeck(1), onDeck(0)], (_) => _ShelfClient());
      expect(sentItems(calls).map((m) => m['episodeTitle']), ['Episode 0', 'Episode 1']);
    });
  });

  group('Reel Saves on Play Next (V2-42)', () {
    List<Map> sent(List<MethodCall> calls) =>
        ((calls.lastWhere((c) => c.method == 'sync').arguments as Map)['items'] as List).cast<Map>();

    MediaItem episodeOf(String showId, int i, {required int lastViewedAt}) => testMediaItem(
      id: 'ep-$showId-$i',
      backend: MediaBackend.plex,
      kind: MediaKind.episode,
      title: 'Episode $i',
      grandparentId: showId,
      grandparentTitle: 'Show $showId',
      serverId: 'server-a',
      serverName: 'Server',
      lastViewedAt: lastViewedAt,
    );

    MediaItem title(String id, MediaKind kind, {String serverId = 'server-a'}) => testMediaItem(
      id: id,
      backend: MediaBackend.plex,
      kind: kind,
      title: 'Title $id',
      thumbPath: '/thumb-$id',
      serverId: serverId,
      serverName: 'Server',
    );

    ShelfSave save(MediaItem item, int ms) =>
        ShelfSave(item: item, savedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true));

    SystemShelfService service({required Future<bool> Function() supported, bool tvos = false}) {
      final s = SystemShelfService.forTesting(
        channel: channel,
        isSupported: supported,
        isTvosTarget: () => tvos,
        clock: () => DateTime.fromMillisecondsSinceEpoch(9000000, isUtc: true),
      );
      s.beginProfileSession('owner-a');
      return s;
    }

    test('saves follow Continue Watching as WATCHLIST, below its lowest time, newest first', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final shelf = service(supported: () async => true);
      // Continue Watching: show-a (viewed at 5000 s) and the film film-x.
      final cw = [
        episodeOf('show-a', 1, lastViewedAt: 5000),
        testMediaItem(
          id: 'film-x',
          backend: MediaBackend.plex,
          title: 'Title film-x',
          serverId: 'server-a',
          serverName: 'Server',
          lastViewedAt: 6000,
          viewOffsetMs: 100,
        ),
      ];
      final saves = [
        save(title('show-b', MediaKind.show), 9000000), // newer than every CW item
        save(title('show-a', MediaKind.show), 8000000), // its episode is in CW
        save(title('film-x', MediaKind.movie), 7000000), // already on the row
        save(title('film-y', MediaKind.movie), 9500000), // newest save
        save(title('film-z', MediaKind.movie), 1000000), // older than every CW item
      ];

      expect(
        await shelf.syncFromContinueWatching('owner-a', cw, (_) => _ShelfClient(), saves: () async => saves),
        isTrue,
      );

      final items = sent(calls);
      expect(items.map((m) => m['contentId']), [
        'plezy_server-a_ep-show-a-1',
        'plezy_server-a_film-x',
        'plezy_server-a_film-y',
        'plezy_server-a_show-b',
        'plezy_server-a_film-z',
      ]);
      expect(items.take(2).map((m) => m['watchlist']), [null, null]);
      expect(items.skip(2).map((m) => m['watchlist']), [true, true, true]);
      expect(items.skip(2).map((m) => m['lastPlaybackPosition']), [0, 0, 0]);
      expect(items[3]['type'], 'show');
      // Below the lowest Continue Watching time (5,000,000 ms), strictly
      // decreasing; a save already older keeps its own save time.
      expect(items.skip(2).map((m) => m['lastEngagementTime']), [4999999, 4999998, 1000000]);
    });

    test('with no Continue Watching, each save keeps its save time', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final shelf = service(supported: () async => true);
      await shelf.syncFromContinueWatching(
        'owner-a',
        const [],
        (_) => _ShelfClient(),
        saves: () async => [save(title('film-y', MediaKind.movie), 3000), save(title('show-b', MediaKind.show), 4000)],
      );
      expect(sent(calls).map((m) => (m['contentId'], m['lastEngagementTime'])), [
        ('plezy_server-a_show-b', 4000),
        ('plezy_server-a_film-y', 3000),
      ]);
    });

    test('saves only fill what Continue Watching leaves under the 20 cap', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final shelf = service(supported: () async => true);
      final cw = [for (var i = 0; i < 19; i++) episodeOf('show-$i', 1, lastViewedAt: 5000 - i)];
      await shelf.syncFromContinueWatching(
        'owner-a',
        cw,
        (_) => _ShelfClient(),
        saves: () async => [
          save(title('film-1', MediaKind.movie), 3),
          save(title('film-2', MediaKind.movie), 2),
          save(title('film-3', MediaKind.movie), 1),
        ],
      );
      final items = sent(calls);
      expect(items, hasLength(SystemShelf.maxItems));
      expect(items.last['contentId'], 'plezy_server-a_film-1');
      expect(items.where((m) => m['watchlist'] == true), hasLength(1));
    });

    test('saves are never read where the shelf is unsupported or on tvOS', () async {
      var reads = 0;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      Future<List<ShelfSave>> saves() async {
        reads++;
        return [save(title('film-y', MediaKind.movie), 3000)];
      }

      expect(
        await service(
          supported: () async => false,
        ).syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient(), saves: saves),
        isFalse,
      );
      expect(reads, 0);

      expect(
        await service(
          supported: () async => true,
          tvos: true,
        ).syncFromContinueWatching('owner-a', const [], (_) => _ShelfClient(), saves: saves),
        isTrue,
      );
      expect(reads, 0);
      expect(sent(calls), isEmpty);
    });

    test('a failing saves read still publishes Continue Watching', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final shelf = service(supported: () async => true);
      expect(
        await shelf.syncFromContinueWatching(
          'owner-a',
          [episodeOf('show-a', 1, lastViewedAt: 5000)],
          (_) => _ShelfClient(),
          saves: () async => throw StateError('store unavailable'),
        ),
        isTrue,
      );
      expect(sent(calls).map((m) => m['contentId']), ['plezy_server-a_ep-show-a-1']);
    });

    test('an owner change while saves are read drops the sync', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final shelf = service(supported: () async => true);
      final gate = Completer<List<ShelfSave>>();
      final pending = shelf.syncFromContinueWatching(
        'owner-a',
        const [],
        (_) => _ShelfClient(),
        saves: () => gate.future,
      );
      await Future<void>.delayed(Duration.zero);
      shelf.beginProfileSession('owner-b');
      gate.complete([save(title('film-y', MediaKind.movie), 3000)]);
      expect(await pending, isFalse);
      expect(calls.where((c) => c.method == 'sync'), isEmpty);
    });
  });
}
