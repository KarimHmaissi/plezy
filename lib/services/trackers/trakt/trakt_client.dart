import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../models/trakt/trakt_cast_entry.dart';
import '../../../models/trakt/trakt_catalog_entry.dart';
import '../../../models/trakt/trakt_catalog_media.dart';
import '../../../models/trakt/trakt_ids.dart';
import '../../../models/trakt/trakt_scrobble_request.dart';
import '../../../models/trakt/trakt_user.dart';
import '../../../models/trakt/trakt_user_list.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/json_utils.dart';
import '../future_coalescer.dart';
import '../tracker.dart';
import '../tracker_constants.dart';
import '../tracker_exceptions.dart';
import '../tracker_http_client.dart';
import '../tracker_session.dart';
import 'trakt_constants.dart';
import '../tracker_page.dart';

/// HTTP wrapper for the Trakt REST API.
///
/// Holds a [TrackerSession] (refreshed in place on 401). Concurrent 401s are
/// coalesced so we only hit `/oauth/token` once per refresh.
class TraktClient implements DisposableTrackerClient {
  static const Set<int> _scrobbleAllowedStatuses = {200, 201, 409};
  static const Set<int> _permanentRefreshFailureStatuses = {400, 401, 403};
  final _refreshCoalescer = FutureCoalescer<TrackerSession>();

  TrackerSession _session;
  final TrackerHttpClient _http;

  /// Fired when refresh fails permanently (e.g. `invalid_grant`). The provider
  /// uses this to clear the stored session and notify the UI.
  final void Function() onSessionInvalidated;

  /// Fired when refresh succeeds so the provider can persist the rotated access/refresh token pair.
  final void Function(TrackerSession session)? onSessionUpdated;

  TraktClient(
    TrackerSession session, {
    required this.onSessionInvalidated,
    this.onSessionUpdated,
    http.Client? httpClient,
  }) : _session = session,
       _http = TrackerHttpClient(logLabel: 'Trakt', httpClient: httpClient);

  TrackerSession get session => _session;

  @override
  void dispose() => _http.dispose();

  Future<TraktUser> getUserSettings() async {
    final res = await _request('GET', '/users/settings');
    return TraktUser.fromJson(res as Map<String, dynamic>);
  }

  Future<void> scrobbleStart(TraktScrobbleRequest body) =>
      _request('POST', '/scrobble/start', body: body.toJson(), allowStatuses: _scrobbleAllowedStatuses);

  Future<void> scrobblePause(TraktScrobbleRequest body) =>
      _request('POST', '/scrobble/pause', body: body.toJson(), allowStatuses: _scrobbleAllowedStatuses);

  Future<void> scrobbleStop(TraktScrobbleRequest body) =>
      _request('POST', '/scrobble/stop', body: body.toJson(), allowStatuses: _scrobbleAllowedStatuses);

  /// Body shape: see `trackerHistoryBody`.
  Future<void> addToHistory(Map<String, dynamic> body) => _request('POST', '/sync/history', body: body);

  /// Fork: one page of the user's watch history (`movies` or `episodes`),
  /// raw, newest first; [startAt] limits it to watches since then.
  Future<TrackerPage<Map<String, dynamic>>> getHistory(
    String type, {
    int page = 1,
    int limit = 1000,
    DateTime? startAt,
    String extended = 'full',
  }) async {
    final since = startAt == null ? '' : '&start_at=${Uri.encodeQueryComponent(startAt.toUtc().toIso8601String())}';
    final res = await _requestResponse('GET', '/sync/history/$type?extended=$extended&page=$page&limit=$limit$since');
    final body = json.decode(res.body);
    return TrackerPage.fromResponse(res, [if (body is List) ...body.whereType<Map<String, dynamic>>()]);
  }

  /// Fork: add watches to history and return Trakt's counts
  /// (`added`/`not_found`). Same item + `watched_at` is deduplicated by Trakt.
  Future<Map<String, dynamic>> addToHistoryCounted(Map<String, dynamic> body) async {
    final res = await _request('POST', '/sync/history', body: body);
    return res is Map<String, dynamic> ? res : const {};
  }

  /// Fork: remove specific watches by their history ids (not every play of
  /// an item).
  Future<Map<String, dynamic>> removeHistoryIds(List<int> ids) async {
    final res = await _request('POST', '/sync/history/remove', body: {'ids': ids});
    return res is Map<String, dynamic> ? res : const {};
  }

