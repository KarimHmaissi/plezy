import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import 'clip_filter.dart';
import 'clip_player.dart';
import 'reel_store.dart';

/// The only server calls the Reel may make: per-title extras and a clip URL.
/// Implemented outside the Reel (`reel_servers_plex.dart`) so no Reel file
/// imports the Plex client, whose other calls report watch state.
abstract interface class ReelServers {
  /// The extras of [ratingKey] on [serverId]. Throws [ReelServerUnavailable]
  /// when that server isn't connected, and any other error when the read
  /// failed (a timeout, a 401, a 5xx): neither says the title has no clip.
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout});

  /// The direct-play URL for a clip part on [serverId], or null when that
  /// server isn't connected.
  String? clipUrl(String serverId, String partKey);
}

/// [serverId] isn't connected right now (asleep, waking, or signed out), so
/// whether it holds a clip is unknown, never a miss.
class ReelServerUnavailable implements Exception {
  const ReelServerUnavailable(this.serverId);

  final String serverId;

  @override
  String toString() => 'ReelServerUnavailable';
}

/// Waits (bounded) for [serverId] to connect; true once it has.
typedef ReelServerWait = Future<bool> Function(String serverId);

/// A copy of a title on one server, as the index lists it.
class ReelCopy {
  const ReelCopy({required this.serverId, required this.ratingKey, this.is4k = false});

  final String serverId;
  final String ratingKey;
  final bool is4k;
}

/// What a card needs to find its clip.
class ReelTitle {
  const ReelTitle({
    required this.titleId,
    required this.groupKey,
    required this.title,
    required this.isShow,
    required this.copies,
    this.anime = false,
    this.tvdbId,
    this.tmdbId,
  });

  final String titleId;
  final String groupKey;
  final String title;
  final bool isShow;
  final List<ReelCopy> copies;
  final bool anime;
  final int? tvdbId;
  final int? tmdbId;
}

/// A resolved rung: where the clip is and what it is.
class ResolvedClip {
  const ResolvedClip({required this.source, required this.assetId, required this.label, this.serverId});

  final ClipSource source;

  /// `plex:<extra ratingKey>` or `at:<video id>`, for Spoiled me.
  final String assetId;

  /// "Trailer", "Teaser", "Opening 1".
  final String label;

  /// Plex rungs: the server the clip streams from (never preloaded off a
  /// server marked slow).
  final String? serverId;
}

/// How sure the ladder is about a title.
enum ClipAnswer {
  /// A clip to play.
  found,

  /// Every rung answered and none has a clip: an AI card, cached 30 days.
  none,

  /// A rung couldn't answer (a server offline, a timeout, a 401, an
  /// AnimeThemes 429 or 5xx): an AI card for this session only.
  unknown,
}

/// One answer from [ClipResolver.lookup].
class ClipLookup {
  const ClipLookup.found(ResolvedClip this.clip) : answer = ClipAnswer.found;
  const ClipLookup.none() : clip = null, answer = ClipAnswer.none;
  const ClipLookup.unknown() : clip = null, answer = ClipAnswer.unknown;

  final ClipAnswer answer;
  final ResolvedClip? clip;
}

/// Maps an anime title to its season-1 AniList id (Fribb). Null means the
/// mapping has no id for it; a throw means the mapping couldn't be read.
typedef AniListLookup = Future<int?> Function(ReelTitle title);

/// Fetches AnimeThemes `anime` records for AniList ids, keyed by AniList id.
/// An id missing from the map has no record; a throw means no answer.
typedef AnimeThemesFetch = Future<Map<int, Map<String, dynamic>>> Function(List<int> anilistIds);

/// One ladder run: the hit, whether every rung answered for sure, and the
/// servers that weren't connected.
class _Run {
  _Run(this.hit, {required this.sure, required this.offline});

  final (ResolvedClip, Map<String, Object?>)? hit;
  final bool sure;
  final Set<String> offline;

  ClipAnswer get answer => hit != null
      ? ClipAnswer.found
      : sure
      ? ClipAnswer.none
      : ClipAnswer.unknown;
}

/// The clip ladder (spec §5), cheapest for the guest servers first:
/// anime → AnimeThemes OP1, else a Plex extra (Teaser / plain trailer), else
/// an AI card. Caches the asset identity per title for 30 days
/// (`src:<groupKey>`), never a resolved CDN URL. A miss is cached only when
/// every rung answered for sure; a rung that couldn't answer leaves the
/// title unknown, which lasts for the session only. One request at a time,
/// per title, on demand: never a batch or crawl of a server.
class ClipResolver {
  ClipResolver({
    required this.servers,
    required this.store,
    required this.aniList,
    AnimeThemesFetch? animeThemes,
    this.waitForServer,
    this.firstTry = const Duration(seconds: 5),
  }) : _animeThemes = animeThemes ?? AnimeThemesClient().fetch;

