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
  Future<List<PlexExtraClip>> extras(String serverId, String ratingKey, {required Duration timeout});

  /// The direct-play URL for a clip part on [serverId], or null when that
  /// server isn't connected.
  String? clipUrl(String serverId, String partKey);
}

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

/// Maps an anime title to its season-1 AniList id (Fribb), or null.
typedef AniListLookup = Future<int?> Function(ReelTitle title);

/// Fetches AnimeThemes `anime` records for AniList ids, keyed by AniList id.
typedef AnimeThemesFetch = Future<Map<int, Map<String, dynamic>>> Function(List<int> anilistIds);

/// The clip ladder (spec §5), cheapest for the guest servers first:
/// anime → AnimeThemes OP1, else a Plex extra (Teaser / plain trailer), else
/// an AI card (null). Caches the asset identity per title for 30 days
/// (`src:<groupKey>`), never a resolved CDN URL. One request at a time, per
/// title, on demand: never a batch or crawl of a server.
class ClipResolver {
  ClipResolver({
    required this.servers,
    required this.store,
    required this.aniList,
    AnimeThemesFetch? animeThemes,
    this.firstTry = const Duration(seconds: 5),
    this.captions,
  }) : _animeThemes = animeThemes ?? AnimeThemesClient().fetch;

  final ReelServers servers;
  final ReelStore store;
  final AniListLookup aniList;
  final AnimeThemesFetch _animeThemes;

  /// A server gets one try this long; a timeout marks it slow for the
  /// session and the miss is cached for 30 days.
  final Duration firstTry;

  /// The Reel's captions pref (V2-54): openings with lyrics or subtitles
  /// first. Read per resolve, so a change applies to the next card. Null is
  /// off.
  final bool Function()? captions;
  final Set<String> _slowServers = {};
  Future<void> _queue = Future.value();

  /// Servers whose extras call timed out this session.
  Set<String> get slowServers => Set.unmodifiable(_slowServers);

  Future<ResolvedClip?> resolve(ReelTitle t) async {
    final spoiled = await store.spoiledAssets(t.titleId);
    // An anime show's pick depends on the captions pref, so each choice
    // keeps its own entry: switching it re-picks instead of replaying the
    // other choice's opening for 30 days. Other titles keep one entry.
    final cc = t.anime && t.isShow && (captions?.call() ?? false);
    final key = 'src:${t.groupKey}${cc ? ':cc' : ''}';
    final cached = await store.cached(key, ttl: ReelStore.sourceTtl);
    if (cached != null) {
      final hit = _fromCache(cached, spoiled);
      if (hit != null || cached == _miss) return hit;
    }
    final found = await _serial(() => _resolveFresh(t, spoiled, captions: cc));
    await store.cache(key, found == null ? _miss : jsonEncode(found.$2));
    return found?.$1;
  }

  static const String _miss = '{"miss":true}';