  /// Fork: every show the user has watched, with images (no seasons).
  Future<List<Map<String, dynamic>>> getWatchedShows() async {
    final res = await _request('GET', '/sync/watched/shows?extended=noseasons,images');
    return [if (res is List) ...res.whereType<Map<String, dynamic>>()];
  }

  Future<void> removeFromHistory(Map<String, dynamic> body) => _request('POST', '/sync/history/remove', body: body);

  Future<void> addRatings(Map<String, dynamic> body) =>
      _request('POST', '/sync/ratings', body: body, allowStatuses: const {200, 201});

  Future<void> removeRatings(Map<String, dynamic> body) => _request('POST', '/sync/ratings/remove', body: body);

  Future<List<dynamic>> getRatings(String type) async {
    final res = await _request('GET', '/sync/ratings/$type');
    return res is List ? res : const [];
  }

  // --- Catalog endpoints (Explore tab) ---

  static const String _catalogExtended = 'extended=full,images';

  /// `GET /sync/watchlist[/{type}/{sort}]`. A null [type] returns all entry
  /// types mixed, in the user's rank order. Pagination is currently optional
  /// on this endpoint; sending page/limit makes Trakt echo X-Pagination
  /// headers.
  Future<TrackerPage<TraktCatalogEntry>> getWatchlist({
    TraktCatalogType? type,
    String sort = 'added',
    int page = 1,
    int limit = 100,
  }) async {
    final path = type == null ? '/sync/watchlist' : '/sync/watchlist/${type.name}/$sort';
    final res = await _requestResponse('GET', '$path?$_catalogExtended&page=$page&limit=$limit');
    return TrackerPage.fromResponse(res, _decodeEntries(res.body));
  }

  /// Items are wrapped as `{watchers, movie|show}`. Public endpoint, but sent
  /// authenticated: the tab only exists with a session and per-user rate
  /// limiting is cleaner than app-level.
  Future<TrackerPage<TraktCatalogEntry>> getTrending(TraktCatalogType type, {int page = 1, int limit = 25}) async {
    final res = await _requestResponse('GET', '/${type.name}/trending?$_catalogExtended&page=$page&limit=$limit');
    return TrackerPage.fromResponse(res, _decodeEntries(res.body));
  }

  /// Returns bare movie/show objects (not wrapped like trending).
  Future<TrackerPage<TraktCatalogMedia>> getPopular(TraktCatalogType type, {int page = 1, int limit = 25}) async {
    final res = await _requestResponse('GET', '/${type.name}/popular?$_catalogExtended&page=$page&limit=$limit');
    return TrackerPage.fromResponse(res, _decodeMedia(res.body));
  }

  /// Personalized recommendations. OAuth-required, limit-only (no pagination).
  Future<List<TraktCatalogMedia>> getRecommended(
    TraktCatalogType type, {
    int limit = 25,
    bool ignoreCollected = false,
    bool ignoreWatchlisted = true,
  }) async {
    final res = await _requestResponse(
      'GET',
      '/recommendations/${type.name}'
          '?$_catalogExtended&limit=$limit&ignore_collected=$ignoreCollected&ignore_watchlisted=$ignoreWatchlisted',
    );
    return _decodeMedia(res.body);
  }

  /// Title search across movies and shows (`GET /search/movie,show`).
  /// Results are wrapped `{type, score, movie|show}` like watchlist entries.
  Future<TrackerPage<TraktCatalogEntry>> searchCatalog(String query, {int page = 1, int limit = 25}) async {
    final res = await _requestResponse(
      'GET',
      '/search/movie,show?query=${Uri.encodeQueryComponent(query)}&$_catalogExtended&page=$page&limit=$limit',
    );
    return TrackerPage.fromResponse(res, _decodeEntries(res.body));
  }

  /// Similar titles (`GET /{movies|shows}/{id}/related`) — bare media
  /// objects of the same type. [id] is a Trakt numeric id or slug.
  Future<List<TraktCatalogMedia>> getRelated(TraktCatalogType type, String id, {int limit = 20}) async {
    final res = await _requestResponse('GET', '/${type.name}/$id/related?$_catalogExtended&limit=$limit');
    return _decodeMedia(res.body);
  }

  /// People for a title (`GET /{movies|shows}/{id}/people`). Show requests
  /// include `guest_stars`; Trakt documents that this returns every guest star
  /// with at least one episode and can be a lot of data, so callers must bound
  /// the cast they retain.
  Future<TraktPeople> getPeople(TraktCatalogType type, String id) async {
    final extended = type == TraktCatalogType.shows ? '$_catalogExtended,guest_stars' : _catalogExtended;
    final res = await _requestResponse('GET', '/${type.name}/$id/people?$extended');
    final decoded = TrackerHttpClient.decodeJson(res.body);
    if (decoded is! Map) return const TraktPeople();
    return TraktPeople(
      cast: _decodePeopleEntries(decoded['cast']),
      guestStars: _decodePeopleEntries(decoded['guest_stars']),
      crew: _decodeCrewEntries(decoded['crew']),
    );
  }