  final ReelServers servers;
  final ReelStore store;
  final AniListLookup aniList;
  final AnimeThemesFetch _animeThemes;

  /// Waits for a server that isn't connected yet (after a wake, the Reel
  /// opens before the servers reconnect). Each server is waited for once
  /// per start or resume ([resumed]); null never waits.
  final ReelServerWait? waitForServer;

  /// A server gets one try this long; a timeout marks it slow for the
  /// session (its titles stay unknown, never a cached miss).
  final Duration firstTry;
  final Set<String> _slowServers = {};
  final Map<String, Future<bool>> _waits = {};
  Future<void> _queue = Future.value();

  /// Servers whose extras call timed out this session.
  Set<String> get slowServers => Set.unmodifiable(_slowServers);

  /// The Reel came back (a resume or tab show): a server that wasn't
  /// connected gets waited for again.
  void resumed() => _waits.clear();

  /// The clip for [t], or null for an AI card.
  Future<ResolvedClip?> resolve(ReelTitle t) async => (await lookup(t)).clip;

  /// Drops [t]'s cached answer (its clip failed to play).
  Future<void> forget(ReelTitle t) => store.cache('src:${t.groupKey}', '');

  /// Resolves [t], skipping the assets in [exclude] for this call only (a
  /// clip that just failed to play). A miss found with assets excluded is
  /// not cached: the excluded asset may only have failed for a moment.
  Future<ClipLookup> lookup(ReelTitle t, {Set<String> exclude = const {}}) async {
    final banned = {...await store.spoiledAssets(t.titleId), ...exclude};
    final key = 'src:${t.groupKey}';
    final cached = await store.cached(key, ttl: ReelStore.sourceTtl);
    var keep = false;
    if (cached != null) {
      final entry = _entry(cached);
      if (entry != null && entry['miss'] == true) return const ClipLookup.none();
      final asset = entry?['a'];
      if (entry != null && asset is String && !banned.contains(asset)) {
        var hit = _fromCache(entry, asset);
        if (hit == null && entry['k'] == 'plex' && entry['sv'] is String) {
          // A good identity whose server is offline is kept, never
          // overwritten by a miss.
          keep = true;
          final sv = entry['sv'] as String;
          if (await _awaitServer(sv)) hit = _fromCache(entry, asset);
        }
        if (hit != null) return ClipLookup.found(hit);
      }
    }
    var run = await _serial(() => _ladder(t, banned));
    if (run.answer == ClipAnswer.unknown && run.offline.isNotEmpty) {
      final back = await Future.wait([for (final s in run.offline) _awaitServer(s)]);
      if (back.contains(true)) run = await _serial(() => _ladder(t, banned));
    }
    final hit = run.hit;
    if (hit != null) {
      if (!keep) await store.cache(key, jsonEncode(hit.$2));
      return ClipLookup.found(hit.$1);
    }
    if (run.sure && !keep) {
      if (exclude.isEmpty) await store.cache(key, _miss);
      return const ClipLookup.none();
    }
    appLogger.d('Reel: clip answer unknown for now; not cached');
    return const ClipLookup.unknown();
  }

  static const String _miss = '{"miss":true}';

