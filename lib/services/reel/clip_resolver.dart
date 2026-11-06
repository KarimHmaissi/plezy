import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import 'clip_filter.dart';
import 'clip_player.dart';
import 'feed_youtube.dart' show ReelYouTube;
import 'reel_playback_profile.dart';
import 'reel_store.dart';
import 'reel_tmdb.dart';

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

/// One file of a clip with several (an opening at 720 and 1080, with and
/// without credits). The resolver keeps them all with what ranks them, and
/// the playback profile picks one when the card plays (plan V2-16, V2-17),
/// so a change of screen or of the captions pref needs no new lookup.
class ClipCandidate implements ReelRendition {
  const ClipCandidate({
    required this.uri,
    required this.assetId,
    this.height,
    this.sizeBytes,
    this.transition = false,
    this.creditless = false,
    this.captioned = false,
    this.source,
  });

  /// An opening's file as cached.
  factory ClipCandidate.opening(AnimeOpening op) => ClipCandidate(
    uri: op.url,
    assetId: 'at:${op.videoId}',
    height: op.resolution,
    sizeBytes: op.sizeBytes,
    transition: op.transition,
    creditless: op.creditless,
    captioned: op.captioned,
    source: op.source,
  );

  final String uri;

  /// `at:<video id>`.
  final String assetId;
  @override
  final int? height;
  @override
  final int? sizeBytes;

  /// See [AnimeOpening.transition], [AnimeOpening.creditless],
  /// [AnimeOpening.captioned] and [AnimeOpening.source].
  final bool transition;
  final bool creditless;
  final bool captioned;
  final String? source;

  @override
  int rankFor(ReelPlaybackProfile profile) => ClipFilter.openingRank(
    transition: transition,
    creditless: creditless,
    captioned: captioned,
    source: source,
    captions: profile.captions,
  );

  Map<String, Object?> toJson() => {
    'a': assetId,
    'u': uri,
    'h': height,
    'sz': sizeBytes,
    'tr': transition,
    'nc': creditless,
    'cc': captioned,
    'so': source,
  };

  /// A cached candidate, or null when it isn't shaped as written.
  static ClipCandidate? fromJson(Object? j) {
    if (j is! Map) return null;
    final (a, u, h, sz, so) = (j['a'], j['u'], j['h'], j['sz'], j['so']);
    final (tr, nc, cc) = (j['tr'], j['nc'], j['cc']);
    if (a is! String || u is! String || !u.startsWith('https://')) return null;
    if ((h != null && h is! int) || (sz != null && sz is! int) || (so != null && so is! String)) return null;
    if (tr is! bool || nc is! bool || cc is! bool) return null;
    return ClipCandidate(
      uri: u,
      assetId: a,
      height: h as int?,
      sizeBytes: sz as int?,
      transition: tr,
      creditless: nc,
      captioned: cc,
      source: so as String?,
    );
  }
}

/// What a clip is, for its chip. The views name it in the app's language
/// when they draw it; the cache stores the kind, never the words.
enum ClipKind {
  trailer,
  teaser,
  opening;

  /// The kind a cached row written before the kind was stored says in its
  /// English label ("Trailer", "Teaser", "Opening 1"), with the opening's
  /// number; null when the label says neither.
  static (ClipKind, int?)? fromLegacyLabel(Object? label) {
    if (label is! String) return null;
    final l = label.trim();
    if (RegExp(r'^teaser$', caseSensitive: false).hasMatch(l)) return (ClipKind.teaser, null);
    if (RegExp(r'^trailer$', caseSensitive: false).hasMatch(l)) return (ClipKind.trailer, null);
    final op = RegExp(r'^opening(?:\s+(\d+))?$', caseSensitive: false).firstMatch(l);
    if (op != null) return (ClipKind.opening, int.tryParse(op.group(1) ?? ''));
    return null;
  }

  /// The kind of a Plex extra by its title: a teaser says so, anything else
  /// the ladder picks is a trailer.
  static ClipKind ofExtraTitle(String title) =>
      RegExp(r'teaser', caseSensitive: false).hasMatch(title) ? ClipKind.teaser : ClipKind.trailer;
}

/// A resolved rung: where the clip is and what it is.
class ResolvedClip {
  const ResolvedClip({
    required this.source,
    required this.assetId,
    required this.kind,
    this.number,
    this.serverId,
    this.height,
    this.candidates = const [],
  });

