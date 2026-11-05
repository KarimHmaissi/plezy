import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/utils/active_client_scope.dart';
import 'package:plezy/utils/continue_watching_logo_notifier.dart';
import 'package:plezy/utils/media_server_timeouts.dart';

import '../test_helpers/backend_client_fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });

  tearDown(() => db.close());

  final serverId = ServerId('server-id');
  final profileScopeId = buildPlexProfileScopeId(serverId: serverId, profileId: 'test-profile');

  http.Response json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: const {'content-type': 'application/json'});

  Map<String, dynamic> episode(String key, String show, {int? offset}) => {
    'ratingKey': key,
    'type': 'episode',
    'title': 'Episode $key',
    'grandparentRatingKey': show,
    'grandparentTitle': 'Show $show',
    'viewOffset': ?offset,
  };

  Map<String, dynamic> movie(String key) => {'ratingKey': key, 'type': 'movie', 'title': 'Movie $key', 'viewOffset': 5};

  test('Continue Watching adds older /library/onDeck items the hub left out', () async {
    final requested = <String>[];
    final client = testPlexClient(
      serverId: serverId,
      profileScopeId: profileScopeId,
      handler: (request) async {
        requested.add(request.url.path);
        return switch (request.url.path) {
          '/hubs' => json({
            'MediaContainer': {
              'Hub': [
                {
                  'hubIdentifier': 'home.continue',
                  'Metadata': [episode('e1', 'showA', offset: 1000), movie('m1')],
                },
              ],
            },
          }),
          '/library/onDeck' => json({
            'MediaContainer': {
              'Metadata': [
                movie('m1'), // already in the hub
                episode('e2', 'showA'), // another episode of a show the hub has
                movie('m-old'), // older than the hub's window
                episode('e9', 'showOld'), // a show the hub dropped
              ],
            },
          }),
          _ => json({'MediaContainer': <String, dynamic>{}}),
        };
      },
    );

    final items = await client.fetchContinueWatching(count: 20);

    expect([for (final item in items) item.id], ['e1', 'm1', 'm-old', 'e9']);
    expect(requested, containsAll(['/hubs', '/library/onDeck']));
  });

  test('a failing /library/onDeck keeps the hub items', () async {
    final client = testPlexClient(
      serverId: serverId,
      profileScopeId: profileScopeId,
      handler: (request) async => switch (request.url.path) {
        '/hubs' => json({
          'MediaContainer': {
            'Hub': [
              {
                'hubIdentifier': 'home.continue',
                'Metadata': [movie('m1')],
              },
            ],
          },
        }),
        _ => http.Response('nope', 500),
      },
    );

    final items = await client.fetchContinueWatching(count: 20);

    expect([for (final item in items) item.id], ['m1']);
  });

  Map<String, dynamic> hubOf(List<Map<String, dynamic>> metadata) => {
    'MediaContainer': {
      'Hub': [
        {'hubIdentifier': 'home.continue', 'Metadata': metadata},
      ],
    },
  };

  test('/library/onDeck is requested alongside the hubs call, and still merges by show', () async {
    final hubs = Completer<http.Response>();
    final requested = <String>[];
    final client = testPlexClient(
      serverId: serverId,
      profileScopeId: profileScopeId,
      handler: (request) {
        requested.add(request.url.path);
        return switch (request.url.path) {
          '/hubs' => hubs.future,
          '/library/onDeck' => Future.value(
            json({
              'MediaContainer': {
                'Metadata': [
                  episode('e2', 'showA'), // another episode of a show the hub has
                  movie('m-old'),
                ],
              },
            }),
          ),
          _ => Future.value(json({'MediaContainer': <String, dynamic>{}})),
        };
      },
    );

    final pending = client.fetchContinueWatching(count: 20);
    await pumpEventQueue();
    expect(requested, ['/library/onDeck', '/hubs'], reason: 'the top-up does not wait for the hubs call');

    hubs.complete(json(hubOf([episode('e1', 'showA', offset: 1000)])));
    final items = await pending;

    // The top-up answered first, but the merge still ran against the hub's
    // shows: e2 is skipped because the hub already has showA.
    expect([for (final item in items) item.id], ['e1', 'm-old']);
    expect(requested.where((path) => path == '/library/onDeck'), hasLength(1));
    expect(requested.where((path) => path == '/hubs'), hasLength(1));
  });

  test('a /library/onDeck that never answers costs only the top-up, at its deadline', () {
    fakeAsync((async) {
      final requested = <String>[];
      final client = testPlexClient(
        serverId: serverId,
        profileScopeId: profileScopeId,
        handler: (request) {
          requested.add(request.url.path);
          if (request.url.path == '/library/onDeck') return Completer<http.Response>().future;
          return Future.value(json(hubOf([episode('e1', 'showA', offset: 1000), movie('m1')])));
        },
      );

      List<MediaItem>? items;
      unawaited(client.fetchContinueWatching(count: 20).then((result) => items = result));
      async.elapse(MediaServerTimeouts.continueWatchingExtrasDeadline - const Duration(milliseconds: 100));
      expect(items, isNull, reason: 'a slow top-up is still waited for inside its deadline');

      async.elapse(const Duration(milliseconds: 100));
      expect([for (final item in items!) item.id], ['e1', 'm1']);
      expect(
        requested.where((path) => path == '/library/onDeck'),
        hasLength(1),
        reason: 'a missed top-up is not retried',
      );
    });
  });

  test('show logos are patched in after the rows return, in the same order', () async {
    final logos = Completer<http.Response>();
    final requested = <String>[];
    final client = testPlexClient(
      serverId: serverId,
      profileScopeId: profileScopeId,
      handler: (request) {
        requested.add(request.url.path);
        return switch (request.url.path) {
          '/hubs' => Future.value(
            json(hubOf([episode('e1', 'showA', offset: 1000), movie('m1'), episode('e2', 'showB', offset: 5)])),
          ),
          '/library/metadata/showA,showB' => logos.future,
          _ => Future.value(json({'MediaContainer': <String, dynamic>{}})),
        };
      },
    );
    final patches = <ContinueWatchingLogoPatch>[];
    final subscription = ContinueWatchingLogoNotifier().stream.listen(patches.add);
    addTearDown(subscription.cancel);

    final items = await client.fetchContinueWatching(count: 20);

    // Returned while the logo lookup is still open.
    expect([for (final item in items) item.id], ['e1', 'm1', 'e2']);
    expect(items.map((item) => item.clearLogoPath), everyElement(isNull));
    await pumpEventQueue();
    expect(requested, contains('/library/metadata/showA,showB'));
    expect(patches, isEmpty);

    logos.complete(
      json({
        'MediaContainer': {
          'Metadata': [
            for (final show in ['showB', 'showA'])
              {
                'ratingKey': show,
                'type': 'show',
                'Image': [
                  {'type': 'clearLogo', 'url': '/library/metadata/$show/clearLogo/1'},
                ],
              },
          ],
        },
      }),
    );
    await pumpEventQueue();

    expect(patches.single.logosBySeriesGlobalKey, {
      'server-id:showA': '/library/metadata/showA/clearLogo/1',
      'server-id:showB': '/library/metadata/showB/clearLogo/1',
    });
    expect(items.first.seriesGlobalKey, 'server-id:showA', reason: 'patch keys match the rows');
  });
}
