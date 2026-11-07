import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../tmdb/tmdb_key_store.dart';

/// TMDB couldn't answer for a title: no reply in time, a 401 (the key was
/// revoked), a 429, a 5xx, or a reply not shaped as documented. The
/// resolver counts it as unknown, never a miss (plan V2-56).
class TmdbUnavailable implements Exception {
  const TmdbUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'TmdbUnavailable: $reason';
}

/// A title's TMDB videos (`results`), or null when the rung can't run here
/// (no TMDB key set). Throws [TmdbUnavailable] when TMDB couldn't answer.
typedef TmdbVideosFetch =
    Future<List<dynamic>?> Function({required int id, required bool show, required String language});

/// The TMDB trailer rung (plan V2-63, D16): a YouTube trailer from TMDB's
/// videos list, after the Plex extras, played on the phone through the
/// YouTube IFrame player. Only the phone gets one; the TV has no WebView,
/// so its clip-less titles stay AI cards.
class ReelTmdbRung {
  const ReelTmdbRung({required this.fetch, required this.on, required this.language});

  final TmdbVideosFetch fetch;

  /// Whether the rung may run now: off on mobile data with Data saver or
  /// Stills only (V2-53). A title it can't ask about now keeps its cached
  /// answer from the other rungs and is asked once the rung is back on.
  final bool Function() on;

  /// The app's language as an ISO 639-1 code (`en`): TMDB's `language`
  /// parameter, and the V2-21 rule that prefers a trailer in it.
  final String Function() language;
}

/// TMDB's videos endpoints, with the key from the app's encrypted settings
/// ([TmdbKeyStore]); the key is read per call and never logged, and neither
/// is the request (an API key rides in its query).
///
/// `GET /3/movie/{movie_id}/videos` and `GET /3/tv/{series_id}/videos`, each
/// answering `{id, results: [{iso_639_1, iso_3166_1, name, key, site, size,
/// type, official, published_at, id}]}`
/// (https://developer.themoviedb.org/reference/movie-videos,
/// https://developer.themoviedb.org/reference/tv-series-videos). An id TMDB
/// doesn't know is a 404 with `status_code` 34; a bad key a 401 (7); too many
/// requests a 429 (25) (https://developer.themoviedb.org/docs/errors).
class TmdbVideosClient {
  TmdbVideosClient({http.Client? client, Future<String?> Function()? key})
    : _client = client ?? http.Client(),
      _key = key ?? TmdbKeyStore.read;

  final http.Client _client;
  final Future<String?> Function() _key;

  /// Whether a usable key was set at the last read; null before the first.
  /// The rung counts itself off without one, so a miss TMDB never answered
  /// still reads as a sure miss ([ClipResolver.knownMisses]).
  bool? hasKey;

  DateTime? _readAt;

  /// How long a "no key" answer stands before the key is read again (one
  /// may be pasted in Settings while the Reel is open).
  static const Duration recheck = Duration(minutes: 1);

  /// False only while the last read found no key; an older answer is read
  /// again in the background.
  bool get mayHaveKey {
    final at = _readAt;
    if (hasKey == false && (at == null || DateTime.now().difference(at) > recheck)) unawaited(prime());
    return hasKey != false;
  }

  /// Reads the key once, so [hasKey] is known before the first title.
  Future<void> prime() async {
    _readAt = DateTime.now();
    try {
      final key = await _key();
      hasKey = key != null && TmdbKeyStore.kindOf(key) != null;
    } catch (_) {
      hasKey = null;
    }
  }

  static const Duration timeout = Duration(seconds: 10);

  /// The request for [id]'s videos with [key]: the v3 API key as `api_key`,
  /// or the Read Access Token as a Bearer header ([TmdbKeyStore.kindOf]).
  ///
  /// `language` alone narrows the list to videos in that language (TMDB
  /// applies it to videos as to images), so a title whose only trailer is in
  /// English would read as having none in any other app language.
  /// `include_video_language` ("filter the list results by language,
  /// supports more than one value by using a comma",
  /// https://developer.themoviedb.org/reference/tv-series-videos) asks for
  /// the app's language and English together; the V2-21 rules then put the
  /// app's language first.
  static http.Request request({required int id, required bool show, required String language, required String key}) {
    final k = key.trim();
    final kind = TmdbKeyStore.kindOf(k);
    final query = <String, String>{
      'language': language,
      'include_video_language': videoLanguages(language),
      if (kind == TmdbKeyKind.apiKey) 'api_key': k,
    };
    final uri = Uri.https('api.themoviedb.org', '/3/${show ? 'tv' : 'movie'}/$id/videos', query);
    final r = http.Request('GET', uri);
    r.headers['Accept'] = 'application/json';
    if (kind == TmdbKeyKind.readAccessToken) r.headers['Authorization'] = 'Bearer $k';
    return r;
  }

  /// The languages asked for: [language], then English, once each.
  static String videoLanguages(String language) {
    final lang = language.trim().toLowerCase();
    return lang.isEmpty || lang == 'en' ? 'en' : '$lang,en';
  }

  Future<List<dynamic>?> fetch({required int id, required bool show, required String language}) async {
    final key = await _key();
    hasKey = key != null && TmdbKeyStore.kindOf(key) != null;
    if (key == null || !hasKey!) return null;
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _client.send(request(id: id, show: show, language: language, key: key)).timeout(timeout),
      ).timeout(timeout);
    } catch (e) {
      throw TmdbUnavailable(e.runtimeType.toString());
    }
    // A title TMDB doesn't know: a sure answer, with no video.
    if (res.statusCode == 404) return const [];
    if (res.statusCode != 200) throw TmdbUnavailable('HTTP ${res.statusCode}');
    final Object? body;
    try {
      body = jsonDecode(res.body);
    } on FormatException {
      throw const TmdbUnavailable('not JSON');
    }
    final results = body is Map ? body['results'] : null;
    if (results is! List) throw const TmdbUnavailable('no results list');
    return results;
  }
}
