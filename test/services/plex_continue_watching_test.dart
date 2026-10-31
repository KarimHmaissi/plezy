import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/utils/active_client_scope.dart';

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
}
