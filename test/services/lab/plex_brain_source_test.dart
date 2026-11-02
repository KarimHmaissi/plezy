import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/lab/plex_brain_source.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../../test_helpers/backend_client_fixtures.dart';

http.Response _json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

void main() {
  setUp(() {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    addTearDown(database.close);
  });

  test('maps Plex metadata to leaves and subtitle streams, and fetches sidecars with the app token', () async {
    final seen = <http.Request>[];
    final source = PlexBrainSource(
      testPlexClient(baseUrl: 'https://plex.example.com', token: 'tok'),
      httpClient: MockClient((request) async {
        seen.add(request);
        return switch (request.url.path) {
          '/library/metadata/10' => _json({
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': '10', 'type': 'show'},
              ],
            },
          }),
          '/library/metadata/10/allLeaves' => _json({
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': '1', 'type': 'episode', 'grandparentTitle': 'Show A', 'parentIndex': 1, 'index': 2},
              ],
            },
          }),
          '/library/metadata/1' => _json({
            'MediaContainer': {
              'Metadata': [
                {
                  'ratingKey': '1',
                  'type': 'episode',
                  'Media': [
                    {
                      'Part': [
                        {
                          'key': '/library/parts/9/file.mkv',
                          'Stream': [
                            {'streamType': 2, 'index': 1},
                            {
                              'streamType': 3,
                              'index': 3,
                              'languageCode': 'eng',
                              'codec': 'srt',
                              'title': 'English SDH',
                            },
                            {'streamType': 3, 'languageCode': 'eng', 'codec': 'srt', 'key': '/library/streams/7'},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
          '/library/streams/7.srt' => http.Response('1\n00:00:01,000 --> 00:00:02,000\nHi\n', 200),
          _ => http.Response('', 404),
        };
      }),
    );

    final leaves = await source.leaves('10');
    expect(leaves.single.episode, 2);
    final streams = await source.subtitleStreams('1');
    expect(streams, hasLength(2));
    expect(streams.first.hearingImpaired, isTrue);
    expect(streams.first.partKey, '/library/parts/9/file.mkv');
    expect(await source.fetchSidecar(streams.last), contains('Hi'));
    expect(seen.every((r) => r.headers['X-Plex-Token'] == 'tok'), isTrue);
    expect(source.partUrl('/library/parts/9/file.mkv'), contains('X-Plex-Token=tok'));
  });
}