  final ClipSource source;

  /// `plex:<extra ratingKey>`, `at:<video id>` or `yt:<YouTube id>`, for
  /// Spoiled me.
  final String assetId;

  /// Trailer, teaser or opening; the views name it ("Opening 1").
  final ClipKind kind;

  /// An opening's number (1 for OP1); null for a trailer or teaser.
  final int? number;

  /// Plex rungs: the server the clip streams from (never preloaded off a
  /// server marked slow).
  final String? serverId;

  /// The picked file's height, when the source says it.
  final int? height;

  /// Every file of this clip, the picked one included; empty for a Plex
  /// trailer, which has the one file. [ClipResolver.repick] chooses again
  /// from these when the playback profile changes.
  final List<ClipCandidate> candidates;
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

/// How the TMDB rung (V2-63) answered a title.
enum _TmdbAnswer {
  /// Not asked: there is no rung here (the TV), it is off for now (Data
  /// saver, Stills only), there is no TMDB key, or an earlier rung couldn't
  /// answer.
  notAsked,

  /// Asked, and it has no trailer to play.
  none,

  /// Asked, and it couldn't answer (a timeout, a 401, a 429, a 5xx).
  unknown,
}

/// One ladder run: the hit, whether every rung before TMDB answered for
/// sure, the servers that weren't connected, and how TMDB answered.
class _Run {
  _Run(this.hit, {required this.sure, required this.offline, this.tmdb = _TmdbAnswer.notAsked});

  final (ResolvedClip, Map<String, Object?>)? hit;
  final bool sure;
  final Set<String> offline;
  final _TmdbAnswer tmdb;

  ClipAnswer get answer => hit != null
      ? ClipAnswer.found
      : sure && tmdb != _TmdbAnswer.unknown
      ? ClipAnswer.none
      : ClipAnswer.unknown;
}

/// The clip ladder (spec §5), cheapest for the guest servers first:
/// anime → AnimeThemes OP1, else a Plex extra (Teaser / plain trailer), else
/// (the phone only, [tmdb]) a TMDB YouTube trailer, else an AI card. Caches the asset identity per title for 30 days
/// (`src:<groupKey>`), never a resolved CDN URL. A miss is cached only when
/// every rung answered for sure; a rung that couldn't answer leaves the
/// title unknown, which lasts for the session only. Plex servers get one
/// request at a time, per title, on demand: never a batch or crawl of a
/// server. AnimeThemes is asked once per deck open for the deck's anime
/// shows ([warm]). A clip with several files (an opening at 720 and 1080)
/// caches them all, and the playback [profile] picks one each time the title
/// is looked up.
class ClipResolver {
  ClipResolver({
    required this.servers,
    required this.store,
    required this.aniList,
    AnimeThemesFetch? animeThemes,
    this.waitForServer,
    this.firstTry = const Duration(seconds: 5),
    this.profile,
    this.tmdb,
  }) : _animeThemes = animeThemes ?? AnimeThemesClient().fetch;

  /// The TMDB trailer rung (plan V2-63): the phone only. Null on the TV,
  /// which has no WebView, so its clip-less titles stay AI cards.
  final ReelTmdbRung? tmdb;

  /// Whether the TMDB rung may run now (never throws).
  bool get tmdbOn {
    final rung = tmdb;
    if (rung == null) return false;
    try {
      return rung.on();
    } catch (_) {
      return false;
    }
  }

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

  /// The device's playback profile, rebuilt when the screen or network
  /// changes (plan V2-16). Null plays [ReelPlaybackProfile.standard].
  final ValueListenable<ReelPlaybackProfile>? profile;

  ReelPlaybackProfile get playback => profile?.value ?? ReelPlaybackProfile.standard;

  /// The `src:` row format. Rows written before it (one file per title, a
  /// miss cached by the older ladder, or candidates cached before `overlap`
  /// was read, which may include an opening with episode footage over it)
  /// read as not cached, so the title is resolved once more and every
  /// candidate is stored with what ranks it.
  static const int sourceFormat = 3;

  final Set<String> _slowServers = {};
  final Map<String, Future<bool>> _waits = {};

  /// Per server (and one for AnimeThemes), the tail of its requests: one in
  /// flight at a time (§9), and a server never waits on another. The order
  /// the cards ask in is the prefetcher's (plan V2-11).
  final Map<String, Future<void>> _lanes = {};

