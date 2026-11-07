import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';

/// The Reel's extras read: a failed read must throw, so the clip resolver
/// never caches it as "this title has no trailer" (V2-56).
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('extras are read from the title\'s extras', () async {
    final client = testPlexClient(
      handler: (request) async => jsonResponse({
        'MediaContainer': {
          'Metadata': [
            {
              'ratingKey': '78',
              'title': 'Harbor Lights Trailer',
              'subtype': 'trailer',
              'Media': [
                {
                  'Part': [
                    {'key': '/library/parts/78/file.mp4'},
                  ],
                },
              ],
            },
          ],
        },
      }),
    );
    addTearDown(client.close);
    final extras = await client.fetchExtraClips('5');
    expect(extras.map((e) => e.ratingKey), ['78']);
  });

  test('the raw rows keep every Media attribute for the extras-shape probe (V2-20)', () async {
    final client = testPlexClient(
      handler: (request) async {
        expect(request.url.path, '/library/metadata/5/extras');
        return jsonResponse({
          'MediaContainer': {
            'Metadata': [
              {
                'ratingKey': '78',
                'title': 'Harbor Lights Trailer',
                'subtype': 'trailer',
                'Media': [
                  {
                    'videoResolution': '1080',
                    'bitrate': 5000,
                    'audioChannels': 2,
                    'Part': [
                      {'key': '/services/iva/assets/78/video.mp4?bitrate=5000'},
                    ],
                  },
                  {
                    'videoResolution': '720',
                    'bitrate': 2000,
                    'Part': [
                      {'key': '/services/iva/assets/78/video.mp4?bitrate=2000'},
                    ],
                  },
                ],
              },
            ],
          },
        });
      },
    );
    addTearDown(client.close);
    final rows = await client.fetchExtraRows('5');
    expect(rows, hasLength(1));
    final media = (rows.single as Map)['Media'] as List;
    expect(media.map((m) => (m as Map)['videoResolution']), ['1080', '720']);
    expect((media.first as Map)['audioChannels'], 2);
    // The clip ladder still reads its lean row from the same response.
    expect((await client.fetchExtraClips('5')).single.partKey, '/services/iva/assets/78/video.mp4?bitrate=5000');
  });

  for (final status in [401, 503]) {
    test('a $status throws instead of reading as no extras', () async {
      final client = testPlexClient(handler: (request) async => jsonResponse({'error': 'no'}, status: status));
      addTearDown(client.close);
      for (final read in [client.fetchExtraClips, client.fetchExtraRows]) {
        await expectLater(
          read('5'),
          throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', status)),
        );
      }
    });
  }
}