  ResolvedClip? _fromCache(String raw, Set<String> spoiled) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['miss'] == true) return null;
      final asset = j['a'] as String;
      if (spoiled.contains(asset)) return null;
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

  Future<T> _serial<T>(Future<T> Function() run) {
    final next = _queue.then((_) => run());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<(ResolvedClip, Map<String, Object?>)?> _resolveFresh(
    ReelTitle t,
    Set<String> spoiled, {
    required bool captions,
  }) async {
    if (t.anime && t.isShow) {
      final op = await _opening(t, captions: captions);
      if (op != null && !spoiled.contains('at:${op.videoId}')) {
        final clip = ResolvedClip(
          source: ClipSource(uri: op.url, origin: ClipOrigin.animeTheme),
          assetId: 'at:${op.videoId}',
          label: 'Opening 1',
        );
        return (clip, {'k': 'at', 'u': op.url, 'a': clip.assetId, 'l': clip.label});
      }
    }
    // Plex extras: HD copies first, then 4K, skipping servers already slow.
    final copies = [...t.copies]..sort((a, b) => (a.is4k ? 1 : 0).compareTo(b.is4k ? 1 : 0));
    final triedServers = <String>{};
    for (final c in copies) {
      if (_slowServers.contains(c.serverId) || !triedServers.add(c.serverId)) continue;
      List<PlexExtraClip> extras;
      try {
        extras = await servers.extras(c.serverId, c.ratingKey, timeout: firstTry);
      } on TimeoutException {
        _slowServers.add(c.serverId);
        appLogger.d('Reel: extras timed out on one server; skipping it this session');
        continue;
      } catch (e) {
        appLogger.d('Reel: extras read failed', error: e);
        continue;
      }
      final usable = [
        for (final e in extras)
          if (!spoiled.contains('plex:${e.ratingKey}')) e,
      ];
      final pick = t.isShow ? ClipFilter.showTrailer(usable, showTitle: t.title) : ClipFilter.filmTrailer(usable);
      if (pick == null) continue;
      final label = RegExp(r'teaser', caseSensitive: false).hasMatch(pick.title) ? 'Teaser' : 'Trailer';
      final clip = _plex(c.serverId, pick.partKey, 'plex:${pick.ratingKey}', label);
      if (clip == null) continue;
      return (clip, {'k': 'plex', 'sv': c.serverId, 'pk': pick.partKey, 'a': clip.assetId, 'l': label});
    }
    return null;
  }

  Future<AnimeOpening?> _opening(ReelTitle t, {required bool captions}) async {
    final id = await aniList(t);
    if (id == null) return null;
    try {
      final anime = (await _animeThemes([id]))[id];
      return anime == null ? null : ClipFilter.firstOpening(anime, captions: captions);
    } catch (e) {
      appLogger.d('Reel: AnimeThemes lookup failed', error: e);
      return null;
    }
  }
}

/// AnimeThemes (volunteer-run): batched lookups by AniList id, under 90
/// requests a minute, honouring Retry-After. Fields verified against a live
/// `/anime` response (animethemes[].type/sequence, animethemeentries[]
/// .episodes/spoiler/nsfw, videos[].link/nc/resolution/size). videos[]
/// .lyrics/subbed are booleans like `nc` (animethemes-server
/// app/Models/Wiki/Video.php casts, Api/Schema/Wiki/VideoSchema.php fields).
class AnimeThemesClient {
  AnimeThemesClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final List<DateTime> _recent = [];
  DateTime? _blockedUntil;

  static const int perMinute = 80;

  Future<Map<int, Map<String, dynamic>>> fetch(List<int> anilistIds) async {
    if (anilistIds.isEmpty) return const {};
    final now = DateTime.now();
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) return const {};
    _recent.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_recent.length >= perMinute) return const {};
    _recent.add(now);
    final uri = Uri.https('api.animethemes.moe', '/anime', {
      'filter[has]': 'resources',
      'filter[site]': 'AniList',
      'filter[external_id]': anilistIds.join(','),
      'include': 'resources,animethemes.animethemeentries.videos,animethemes.song',
      'page[size]': '${anilistIds.length.clamp(1, 50)}',
    });
    final res = await _client
        .get(uri, headers: const {'Accept': 'application/json', 'User-Agent': 'Plezy'})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 429) {
      final wait = int.tryParse(res.headers['retry-after'] ?? '') ?? 60;
      _blockedUntil = now.add(Duration(seconds: wait));
      return const {};
    }
    if (res.statusCode != 200) return const {};
    final out = <int, Map<String, dynamic>>{};
    for (final a in ((jsonDecode(res.body) as Map)['anime'] as List? ?? const [])) {
      if (a is! Map<String, dynamic>) continue;
      for (final r in (a['resources'] as List? ?? const [])) {
        if (r is Map && r['site'] == 'AniList' && r['external_id'] is int) out[r['external_id'] as int] = a;
      }
    }
    return out;
  }
}