  /// Fork: a title's full details (`GET /{movies|shows}/{id}?extended=full`): overview, genres, runtime,
  /// rating, and for shows `aired_episodes`. Null when Trakt does not know the title. [id] is a Trakt id, slug or
  /// IMDb id.
  Future<Map<String, dynamic>?> getSummary(TraktCatalogType type, String id) async {
    final res = await _getOrNull('/${type.name}/$id?extended=full');
    final decoded = res == null ? null : TrackerHttpClient.decodeJson(res.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// The Trakt id a TMDB or TVDB id ([idType]) names (`GET /search/{tmdb|tvdb}/{id}?type=movie|show`,
  /// "ID Lookup"), from the first result of [type]'s kind; null when Trakt does not know the title.
  Future<int?> lookupTraktId(String idType, int id, TraktCatalogType type) async {
    final kind = type == TraktCatalogType.movies ? 'movie' : 'show';
    final res = await _getOrNull('/search/$idType/$id?type=$kind');
    if (res == null) return null;
    for (final entry in _decodeEntries(res.body)) {
      if (entry.type == kind) return (type == TraktCatalogType.movies ? entry.movie : entry.show)?.ids.trakt;
    }
    return null;
  }

  /// A title's community rating (`GET /{movies|shows}/{id}/ratings`): the 0-10 average and its votes; null
  /// when Trakt does not know the title. [id] is a Trakt id, slug or IMDb id.
  Future<({double? rating, int? votes})?> getCommunityRating(TraktCatalogType type, String id) async {
    final res = await _getOrNull('/${type.name}/$id/ratings');
    final decoded = res == null ? null : TrackerHttpClient.decodeJson(res.body);
    if (decoded is! Map) return null;
    return (rating: flexibleDouble(decoded['rating']), votes: flexibleInt(decoded['votes']));
  }

  /// Body shape: `{"movies":[{"ids":{...}}],"shows":[{"ids":{...}}]}`.
  Future<void> addToWatchlist(Map<String, dynamic> body) =>
      _request('POST', '/sync/watchlist', body: body, allowStatuses: const {200, 201});

  Future<void> removeFromWatchlist(Map<String, dynamic> body) => _request('POST', '/sync/watchlist/remove', body: body);

  /// `GET /movies/boxoffice`: this weekend's top 10, as `{revenue, movie}`.
  Future<List<TraktCatalogEntry>> getBoxOffice() async {
    final res = await _requestResponse('GET', '/movies/boxoffice?$_catalogExtended');
    return _decodeEntries(res.body);
  }

  /// `GET /{type}/watched/{period}`: most watched (unique viewers), as
  /// `{watcher_count, ..., movie|show}`.
  Future<TrackerPage<TraktCatalogEntry>> getMostWatched(
    TraktCatalogType type, {
    String period = 'weekly',
    int page = 1,
    int limit = 25,
  }) async {
    final res = await _requestResponse(
      'GET',
      '/${type.name}/watched/$period?$_catalogExtended&page=$page&limit=$limit',
    );
    return TrackerPage.fromResponse(res, _decodeEntries(res.body));
  }

  /// `GET /{type}/anticipated`: most-listed upcoming titles, as
  /// `{list_count, movie|show}`.
  Future<TrackerPage<TraktCatalogEntry>> getAnticipated(TraktCatalogType type, {int page = 1, int limit = 25}) async {
    final res = await _requestResponse('GET', '/${type.name}/anticipated?$_catalogExtended&page=$page&limit=$limit');
    return TrackerPage.fromResponse(res, _decodeEntries(res.body));
  }

  /// The account's personal-list allowance from `/users/settings` (`limits.list.count`),
  /// or null when Trakt doesn't report one.
  Future<int?> getPersonalListLimit() async {
    final res = await _request('GET', '/users/settings');
    if (res is! Map) return null;
    final limits = res['limits'];
    final list = limits is Map ? limits['list'] : null;
    final count = list is Map ? list['count'] : null;
    return count is int ? count : null;
  }

  /// Lists the user has liked, most recently liked first.
  Future<List<TraktUserList>> getLikedLists({int limit = 100}) async {
    final res = await _request('GET', '/users/likes/lists?limit=$limit');
    return _decodeListWrappers(res);
  }

  /// Public lists by recent likes (`trending`) or all-time likes (`popular`).
  Future<List<TraktUserList>> getPublicLists({required bool trending, int limit = 25}) async {
    final res = await _request('GET', '/lists/${trending ? 'trending' : 'popular'}?limit=$limit');
    return _decodeListWrappers(res);
  }

  /// Items on any list the user can see (their own, or anyone's public list),
  /// in list order. [user] is the owner's slug (`me` for the signed-in user,
  /// `*` to address the list by its id alone).
  Future<TrackerPage<TraktCatalogEntry>> getListItems(String user, int listId, {int page = 1, int limit = 50}) async {
    final path = user == '*' ? '/lists/$listId' : '/users/${Uri.encodeComponent(user)}/lists/$listId';
    final res = await _requestResponse('GET', '$path/items?$_catalogExtended&page=$page&limit=$limit');
    return TrackerPage.fromResponse(res, _decodeEntries(res.body));
  }

  /// One list by its Trakt id, or null if it can't be read.
  Future<TraktUserList?> getList(int listId) async {
    final res = await _request('GET', '/lists/$listId');
    return res is Map<String, dynamic> ? TraktUserList.fromJson(res) : null;
  }

  Future<void> likeList(String user, int listId) =>
      _request('POST', '/users/${Uri.encodeComponent(user)}/lists/$listId/like', allowStatuses: const {200, 201, 204});

  Future<void> unlikeList(String user, int listId) =>
      _request('DELETE', '/users/${Uri.encodeComponent(user)}/lists/$listId/like', allowStatuses: const {200, 204});

  /// `{..., list: {...}}` wrappers (likes, trending, popular) to lists.
  static List<TraktUserList> _decodeListWrappers(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw.whereType<Map<String, dynamic>>())
        if (entry['list'] case final Map<String, dynamic> list) ?TraktUserList.fromJson(list),
    ];
  }