  /// Season 1 OP1's files per AniList id, as AnimeThemes answered this
  /// session; an empty list is a sure "no opening". Failed lookups are never
  /// kept, so they are asked again.
  final Map<int, List<AnimeOpening>> _openingsById = {};

  /// Anime shows a [warm] batch is answering, by group key: the ladder waits
  /// for the batch rather than asking AnimeThemes about the one title.
  final Map<String, Future<void>> _warming = {};

  /// Servers whose extras call timed out this session. Their clips are
  /// never preloaded ([ClipSource.preloadable]).
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
    final entry = cached == null ? null : _entry(cached);
    if (entry != null) {
      if (entry['miss'] == true) {
        // The servers (and AnimeThemes) said no. TMDB wasn't asked when the
        // row was written (no rung then, or it was off): ask it alone now,
        // with no server read.
        if (entry['tm'] != true && tmdbOn) return _tmdbOnly(t, key, banned, exclude);
        return const ClipLookup.none();
      }
      if (entry['k'] == 'yt') {
        // A YouTube trailer this device can't play now (Data saver, Stills
        // only): an AI card for the session; the row is kept.
        if (!tmdbOn) return const ClipLookup.unknown();
        // It failed or was marked as a spoiler: the servers said no when it
        // was found, so only TMDB is asked again.
        if (_assets(entry).any(banned.contains)) return _tmdbOnly(t, key, banned, exclude);
      }
      final assets = _assets(entry);
      if (assets.isNotEmpty && !assets.any(banned.contains)) {
        var hit = _fromCache(entry);
        if (hit == null && entry['k'] == 'plex' && entry['sv'] is String) {
          // A good identity whose server is offline is kept, never
          // overwritten by a miss.
          keep = true;
          final sv = entry['sv'] as String;
          if (await _awaitServer(sv)) hit = _fromCache(entry);
        }
        if (hit != null) return ClipLookup.found(hit);
      }
    }
    var run = await _ladder(t, banned);
    if (run.answer == ClipAnswer.unknown && run.offline.isNotEmpty) {
      final back = await Future.wait([for (final s in run.offline) _awaitServer(s)]);
      if (back.contains(true)) run = await _ladder(t, banned);
    }
    final hit = run.hit;
    if (hit != null) {
      if (!keep) await store.cache(key, jsonEncode(hit.$2));
      return ClipLookup.found(hit.$1);
    }
    if (run.sure && !keep) {
      // The servers' answer is kept even while TMDB's is unknown, so the
      // next lookup asks TMDB alone and no server again.
      if (exclude.isEmpty) await store.cache(key, run.tmdb == _TmdbAnswer.none ? missRowWithTmdb : missRow);
      if (run.tmdb != _TmdbAnswer.unknown) return const ClipLookup.none();
    }
    appLogger.d('Reel: clip answer unknown for now; not cached');
    return const ClipLookup.unknown();
  }

  /// A definitive miss in the current [sourceFormat] from the servers and
  /// AnimeThemes, with TMDB not asked.
  static const String missRow = '{"v":$sourceFormat,"miss":true}';

  /// A definitive miss that TMDB answered too (V2-63).
  static const String missRowWithTmdb = '{"v":$sourceFormat,"miss":true,"tm":true}';

  /// The TMDB rung alone, for a title whose other rungs already said no: a
  /// trailer is cached as found, a sure no as a miss TMDB answered, and an
  /// unknown leaves the row as it was. With assets [exclude]d (a trailer
  /// that just failed), a no is not cached: the trailer may play next time.
  Future<ClipLookup> _tmdbOnly(ReelTitle t, String key, Set<String> banned, Set<String> exclude) async {
    final (answer, hit) = await _tmdbRung(t, banned);
    if (hit != null) {
      await store.cache(key, jsonEncode(hit.$2));
      return ClipLookup.found(hit.$1);
    }
    switch (answer) {
      case _TmdbAnswer.none:
        if (exclude.isEmpty) await store.cache(key, missRowWithTmdb);
        return const ClipLookup.none();
      case _TmdbAnswer.notAsked:
        // No key, or the rung went off meanwhile: the servers' no stands.
        return const ClipLookup.none();
      case _TmdbAnswer.unknown:
        return const ClipLookup.unknown();
    }
  }

  /// The TMDB lane's key.
  static const String _tmdbLane = ':tmdb';

