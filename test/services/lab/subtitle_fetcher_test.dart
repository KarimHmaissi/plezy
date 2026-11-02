import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/lab/subtitle_fetcher.dart';
import 'package:plezy/services/plex_api_cache.dart';

import '../../test_helpers/backend_client_fixtures.dart';

Map<String, dynamic> _stream(
  int id, {
  String lang = 'eng',
  String codec = 'srt',
  bool sidecar = false,
  bool forced = false,
  String? title,
}) => {
  'id': id,
  'index': id,
  'streamType': 3,
  'languageCode': lang,
  'codec': codec,
  'forced': forced,
  'title': ?title,
  if (sidecar) 'key': '/library/streams/$id',
};

void main() {
  final requested = <String>[];

  SubtitleFetcher fetcher() => SubtitleFetcher(
    testPlexClient(
      handler: (request) async {
        final path = request.url.path;
        requested.add(path);
        if (path == '/library/metadata/1') {
          return http.Response(
            jsonEncode({
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
                              _stream(2, forced: true, sidecar: true),
                              _stream(3, codec: 'pgs'),
                              _stream(4, lang: 'fra', sidecar: true),
                              _stream(5),
                              _stream(6, sidecar: true, title: 'English SDH'),
                              _stream(7, sidecar: true),
                            ],
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/library/metadata/10') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {'ratingKey': '10', 'type': 'show'},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/library/metadata/10/allLeaves') {
          return http.Response(
            jsonEncode({
              'MediaContainer': {
                'Metadata': [
                  {'ratingKey': '1', 'type': 'episode'},
                  {'ratingKey': '2', 'type': 'episode'},
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/library/streams/7.srt') return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHello\n', 200);
        return http.Response('', 404);
      },
    ),
  );

  setUp(() {
    requested.clear();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(database);
    addTearDown(database.close);
  });

  test('takes the plain English sidecar over SDH, forced, image and embedded tracks', () async {
    final got = await fetcher().fetch('1');
    expect(got?.source, SubtitleSource.sidecar);
    expect(got?.srt, contains('Hello'));
    expect(requested, contains('/library/streams/7.srt'));
    expect(requested, isNot(contains('/library/streams/2.srt')));
  });

  test('a show expands to its episodes', () async {
    final leaves = await fetcher().leaves('10');
    expect([for (final l in leaves) l['ratingKey']], ['1', '2']);
  });
}