  /// The signed-in user's personal lists.
  Future<List<TraktUserList>> getMyLists() async {
    final res = await _request('GET', '/users/me/lists');
    if (res is! List) return const [];
    return [for (final raw in res.whereType<Map<String, dynamic>>()) ?TraktUserList.fromJson(raw)];
  }

  /// Create a private personal list.
  Future<TraktUserList?> createMyList(String name, {String? description}) async {
    final res = await _request(
      'POST',
      '/users/me/lists',
      body: {'name': name, 'description': ?description, 'privacy': 'private'},
      allowStatuses: const {200, 201},
    );
    return res is Map<String, dynamic> ? TraktUserList.fromJson(res) : null;
  }

  /// Replace a personal list's description.
  Future<void> updateMyListDescription(int listId, String description) =>
      _request('PUT', '/users/me/lists/$listId', body: {'description': description});

  /// The shows on a personal list, in list order.
  Future<List<TraktCatalogEntry>> getMyListShows(int listId) async {
    final res = await _requestResponse('GET', '/users/me/lists/$listId/items/shows?$_catalogExtended');
    return _decodeEntries(res.body);
  }

  Future<void> addShowsToMyList(int listId, List<TraktIds> shows) => _request(
    'POST',
    '/users/me/lists/$listId/items',
    body: {
      'shows': [
        for (final ids in shows) {'ids': ids.toJson()},
      ],
    },
    allowStatuses: const {200, 201},
  );

  Future<void> removeShowsFromMyList(int listId, List<TraktIds> shows) => _request(
    'POST',
    '/users/me/lists/$listId/items/remove',
    body: {
      'shows': [
        for (final ids in shows) {'ids': ids.toJson()},
      ],
    },
  );

  static List<TraktCastEntry> _decodePeopleEntries(Object? raw) {
    if (raw is! List) return const [];
    return [for (final entry in raw.whereType<Map<String, dynamic>>()) TraktCastEntry.fromJson(entry)];
  }

  static List<TraktCastEntry> _decodeCrewEntries(Object? raw) {
    if (raw is! Map) return const [];
    return [
      for (final department in raw.values.whereType<List>())
        for (final entry in department.whereType<Map<String, dynamic>>()) TraktCastEntry.fromJson(entry),
    ];
  }

  static List<TraktCatalogEntry> _decodeEntries(String body) {
    final decoded = TrackerHttpClient.decodeJson(body);
    if (decoded is! List) return const [];
    return [for (final e in decoded.whereType<Map<String, dynamic>>()) TraktCatalogEntry.fromJson(e)];
  }