  /// TMDB's trailer for [t] (V2-21 rules: official YouTube, a Trailer before
  /// a Teaser, the app's language first, the earliest), skipping [banned]
  /// ones and keys that aren't YouTube ids. A title with no TMDB id has none.
  Future<(_TmdbAnswer, (ResolvedClip, Map<String, Object?>)?)> _tmdbRung(ReelTitle t, Set<String> banned) async {
    final rung = tmdb;
    if (rung == null || !tmdbOn) return (_TmdbAnswer.notAsked, null);
    final id = t.tmdbId;
    if (id == null) {
      appLogger.i('[ReelTmdb] no TMDB id: none');
      return (_TmdbAnswer.none, null);
    }
    final String language;
    final List<dynamic>? results;
    try {
      language = rung.language();
      results = await _inLane(_tmdbLane, () => rung.fetch(id: id, show: t.isShow, language: language));
    } catch (e) {
      appLogger.i('[ReelTmdb] videos unknown (${e is TmdbUnavailable ? e.reason : e.runtimeType})');
      return (_TmdbAnswer.unknown, null);
    }
    if (results == null) {
      appLogger.d('[ReelTmdb] no TMDB key: rung skipped');
      return (_TmdbAnswer.notAsked, null);
    }
    final usable = [
      for (final r in results)
        if (r is Map && r['key'] is String && ReelYouTube.videoId.hasMatch((r['key'] as String).trim()))
          if (!banned.contains('yt:${(r['key'] as String).trim()}')) r,
    ];
    final pick = ClipFilter.tmdbTrailer(usable, language: language, show: t.isShow);
    if (pick == null) {
      appLogger.i('[ReelTmdb] ${results.length} videos, no trailer to play: none');
      return (_TmdbAnswer.none, null);
    }
    final kind = pick.typeRank == 1 ? ClipKind.teaser : ClipKind.trailer;
    final clip = _youTube(pick.key, kind);
    appLogger.i('[ReelTmdb] ${results.length} videos, picked a ${kind.name}');
    return (_TmdbAnswer.none, (clip, _youTubeRow(clip, pick.key)));
  }

  /// The `src:` row for a TMDB YouTube trailer.
  static Map<String, Object?> _youTubeRow(ResolvedClip clip, String id) => {
    'v': sourceFormat,
    'k': 'yt',
    'a': clip.assetId,
    ..._kindRow(clip),
    'yk': id,
  };

  /// A YouTube trailer as the phone feed plays it: never preloaded with the
  /// cards around it (only the card on screen opens a player page).
  static ResolvedClip _youTube(String id, ClipKind kind) => ResolvedClip(
    source: ClipSource(uri: ReelYouTube.watchUri(id), origin: ClipOrigin.youtube, preloadable: false),
    assetId: 'yt:$id',
    kind: kind,
  );

