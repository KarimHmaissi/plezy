import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/reel/reel_tmdb.dart';

/// TMDB's videos endpoints for the trailer rung (V2-63). The keys here are
/// made up and built at run time: a v3 key is 32 hex characters, a Read
/// Access Token a three-part JWT starting `eyJ`.
void main() {
  final apiKey = 'c0ffee' * 5 + 'ab';
  final token = 'eyJ${'a' * 20}.${'b' * 20}.${'c' * 20}';

  group('request', () {
    test('a v3 key rides as api_key on the series or movie videos path, with the language', () {
      final r = TmdbVideosClient.request(id: 4242, show: true, language: 'en', key: apiKey);
      expect(r.method, 'GET');
      expect(r.url.host, 'api.themoviedb.org');
      expect(r.url.path, '/3/tv/4242/videos');
      expect(r.url.queryParameters, {'language': 'en', 'include_video_language': 'en', 'api_key': apiKey});
      expect(r.headers.containsKey('Authorization'), isFalse);
      expect(TmdbVideosClient.request(id: 7, show: false, language: 'en', key: apiKey).url.path, '/3/movie/7/videos');
    });

    test('a Read Access Token rides as a Bearer header, never in the URL', () {
      final r = TmdbVideosClient.request(id: 7, show: false, language: 'en', key: token);
      expect(r.headers['Authorization'], 'Bearer $token');
      expect(r.url.toString(), isNot(contains(token)));
      expect(r.url.queryParameters, {'language': 'en', 'include_video_language': 'en'});
    });

    test('another app language asks for its videos and English ones, so an English-only trailer is still found', () {
      final r = TmdbVideosClient.request(id: 7, show: false, language: 'de', key: apiKey);
      expect(r.url.queryParameters['language'], 'de');
      expect(r.url.queryParameters['include_video_language'], 'de,en');
      expect(TmdbVideosClient.videoLanguages(' EN '), 'en');
      expect(TmdbVideosClient.videoLanguages(''), 'en');
    });
  });

  group('fetch', () {
    TmdbVideosClient client(http.Response Function(http.Request) answer, {String? key}) =>
        TmdbVideosClient(client: MockClient((r) async => answer(r)), key: () async => key ?? apiKey);

    test('a 200 gives the results list', () async {
      final results = await client(
        (_) => http.Response(
          jsonEncode({
            'id': 4242,
            'results': [
              {'key': 'AbCdEfGhIj1', 'site': 'YouTube', 'type': 'Trailer', 'official': true},
            ],
          }),
          200,
        ),
      ).fetch(id: 4242, show: true, language: 'en');
      expect(results, hasLength(1));
    });

    test('a 404 (an id TMDB doesn\'t know) is a sure empty list', () async {
      final results = await client(
        (_) => http.Response('{"status_code":34}', 404),
      ).fetch(id: 1, show: false, language: 'en');
      expect(results, isEmpty);
    });

    for (final code in [401, 429, 500, 503]) {
      test('a $code is unknown, never an empty answer', () async {
        await expectLater(
          client((_) => http.Response('{}', code)).fetch(id: 1, show: false, language: 'en'),
          throwsA(isA<TmdbUnavailable>()),
        );
      });
    }

    test('a reply not shaped as documented is unknown', () async {
      await expectLater(
        client((_) => http.Response('<html>', 200)).fetch(id: 1, show: false, language: 'en'),
        throwsA(isA<TmdbUnavailable>()),
      );
      await expectLater(
        client((_) => http.Response('{"id":1}', 200)).fetch(id: 1, show: false, language: 'en'),
        throwsA(isA<TmdbUnavailable>()),
      );
    });

    test('a network failure is unknown', () async {
      final c = TmdbVideosClient(
        client: MockClient((_) async => throw http.ClientException('down')),
        key: () async => apiKey,
      );
      await expectLater(c.fetch(id: 1, show: false, language: 'en'), throwsA(isA<TmdbUnavailable>()));
    });

    test('no key, or one that is neither credential: null, and no request', () async {
      var requests = 0;
      TmdbVideosClient c(String? key) => TmdbVideosClient(
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
        key: () async => key,
      );
      expect(await c(null).fetch(id: 1, show: false, language: 'en'), isNull);
      expect(await c('not a key').fetch(id: 1, show: false, language: 'en'), isNull);
      expect(requests, 0);
    });
  });

  group('key presence', () {
    test('mayHaveKey is true until a read finds none, then false', () async {
      String? key;
      final c = TmdbVideosClient(client: MockClient((_) async => http.Response('{}', 200)), key: () async => key);
      expect(c.mayHaveKey, isTrue);
      await c.prime();
      expect(c.hasKey, isFalse);
      expect(c.mayHaveKey, isFalse);
      key = apiKey;
      await c.prime();
      expect(c.mayHaveKey, isTrue);
    });
  });
}