  Map<String, dynamic>? _entry(String raw) {
    try {
      final j = jsonDecode(raw);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  ResolvedClip? _fromCache(Map<String, dynamic> j, String asset) {
    try {
      return switch (j['k']) {
        'at' => ResolvedClip(
          source: ClipSource(uri: j['u'] as String, origin: ClipOrigin.animeTheme),
          assetId: asset,
          label: j['l'] as String? ?? 'Opening',
        ),
        'plex' => _plex(j['sv'] as String, j['pk'] as String, asset, j['l'] as String? ?? 'Trailer'),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  ResolvedClip? _plex(String serverId, String partKey, String asset, String label) {
    final url = servers.clipUrl(serverId, partKey);
    if (url == null) return null;
    return ResolvedClip(
      source: ClipSource(uri: url, origin: ClipOrigin.plexExtra),
      assetId: asset,
      label: label,
      serverId: serverId,
    );
  }

  /// Waits for [serverId] once per start or resume; later callers share the
  /// answer.
  Future<bool> _awaitServer(String serverId) {
    final wait = waitForServer;
    if (wait == null) return Future.value(false);
    return _waits[serverId] ??= wait(serverId).catchError((Object _) => false);
  }

  Future<T> _serial<T>(Future<T> Function() run) {
    final next = _queue.then((_) => run());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<_Run> _ladder(ReelTitle t, Set<String> banned) async {
    var sure = true;
    final offline = <String>{};
    if (t.anime && t.isShow) {
      final (op, opSure) = await _opening(t);
      sure &= opSure;
      if (op != null && !banned.contains('at:${op.videoId}')) {
        final clip = ResolvedClip(
          source: ClipSource(uri: op.url, origin: ClipOrigin.animeTheme),
          assetId: 'at:${op.videoId}',
          label: 'Opening 1',
        );
        return _Run((clip, {'k': 'at', 'u': op.url, 'a': clip.assetId, 'l': clip.label}), sure: sure, offline: offline);
      }
    }
    // Plex extras: HD copies first, then 4K, skipping servers already slow.
    final copies = [...t.copies]..sort((a, b) => (a.is4k ? 1 : 0).compareTo(b.is4k ? 1 : 0));
    final triedServers = <String>{};
    for (final c in copies) {
      if (!triedServers.add(c.serverId)) continue;
      if (_slowServers.contains(c.serverId)) {
        sure = false;
        continue;
      }
      List<PlexExtraClip> extras;
      try {
        extras = await servers.extras(c.serverId, c.ratingKey, timeout: firstTry);
      } on ReelServerUnavailable {
        sure = false;
        offline.add(c.serverId);
        continue;
      } on TimeoutException {
        sure = false;
        _slowServers.add(c.serverId);
        appLogger.d('Reel: extras timed out on one server; skipping it this session');
        continue;
      } catch (e) {
        sure = false;
        appLogger.d('Reel: extras read failed', error: e);
        continue;
      }
      final usable = [
        for (final e in extras)
          if (!banned.contains('plex:${e.ratingKey}')) e,
      ];
      final pick = t.isShow ? ClipFilter.showTrailer(usable, showTitle: t.title) : ClipFilter.filmTrailer(usable);
      if (pick == null) continue;
      final label = RegExp(r'teaser', caseSensitive: false).hasMatch(pick.title) ? 'Teaser' : 'Trailer';
      final clip = _plex(c.serverId, pick.partKey, 'plex:${pick.ratingKey}', label);
      if (clip == null) {
        // The server dropped between the read and the URL.
        sure = false;
        offline.add(c.serverId);
        continue;
      }
      return _Run(
        (clip, {'k': 'plex', 'sv': c.serverId, 'pk': pick.partKey, 'a': clip.assetId, 'l': label}),
        sure: sure,
        offline: offline,
      );
    }
    return _Run(null, sure: sure, offline: offline);
  }

  /// AnimeThemes OP1 for [t], and whether the answer is sure: no mapping or
  /// no record is sure, a failed lookup (429, 5xx, the local cap, a changed
  /// response) is not.
  Future<(AnimeOpening?, bool)> _opening(ReelTitle t) async {
    try {
      final id = await aniList(t);
      if (id == null) return (null, true);
      final anime = (await _animeThemes([id]))[id];
      return (anime == null ? null : ClipFilter.firstOpening(anime), true);
    } catch (e) {
      appLogger.d('Reel: AnimeThemes lookup failed', error: e);
      return (null, false);
    }
  }
}

/// AnimeThemes couldn't answer: rate limited (429 with Retry-After, or this
/// client's own cap), a non-200 (a 404 or 410 once an endpoint is retired),
/// GraphQL errors, or a response that no longer has the expected shape. The
/// resolver counts it as unknown, never a miss.
class AnimeThemesUnavailable implements Exception {
  const AnimeThemesUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'AnimeThemesUnavailable: $reason';
}

/// AnimeThemes (volunteer-run) over its GraphQL API, which replaces the
/// deprecated JSON:API: batched lookups by AniList id through
/// `findAnimeByExternalSite`, under 90 requests a minute, honouring
/// Retry-After (https://api-docs.animethemes.moe/graphql/intro/ratelimiting/).
/// Throws [AnimeThemesUnavailable] when it can't answer, so a blocked or
/// failed lookup never reads as "no record".
///
/// The query's fields come from the live schema and one recorded response
/// (test/reel/fixtures/animethemes_graphql_op.json). Each anime is returned
/// in the record shape [ClipFilter.firstOpening] reads: `animethemes[]`
/// .type/sequence/song.title, `animethemeentries[]`.episodes/spoiler/nsfw,
/// `videos[]`.id/link/nc/resolution/size, plus overlap/lyrics/subbed/source
/// as the API spells them (`NONE`/`TRANS`/`OVER`, `BD`, `WEB`, …).
class AnimeThemesClient {
  AnimeThemesClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final List<DateTime> _recent = [];
  DateTime? _blockedUntil;

  static const int perMinute = 80;

  /// Ids per request; a longer list is split into requests of this size.
  static const int maxBatch = 50;

  static final Uri endpoint = Uri.https('graphql.animethemes.moe', '/');

  /// Openings only: the ladder never plays an ED or an insert song.
  static const String query = r'''
query ReelOpenings($ids: [Int!]) {
  findAnimeByExternalSite(site: ANILIST, id: $ids) {
    resources(site: ANILIST) { nodes { site externalId } }
    animethemes(type: OP) {
      type
      sequence
      song { title { romaji } }
      animethemeentries {
        episodes
        spoiler
        nsfw
        videos { nodes { id link nc resolution size overlap lyrics subbed source } }
      }
    }
  }
}''';

  Future<Map<int, Map<String, dynamic>>> fetch(List<int> anilistIds) async {
    final ids = anilistIds.toSet().toList();
    final out = <int, Map<String, dynamic>>{};
    for (var i = 0; i < ids.length; i += maxBatch) {
      out.addAll(await _fetchBatch(ids.sublist(i, (i + maxBatch).clamp(0, ids.length))));
    }
    return out;
  }

  Future<Map<int, Map<String, dynamic>>> _fetchBatch(List<int> ids) async {
    final now = DateTime.now();
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) throw const AnimeThemesUnavailable('blocked');
    _recent.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_recent.length >= perMinute) throw const AnimeThemesUnavailable('local cap');
    _recent.add(now);
    final res = await _client
        .post(
          endpoint,
          headers: const {'Content-Type': 'application/json', 'Accept': 'application/json', 'User-Agent': 'Plezy'},
          body: jsonEncode({
            'query': query,
            'variables': {'ids': ids},
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 429) {
      final wait = int.tryParse(res.headers['retry-after'] ?? '') ?? 60;
      _blockedUntil = now.add(Duration(seconds: wait));
      throw const AnimeThemesUnavailable('429');
    }
    if (res.statusCode != 200) throw AnimeThemesUnavailable('HTTP ${res.statusCode}');
    final Object? body;
    try {
      body = jsonDecode(res.body);
    } on FormatException {
      throw const AnimeThemesUnavailable('not JSON');
    }
    if (body is! Map) throw const AnimeThemesUnavailable('not an object');
    // Validation, depth and complexity errors come back as a 200 with
    // `errors`; a partial answer is no answer.
    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty) throw const AnimeThemesUnavailable('GraphQL errors');
    final data = body['data'];
    final list = data is Map ? data['findAnimeByExternalSite'] : null;
    if (list is! List) throw const AnimeThemesUnavailable('no anime list');
    final out = <int, Map<String, dynamic>>{};
    for (final a in list) {
      final record = _record(a);
      for (final r in _nodes((a as Map)['resources'])) {
        if (r['site'] == 'ANILIST' && r['externalId'] is int) out[r['externalId'] as int] = record;
      }
    }
    return out;
  }

  /// One GraphQL anime as the record [ClipFilter.firstOpening] reads. Any
  /// part not shaped as queried throws: a changed schema must never read as
  /// "this title has no opening".
  static Map<String, dynamic> _record(Object? a) {
    if (a is! Map) throw const AnimeThemesUnavailable('anime not an object');
    final themes = a['animethemes'];
    if (themes is! List) throw const AnimeThemesUnavailable('no animethemes list');
    return {
      'animethemes': [
        for (final t in themes)
          if (t is Map)
            {
              'type': t['type'],
              'sequence': t['sequence'],
              'song': {'title': ((t['song'] as Map?)?['title'] as Map?)?['romaji']},
              'animethemeentries': [
                for (final e in _list(t['animethemeentries'], 'animethemeentries'))
                  {
                    'episodes': e['episodes'],
                    'spoiler': e['spoiler'],
                    'nsfw': e['nsfw'],
                    'videos': [for (final v in _nodes(e['videos'])) Map<String, dynamic>.from(v)],
                  },
              ],
            },
      ],
    };
  }

  static List<Map> _list(Object? v, String what) {
    if (v is! List) throw AnimeThemesUnavailable('no $what list');
    return [
      for (final x in v)
        if (x is Map) x,
    ];
  }

  /// A connection's `nodes`.
  static List<Map> _nodes(Object? connection) => _list(connection is Map ? connection['nodes'] : null, 'nodes');
}