  /// Asks AnimeThemes about a deck's anime shows when the deck loads (plan
  /// V2-12): each show is mapped to its AniList id locally (Fribb), then the
  /// ids not yet answered this session go in one request per
  /// [AnimeThemesClient.maxBatch], in deck order. A show whose opening is
  /// found has its `src:` row written as the ladder writes it. A show with
  /// no opening is kept as a sure answer for the session only: its Plex
  /// extras are still read per title, on demand, before any miss is cached.
  /// A failed or blocked batch (429, the local cap) writes and keeps
  /// nothing, so its shows resolve one by one as before. Shows with a
  /// cached row are skipped. Never throws.
  Future<void> warm(List<ReelTitle> titles) async {
    final keys = <String>{};
    final shows = [
      for (final t in titles)
        if (t.anime && t.isShow && !_warming.containsKey(t.groupKey) && keys.add(t.groupKey)) t,
    ];
    if (shows.isEmpty) return;
    // Registered before the first await, so a card resolving straight after
    // the deck loads waits for this batch.
    final done = {for (final t in shows) t.groupKey: Completer<void>()};
    for (final t in shows) {
      _warming[t.groupKey] = done[t.groupKey]!.future;
    }
    void finish(ReelTitle t) {
      final c = done[t.groupKey]!;
      if (c.isCompleted) return;
      c.complete();
      if (identical(_warming[t.groupKey], c.future)) _warming.remove(t.groupKey);
    }

    final sw = Stopwatch()..start();
    var requests = 0;
    var hits = 0;
    try {
      final idOf = await Future.wait([
        for (final t in shows)
          () async {
            try {
              final raw = await store.cached('src:${t.groupKey}', ttl: ReelStore.sourceTtl);
              if (raw != null && _entry(raw) != null) return null;
              return await aniList(t);
            } catch (_) {
              // The mapping couldn't be read: the ladder asks again.
              return null;
            }
          }(),
      ]);
      final asking = <int>[];
      for (final (i, t) in shows.indexed) {
        final id = idOf[i];
        if (id == null) {
          finish(t);
        } else if (!_openingsById.containsKey(id) && !asking.contains(id)) {
          asking.add(id);
        }
      }
      for (var i = 0; i < asking.length; i += AnimeThemesClient.maxBatch) {
        final chunk = asking.sublist(i, (i + AnimeThemesClient.maxBatch).clamp(0, asking.length));
        final Map<int, Map<String, dynamic>> got;
        try {
          requests++;
          got = await _animeThemes(chunk);
        } catch (e) {
          appLogger.d('Reel: AnimeThemes batch failed; its shows resolve one by one', error: e);
          break;
        }
        for (final id in chunk) {
          try {
            _openingsById[id] = got[id] == null ? const [] : ClipFilter.openings(got[id]!);
          } catch (_) {
            // Not shaped as read: unknown, asked again per title.
          }
        }
        for (final (j, t) in shows.indexed) {
          final id = idOf[j];
          if (id == null || done[t.groupKey]!.isCompleted || !_openingsById.containsKey(id)) continue;
          if (await _writeOpening(t, _openingsById[id]!)) hits++;
          finish(t);
        }
      }
      // Shows answered by an earlier batch this session.
      for (final (j, t) in shows.indexed) {
        final id = idOf[j];
        if (id == null || done[t.groupKey]!.isCompleted) continue;
        if (_openingsById[id] case final ops?) {
          if (await _writeOpening(t, ops)) hits++;
        }
        finish(t);
      }
    } catch (e) {
      appLogger.d('Reel: AnimeThemes warm failed', error: e);
    } finally {
      shows.forEach(finish);
    }
    appLogger.i(
      '[ReelWarm] ${shows.length} anime shows: $requests requests, $hits openings (${sw.elapsedMilliseconds}ms)',
    );
  }

  /// Writes [t]'s `src:` row for [ops] as the ladder would; false when the
  /// ladder would go on to the Plex rung (no file this profile plays, or a
  /// file the user marked as a spoiler).
  Future<bool> _writeOpening(ReelTitle t, List<AnimeOpening> ops) async {
    try {
      final candidates = [for (final op in ops) ClipCandidate.opening(op)];
      if (candidates.isEmpty) return false;
      final banned = await store.spoiledAssets(t.titleId);
      if (candidates.any((c) => banned.contains(c.assetId))) return false;
      final clip = _opening1(1, candidates);
      if (clip == null) return false;
      await store.cache('src:${t.groupKey}', jsonEncode(_openingRow(clip, candidates)));
      return true;
    } catch (e) {
      appLogger.d('Reel: AnimeThemes warm could not cache a show', error: e);
      return false;
    }
  }

  /// The `src:` row for an AnimeThemes clip.
  static Map<String, Object?> _openingRow(ResolvedClip clip, List<ClipCandidate> candidates) => {
    'v': sourceFormat,
    'k': 'at',
    ..._kindRow(clip),
    'c': [for (final c in candidates) c.toJson()],
  };

  /// A row's clip kind: `lk` (the [ClipKind] name) and, for an opening,
  /// `ln` (its number). Rows written before carry an English `l` instead,
  /// still read by [_kindOf].
  static Map<String, Object?> _kindRow(ResolvedClip clip) => {'lk': clip.kind.name, 'ln': ?clip.number};

  /// The kind and number a cached row says: `lk`/`ln`, else the older
  /// English `l`, else [fallback] (an AnimeThemes row is OP1).
  static (ClipKind, int?) _kindOf(Map<String, dynamic> j, (ClipKind, int?) fallback) {
    final lk = j['lk'];
    if (lk is String) {
      final kind = ClipKind.values.where((k) => k.name == lk).firstOrNull;
      if (kind != null) {
        final n = j['ln'];
        return (kind, n is int ? n : fallback.$2);
      }
    }
    final legacy = ClipKind.fromLegacyLabel(j['l']);
    if (legacy != null) return (legacy.$1, legacy.$2 ?? fallback.$2);
    return fallback;
  }

