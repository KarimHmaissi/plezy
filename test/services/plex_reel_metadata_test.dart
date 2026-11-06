import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/utils/active_client_scope.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

/// The Reel card's lean metadata read (plan V2-03): no file checks or stream
/// detail, and never written into the shared `/library/metadata/{id}` row
/// that the file-info and play paths read.
void main() {
  final serverId = ServerId('server-1');
  final scope = buildPlexProfileScopeId(serverId: serverId, profileId: 'profile-a');
  const endpoint = '/library/metadata/5';

  late AppDatabase db;
  late PlexApiCache cache;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    cache = PlexApiCache.instance;
  });

  tearDown(() => db.close());

  const row = {
    'MediaContainer': {
      'librarySectionID': 3,
      'librarySectionTitle': 'Films',
      'Metadata': [
        {'ratingKey': '5', 'type': 'movie', 'title': 'Harbor Lights', 'year': 2019, 'art': '/library/metadata/5/art/1'},
      ],
    },
  };

  test('one lean read, with the library section, and no cache write', () async {
    final requested = <Uri>[];
    final client = testPlexClient(
      serverId: serverId,
      profileScopeId: scope,
      handler: (http.Request request) async {
        requested.add(request.url);
        return jsonResponse(row);
      },
    );
    addTearDown(client.close);

    final json = await client.fetchReelMetadataJson('5');

    expect(requested, hasLength(1));
    expect(requested.single.path, endpoint);
    expect(
      requested.single.queryParameters.keys,
      isNot(anyOf(contains('checkFiles'), contains('includeStreams'), contains('includeChapters'))),
    );
    expect(json?['title'], 'Harbor Lights');
    expect(json?['librarySectionID'], 3);
    expect(json?['librarySectionTitle'], 'Films');
    expect(await cache.get(scope.cacheServerId, endpoint), isNull, reason: 'the shared row stays the app\'s');
  });

  test('a 404 reads as no such item', () async {
    final client = testPlexClient(handler: (_) async => jsonResponse({'error': 'no'}, status: 404));
    addTearDown(client.close);
    expect(await client.fetchReelMetadataJson('5'), isNull);
  });

  test('a 503 throws, so the Reel never takes it as no item', () async {
    final client = testPlexClient(handler: (_) async => jsonResponse({'error': 'no'}, status: 503));
    addTearDown(client.close);
    await expectLater(
      client.fetchReelMetadataJson('5'),
      throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 503)),
    );
  });

  test('the app row is served only while it is fresh', () async {
    await cache.put(scope.cacheServerId, endpoint, row);
    final fresh = await cache.getMetadataIfFresh(scope.cacheServerId, '5', maxAge: const Duration(days: 7));
    expect(fresh?.title, 'Harbor Lights');
    expect(fresh?.serverId, serverId.value);

    await (db.update(
      db.apiCache,
    )).write(ApiCacheCompanion(cachedAt: Value(DateTime.now().subtract(const Duration(days: 8)))));
    expect(await cache.getMetadataIfFresh(scope.cacheServerId, '5', maxAge: const Duration(days: 7)), isNull);
    expect((await cache.getMetadata(scope.cacheServerId, '5'))?.title, 'Harbor Lights');
  });
}