  static List<TraktCatalogMedia> _decodeMedia(String body) {
    final decoded = TrackerHttpClient.decodeJson(body);
    if (decoded is! List) return const [];
    return [for (final e in decoded.whereType<Map<String, dynamic>>()) TraktCatalogMedia.fromJson(e)];
  }

  /// Refresh the access token. Coalesces concurrent calls so
  /// duplicate POSTs don't race when multiple in-flight requests hit 401.
  Future<TrackerSession> refresh() => _refreshCoalescer.run(_doRefresh);

  Future<TrackerSession> _doRefresh() async {
    final String refreshToken;
    try {
      refreshToken = _session.requireRefreshToken(TrackerService.trakt);
    } on TrackerAuthException catch (e) {
      if (e.isPermanent) onSessionInvalidated();
      rethrow;
    }
    appLogger.d('Trakt: refreshing access token');
    final tokenUri = Uri.parse(TraktConstants.tokenUrl);
    final res = await _http.sendJson(
      'POST',
      tokenUri,
      headers: TraktConstants.headers(),
      body: {
        'refresh_token': refreshToken,
        'client_id': TraktConstants.clientId,
        'client_secret': TraktConstants.clientSecret,
        'grant_type': 'refresh_token',
      },
      timeout: TrackerConstants.refreshTimeout,
      operation: 'Trakt token refresh',
      allowedMethods: const {'POST'},
    );

    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      _session = TrackerSession.fromTokenResponse(TrackerService.trakt, body).copyWith(username: _session.username);
      onSessionUpdated?.call(_session);
      return _session;
    }

    final isPermanent = _permanentRefreshFailureStatuses.contains(res.statusCode);
    if (isPermanent) {
      appLogger.w('Trakt: refresh failed permanently (${res.statusCode}), session invalidated');
      onSessionInvalidated();
    } else {
      appLogger.w('Trakt: refresh failed (${res.statusCode}), will retry later');
    }
    throw TrackerAuthException(
      service: TrackerService.trakt,
      message: 'Refresh failed: HTTP ${res.statusCode}',
      statusCode: res.statusCode,
      isPermanent: isPermanent,
    );
  }

  /// Revoke the access token at Trakt. Best-effort; swallows network errors.
  Future<void> revoke() async {
    try {
      await _http.sendJson(
        'POST',
        Uri.parse(TraktConstants.revokeUrl),
        headers: TraktConstants.headers(),
        body: {
          'token': _session.accessToken,
          'client_id': TraktConstants.clientId,
          'client_secret': TraktConstants.clientSecret,
        },
        timeout: TrackerConstants.revokeTimeout,
        operation: 'Trakt token revoke',
        allowedMethods: const {'POST'},
      );
    } catch (e) {
      appLogger.d('Trakt: revoke failed (non-fatal)', error: e);
    }
  }

  /// Send an authenticated request, refreshing on 401 and retrying once.
  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Set<int> allowStatuses = const {200, 201, 204},
  }) async {
    final res = await _requestResponse(method, path, body: body, allowStatuses: allowStatuses);
    return TrackerHttpClient.decodeJson(res.body);
  }

  /// [_request] variant exposing the raw response for callers that need
  /// headers (pagination).
  Future<http.Response> _requestResponse(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Set<int> allowStatuses = const {200, 201, 204},
  }) async {
    if (_session.needsRefresh) {
      try {
        await refresh();
      } catch (_) {
        // Fall through; the request will hit 401 naturally and retry.
      }
    }

    var res = await _send(method, path, body: body);

    if (res.statusCode == 401) {
      // A failed refresh propagates its TrackerAuthException.
      await refresh();
      res = await _send(method, path, body: body);
    }

    if (allowStatuses.contains(res.statusCode)) return res;

    if (res.statusCode == 429) {
      throw TrackerRateLimitException(
        service: TrackerService.trakt,
        retryAfterSeconds: int.tryParse(res.headers['retry-after'] ?? ''),
      );
    }

    throw TrackerApiException(service: TrackerService.trakt, statusCode: res.statusCode);
  }

  /// [_requestResponse] for a read whose 404 means Trakt does not know the title.
  Future<http.Response?> _getOrNull(String path) async {
    try {
      return await _requestResponse('GET', path);
    } on TrackerApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<http.Response> _send(String method, String path, {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('${TraktConstants.apiBase}$path');
    final headers = TraktConstants.headers(accessToken: _session.accessToken);
    return _http.sendJson(
      method,
      uri,
      headers: headers,
      body: body,
      allowedMethods: const {'GET', 'POST', 'PUT', 'DELETE'},
    );
  }
}