  /// A cached row in the current [sourceFormat]; anything else (an older
  /// format, a forgotten or unreadable row) is not cached.
  static Map<String, dynamic>? _entry(String raw) {
    try {
      final j = jsonDecode(raw);
      return j is Map<String, dynamic> && j['v'] == sourceFormat ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// Every asset a cached row can play.
  static List<String> _assets(Map<String, dynamic> j) => switch (j['k']) {
    'at' => [
      for (final c in (j['c'] is List ? j['c'] as List : const []))
        if (c is Map && c['a'] is String) c['a'] as String,
    ],
    'plex' || 'yt' => [if (j['a'] case final String a) a],
    _ => const [],
  };

  /// What the cached `src:` rows alone say about [titles]' clips, by group
  /// key: [ClipAnswer.found] for a row with a clip, [ClipAnswer.none] for a
  /// cached miss. A title with no usable row (none, expired, or an older
  /// format) is left out. Reads no server and resolves nothing (the warm
  /// start before the Reel opens, V2-14).
  static Future<Map<String, ClipAnswer>> cachedAnswers(ReelStore store, Iterable<ReelTitle> titles) async {
    final rows = await store.cachedMany({for (final t in titles) 'src:${t.groupKey}'}, ttl: ReelStore.sourceTtl);
    return {
      for (final MapEntry(:key, :value) in rows.entries)
        if (_entry(value) case final e?)
          if (e['miss'] == true)
            key.substring(4): ClipAnswer.none
          else if (_assets(e).isNotEmpty)
            key.substring(4): ClipAnswer.found,
    };
  }

  /// The group keys of [titles] whose cached answer is a miss (an AI card):
  /// cached `src:` rows in the current [sourceFormat] only, so nothing is
  /// resolved and no server is asked. A title with no row, or an older
  /// format's row, is left out (assumed to have a clip until it is resolved
  /// on demand), and so is a miss TMDB hasn't answered while the TMDB rung
  /// is on (it may have a trailer).
  Future<Set<String>> knownMisses(Iterable<ReelTitle> titles) async {
    final keys = {for (final t in titles) 'src:${t.groupKey}'};
    final rows = await store.cachedMany(keys, ttl: ReelStore.sourceTtl);
    final askTmdb = tmdbOn;
    return {
      for (final MapEntry(:key, :value) in rows.entries)
        if (_entry(value) case final e? when e['miss'] == true && (e['tm'] == true || !askTmdb)) key.substring(4),
    };
  }

  ResolvedClip? _fromCache(Map<String, dynamic> j) {
    try {
      return switch (j['k']) {
        'at' => _opening1(_kindOf(j, (ClipKind.opening, 1)).$2 ?? 1, _candidates(j['c'])),
        'plex' => _plex(
          j['sv'] as String,
          j['pk'] as String,
          j['a'] as String,
          _kindOf(j, (ClipKind.trailer, null)).$1,
        ),
        'yt' when ReelYouTube.videoId.hasMatch(j['yk'] as String) && j['a'] == 'yt:${j['yk']}' => _youTube(
          j['yk'] as String,
          _kindOf(j, (ClipKind.trailer, null)).$1,
        ),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  /// A cached candidate list, or empty when any entry isn't shaped as
  /// written (the row is then resolved again).
  static List<ClipCandidate> _candidates(Object? raw) {
    if (raw is! List) return const [];
    final out = <ClipCandidate>[];
    for (final j in raw) {
      final c = ClipCandidate.fromJson(j);
      if (c == null) return const [];
      out.add(c);
    }
    return out;
  }

  /// Opening [number] of an AnimeThemes show as [playback] plays it from
  /// [candidates]; null for none.
  ResolvedClip? _opening1(int number, List<ClipCandidate> candidates) {
    final pick = playback.pick(candidates);
    if (pick == null) return null;
    return ResolvedClip(
      source: ClipSource(uri: pick.uri, origin: ClipOrigin.animeTheme),
      assetId: pick.assetId,
      kind: ClipKind.opening,
      number: number,
      height: pick.height,
      candidates: candidates,
    );
  }

  /// [clip] as the current profile plays it: another of its candidates when
  /// the profile now picks one, else [clip] itself (identical).
  ResolvedClip repick(ResolvedClip clip) {
    if (clip.candidates.length < 2) return clip;
    final pick = playback.pick(clip.candidates);
    if (pick == null || pick.assetId == clip.assetId) return clip;
    return ResolvedClip(
      source: ClipSource(uri: pick.uri, origin: clip.source.origin, preloadable: clip.source.preloadable),
      assetId: pick.assetId,
      kind: clip.kind,
      number: clip.number,
      serverId: clip.serverId,
      height: pick.height,
      candidates: clip.candidates,
    );
  }

  ResolvedClip? _plex(String serverId, String partKey, String asset, ClipKind kind) {
    final url = servers.clipUrl(serverId, partKey);
    if (url == null) return null;
    return ResolvedClip(
      source: ClipSource(uri: url, origin: ClipOrigin.plexExtra, preloadable: !_slowServers.contains(serverId)),
      assetId: asset,
      kind: kind,
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

  /// Runs [request] after every earlier request in [lane] has settled.
  Future<T> _inLane<T>(String lane, Future<T> Function() request) {
    final before = _lanes[lane] ?? Future<void>.value();
    final run = before.then((_) => request());
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _lanes[lane] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_lanes[lane], tail)) _lanes.remove(lane);
      }),
    );
    return run;
  }

  /// The AnimeThemes lane's key (Plex machine ids are alphanumeric).
  static const String _animeThemesLane = ':animethemes';

  Future<_Run> _ladder(ReelTitle t, Set<String> banned) async {
    var sure = true;
    final offline = <String>{};
    if (t.anime && t.isShow) {
      final (ops, opSure) = await _openings(t);
      sure &= opSure;
      final candidates = [for (final op in ops) ClipCandidate.opening(op)];
      // A banned file bans the opening: its other files are the same clip.
      final clip = candidates.any((c) => banned.contains(c.assetId)) ? null : _opening1(1, candidates);
      if (clip != null) {
        return _Run((clip, _openingRow(clip, candidates)), sure: sure, offline: offline);
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
        extras = await _inLane(c.serverId, () => servers.extras(c.serverId, c.ratingKey, timeout: firstTry));
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
      final clip = _plex(c.serverId, pick.partKey, 'plex:${pick.ratingKey}', ClipKind.ofExtraTitle(pick.title));
      if (clip == null) {
        // The server dropped between the read and the URL.
        sure = false;
        offline.add(c.serverId);
        continue;
      }
      return _Run(
        (
          clip,
          {'v': sourceFormat, 'k': 'plex', 'sv': c.serverId, 'pk': pick.partKey, 'a': clip.assetId, ..._kindRow(clip)},
        ),
        sure: sure,
        offline: offline,
      );
    }
    // TMDB last, and only once every rung before it said no for sure: a
    // server that couldn't answer may still hold the title's own trailer.
    if (!sure) return _Run(null, sure: sure, offline: offline);
    final (tm, hit) = await _tmdbRung(t, banned);
    return _Run(hit, sure: sure, offline: offline, tmdb: tm);
  }

  /// Every file of AnimeThemes OP1 for [t], and whether the answer is
  /// sure: no mapping or no record is sure, a failed lookup (429, 5xx, the
  /// local cap, a changed response) is not. A deck's batch ([warm]) in
  /// flight for [t] is waited for, and its answer used.
  Future<(List<AnimeOpening>, bool)> _openings(ReelTitle t) async {
    try {
      if (_warming[t.groupKey] case final batch?) await batch;
      final id = await aniList(t);
      if (id == null) return (const <AnimeOpening>[], true);
      if (_openingsById[id] case final known?) return (known, true);
      final anime = (await _inLane(_animeThemesLane, () => _animeThemes([id])))[id];
      final ops = anime == null ? const <AnimeOpening>[] : ClipFilter.openings(anime);
      _openingsById[id] = ops;
      return (ops, true);
    } catch (e) {
      appLogger.d('Reel: AnimeThemes lookup failed', error: e);
      return (const <AnimeOpening>[], false);
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
                    'videos': [for (final v in _nodes(e['videos'])) _video(v)],
                  },
              ],
            },
      ],
    };
  }

  /// One video as queried. An `overlap` this build can't read throws: the
  /// opening filter drops such a file, and a schema change must leave the
  /// title unknown, never a 30-day miss.
  static Map<String, dynamic> _video(Map v) {
    if (ClipFilter.overlapOf(v['overlap']) == null) throw const AnimeThemesUnavailable('unknown overlap');
    return Map<String, dynamic>.from(v);
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
