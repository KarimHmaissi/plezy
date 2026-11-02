import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/trakt/trakt_images.dart';
import '../../utils/app_logger.dart';
import '../library_index/library_index.dart' show IndexSource;
import '../trackers/trakt/trakt_client.dart';
import 'history_models.dart';

/// Fork: what the History page shows.
@immutable
class HistoryState {
  const HistoryState({this.history, this.loading = false, this.error, this.hasTrakt = false, this.updatedAt});

  final MergedHistory? history;
  final bool loading;
  final String? error;

  /// Whether Trakt was part of the last refresh.
  final bool hasTrakt;
  final DateTime? updatedAt;

  HistoryState copyWith({MergedHistory? history, bool? loading, String? error, bool? hasTrakt, DateTime? updatedAt}) =>
      HistoryState(
        history: history ?? this.history,
        loading: loading ?? this.loading,
        error: error,
        hasTrakt: hasTrakt ?? this.hasTrakt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// Fork: watch history from Plex (each title's last-viewed date, per film
/// and per episode) and Trakt (every logged watch), cached on the device and
/// refreshed in the background. Read-only on both.
class HistoryService {
  HistoryService({Future<File> Function()? cacheFile, this.requestGap = const Duration(milliseconds: 250)})
    : _cacheFile = cacheFile ?? _defaultCacheFile;

  static final HistoryService instance = HistoryService();

  final Future<File> Function() _cacheFile;

  /// Pause between Plex pages, to stay gentle on shared servers.
  final Duration requestGap;

  final ValueNotifier<HistoryState> state = ValueNotifier(const HistoryState());

  static const Duration traktStaleAfter = Duration(minutes: 15);
  static const Duration traktFullEvery = Duration(days: 7);
  static const Duration plexStaleAfter = Duration(hours: 6);
  static const int _plexPageSize = 500;
  static const int _maxPlexPages = 40;

  List<HistoryPlay> _trakt = [];
  List<HistoryPlay> _plex = [];
  DateTime? _traktSyncedAt;
  DateTime? _traktFullAt;
  DateTime? _plexSyncedAt;
  bool _cacheLoaded = false;
  Future<void>? _running;

  static Future<File> _defaultCacheFile() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'history_cache.json'));

  /// Show the cached history, then refresh what's stale ([force]: all).
  Future<void> load({required List<IndexSource> Function() plex, TraktClient? trakt, bool force = false}) {
    return _running ??= _load(plex, trakt, force).whenComplete(() => _running = null);
  }

  Future<void> _load(List<IndexSource> Function() plexSources, TraktClient? trakt, bool force) async {
    if (!_cacheLoaded) {
      _cacheLoaded = true;
      await _readCache();
      if (_trakt.isNotEmpty || _plex.isNotEmpty) _publish(hasTrakt: trakt != null);
    }
    final now = DateTime.now();
    final traktDue =
        trakt != null && (force || _traktSyncedAt == null || now.difference(_traktSyncedAt!) > traktStaleAfter);
    final plexDue = force || _plexSyncedAt == null || now.difference(_plexSyncedAt!) > plexStaleAfter;
    if (!traktDue && !plexDue) {
      _publish(hasTrakt: trakt != null);
      return;
    }
    state.value = state.value.copyWith(loading: true);
    String? error;
    if (traktDue) {
      try {
        await _refreshTrakt(
          trakt,
          full: force || _traktFullAt == null || now.difference(_traktFullAt!) > traktFullEvery,
        );
      } catch (e) {
        appLogger.w('History: Trakt refresh failed', error: e);
        error = 'trakt';
      }
    }
    if (plexDue) {
      try {
        final sources = plexSources();
        if (sources.isNotEmpty) await _refreshPlex(sources);
      } catch (e) {
        appLogger.w('History: Plex refresh failed', error: e);
        error ??= 'plex';
      }
    }
    await _writeCache();
    _publish(hasTrakt: trakt != null, error: error);
  }

  void _publish({required bool hasTrakt, String? error}) {
    final merged = mergeHistory(
      trakt: [for (final p in _trakt) HistoryPlay.fromJson(p.toJson())],
      plex: [for (final p in _plex) HistoryPlay.fromJson(p.toJson())],
    );
    state.value = HistoryState(
      history: merged,
      hasTrakt: hasTrakt,
      error: error,
      updatedAt: _plexSyncedAt ?? _traktSyncedAt,
    );
  }

  // ── Trakt ──

  Future<void> _refreshTrakt(TraktClient client, {required bool full}) async {
    final newest = _trakt.isEmpty ? null : _trakt.map((p) => p.watchedAt).reduce((a, b) => a.isAfter(b) ? a : b);
    final since = full || newest == null ? null : newest.subtract(const Duration(days: 2));
    final fetched = <HistoryPlay>[];
    // Movies carry their own poster; episodes take the show's from the
    // watched-shows list.
    fetched.addAll(await _traktPages(client, 'movies', since, extended: 'full,images'));
    fetched.addAll(await _traktPages(client, 'episodes', since, extended: 'full'));
    if (full || fetched.any((p) => !p.isMovie)) {
      final posters = <int, String>{};
      for (final w in await client.getWatchedShows()) {
        final show = w['show'];
        if (show is! Map<String, dynamic>) continue;
        final id = (show['ids'] as Map?)?['trakt'];
        final images = show['images'];
        final url = images is Map<String, dynamic> ? TraktImages.fromJson(images).primaryPoster : null;
        if (id is int && url != null) posters[id] = url;
      }
      for (final p in [...fetched, ..._trakt]) {
        if (!p.isMovie && p.traktId != null) p.posterUrl ??= posters[p.traktId];
      }
    }
    if (full) {
      _trakt = fetched;
      _traktFullAt = DateTime.now();
    } else {
      final seen = {for (final p in _trakt) p.traktHistoryId};
      _trakt = [..._trakt, ...fetched.where((p) => !seen.contains(p.traktHistoryId))];
    }
    _traktSyncedAt = DateTime.now();
    appLogger.d('History: Trakt ${full ? 'full' : 'update'}: ${fetched.length} watches, ${_trakt.length} cached');
  }

  Future<List<HistoryPlay>> _traktPages(
    TraktClient client,
    String type,
    DateTime? since, {
    required String extended,
  }) async {
    final out = <HistoryPlay>[];
    for (var page = 1; page <= 50; page++) {
      final res = await client.getHistory(type, page: page, startAt: since, extended: extended);
      for (final raw in res.items) {
        final play = traktPlayFromJson(raw);
        if (play != null) out.add(play);
      }
      if (!res.hasMore) break;
    }
    return out;
  }

  // ── Plex ──

  Future<void> _refreshPlex(List<IndexSource> sources) async {
    final plays = <HistoryPlay>[];
    var requests = 0;
    Future<T> gentle<T>(Future<T> Function() call) async {
      if (requests++ > 0) await Future<void>.delayed(requestGap);
      return call();
    }

    for (final source in sources) {
      final List<Map<String, dynamic>> sections;
      try {
        sections = await gentle(source.sections);
      } catch (e) {
        appLogger.d('History: Plex sections unavailable', error: e);
        continue;
      }
      for (final section in sections) {
        final key = '${section['key'] ?? ''}';
        final type = section['type'];
        if (key.isEmpty) continue;
        Future<List<Map<String, dynamic>>> watched(int plexType) async {
          final items = <Map<String, dynamic>>[];
          for (var i = 0; i < _maxPlexPages; i++) {
            final res = await gentle(
              () => source.page(
                key,
                plexType: plexType,
                start: i * _plexPageSize,
                size: _plexPageSize,
                filters: const {'lastViewedAt>>': '1', 'sort': 'lastViewedAt:desc'},
              ),
            );
            items.addAll(res.items);
            if (res.items.length < _plexPageSize || items.length >= res.total) break;
          }
          return items;
        }

        try {
          if (type == 'movie') {
            for (final m in await watched(1)) {
              final play = plexMoviePlay(m, serverId: source.serverId);
              if (play != null) plays.add(play);
            }
          } else if (type == 'show') {
            final shows = {for (final s in await watched(2)) '${s['ratingKey']}': s};
            for (final e in await watched(4)) {
              final play = plexEpisodePlay(e, show: shows['${e['grandparentRatingKey']}'], serverId: source.serverId);
              if (play != null) plays.add(play);
            }
          }
        } catch (e) {
          appLogger.d('History: a Plex library failed', error: e);
        }
      }
    }
    // The same title on two servers or in a 4K copy: keep one watch.
    final byWatch = <String, HistoryPlay>{};
    for (final p in plays) {
      final key = '${p.watchKey}@${p.watchedAt.millisecondsSinceEpoch ~/ 3600000}';
      byWatch.putIfAbsent(key, () => p);
    }
    _plex = byWatch.values.toList();
    _plexSyncedAt = DateTime.now();
    appLogger.d('History: Plex: ${_plex.length} watches from $requests requests');
  }

  // ── Cache ──

  Future<void> _readCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return;
      final j = json.decode(await file.readAsString()) as Map<String, dynamic>;
      if (j['v'] != 2) return;
      List<HistoryPlay> plays(Object? v) => [
        if (v is List)
          for (final e in v.whereType<Map<String, dynamic>>()) HistoryPlay.fromJson(e),
      ];
      DateTime? at(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
      _trakt = plays(j['trakt']);
      _plex = plays(j['plex']);
      _traktSyncedAt = at(j['traktAt']);
      _traktFullAt = at(j['traktFullAt']);
      _plexSyncedAt = at(j['plexAt']);
    } catch (e) {
      appLogger.d('History: cache unreadable, starting fresh', error: e);
    }
  }

  Future<void> _writeCache() async {
    try {
      final file = await _cacheFile();
      await file.writeAsString(
        json.encode({
          'v': 2,
          'trakt': [for (final p in _trakt) p.toJson()],
          'plex': [for (final p in _plex) p.toJson()],
          'traktAt': _traktSyncedAt?.millisecondsSinceEpoch,
          'traktFullAt': _traktFullAt?.millisecondsSinceEpoch,
          'plexAt': _plexSyncedAt?.millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      appLogger.d('History: cache not written', error: e);
    }
  }
}

// ── Parsing (public for tests) ──

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));

List<String> _tags(Object? list, {int? limit}) {
  if (list is! List) return const [];
  final names = [
    for (final t in list)
      if (t is Map && t['tag'] is String) t['tag'] as String,
  ];
  return limit == null ? names : names.take(limit).toList();
}

String? _guid(Map<String, dynamic> m, String scheme) {
  final guids = m['Guid'];
  if (guids is! List) return null;
  for (final g in guids) {
    final id = g is Map ? g['id'] : null;
    if (id is String && id.startsWith('$scheme://')) return id.substring(scheme.length + 3);
  }
  return null;
}

DateTime? _plexDate(Object? v) {
  final s = _int(v);
  return s == null || s <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
}

int? _plexMinutes(Object? ms) {
  final v = _int(ms);
  return v == null ? null : (v / 60000).round();
}

@visibleForTesting
HistoryPlay? plexMoviePlay(Map<String, dynamic> m, {required String serverId}) {
  final at = _plexDate(m['lastViewedAt']);
  if (at == null) return null;
  return HistoryPlay(
    kind: HistoryKind.movie,
    watchedAt: at,
    title: _str(m['title']) ?? '',
    year: _int(m['year']),
    runtimeMinutes: _plexMinutes(m['duration']),
    imdb: _guid(m, 'imdb'),
    tmdb: _guid(m, 'tmdb'),
    genres: _tags(m['Genre']),
    directors: _tags(m['Director']),
    cast: _tags(m['Role'], limit: 8),
    sources: {HistorySource.plex},
    plexServerId: serverId,
    plexRatingKey: _str(m['ratingKey']),
    plexThumb: _str(m['thumb']),
  );
}

@visibleForTesting
HistoryPlay? plexEpisodePlay(Map<String, dynamic> e, {Map<String, dynamic>? show, required String serverId}) {
  final at = _plexDate(e['lastViewedAt']);
  if (at == null) return null;
  return HistoryPlay(
    kind: HistoryKind.episode,
    watchedAt: at,
    title: _str(e['grandparentTitle']) ?? _str(show?['title']) ?? '',
    episodeTitle: _str(e['title']),
    season: _int(e['parentIndex']),
    episode: _int(e['index']),
    year: _int(show?['year']),
    runtimeMinutes: _plexMinutes(e['duration']),
    imdb: show == null ? null : _guid(show, 'imdb'),
    tmdb: show == null ? null : _guid(show, 'tmdb'),
    tvdb: show == null ? null : _guid(show, 'tvdb'),
    genres: show == null ? const [] : _tags(show['Genre']),
    cast: show == null ? const [] : _tags(show['Role'], limit: 8),
    sources: {HistorySource.plex},
    plexServerId: serverId,
    plexRatingKey: _str(e['grandparentRatingKey']),
    plexThumb: _str(e['grandparentThumb']) ?? _str(show?['thumb']),
  );
}

@visibleForTesting
HistoryPlay? traktPlayFromJson(Map<String, dynamic> raw) {
  final at = DateTime.tryParse('${raw['watched_at'] ?? ''}')?.toUtc();
  if (at == null) return null;
  final type = raw['type'];
  if (type == 'movie') {
    final m = raw['movie'];
    if (m is! Map<String, dynamic>) return null;
    final ids = m['ids'] as Map? ?? const {};
    final images = m['images'];
    return HistoryPlay(
      kind: HistoryKind.movie,
      watchedAt: at,
      title: _str(m['title']) ?? '',
      year: _int(m['year']),
      runtimeMinutes: _int(m['runtime']),
      imdb: _str(ids['imdb']),
      tmdb: _str(ids['tmdb']),
      traktId: _int(ids['trakt']),
      traktHistoryId: _int(raw['id']),
      genres: [for (final g in (m['genres'] as List? ?? const [])) _titleCase('$g')],
      sources: {HistorySource.trakt},
      posterUrl: images is Map<String, dynamic> ? TraktImages.fromJson(images).primaryPoster : null,
      datedAtRelease: _sameDay(at, m['released']),
    );
  }
  if (type == 'episode') {
    final ep = raw['episode'];
    final show = raw['show'];
    if (ep is! Map<String, dynamic> || show is! Map<String, dynamic>) return null;
    final ids = show['ids'] as Map? ?? const {};
    return HistoryPlay(
      kind: HistoryKind.episode,
      watchedAt: at,
      title: _str(show['title']) ?? '',
      episodeTitle: _str(ep['title']),
      season: _int(ep['season']),
      episode: _int(ep['number']),
      year: _int(show['year']),
      runtimeMinutes: _int(ep['runtime']) ?? _int(show['runtime']),
      imdb: _str(ids['imdb']),
      tmdb: _str(ids['tmdb']),
      tvdb: _str(ids['tvdb']),
      traktId: _int(ids['trakt']),
      traktHistoryId: _int(raw['id']),
      genres: [for (final g in (show['genres'] as List? ?? const [])) _titleCase('$g')],
      sources: {HistorySource.trakt},
      datedAtRelease: _sameDay(at, ep['first_aired']),
    );
  }
  return null;
}

/// Whether [at] falls on [release]'s day (a date or a timestamp), give or
/// take the time zone.
bool _sameDay(DateTime at, Object? release) {
  final day = DateTime.tryParse('${release ?? ''}');
  if (day == null) return false;
  return at.difference(DateTime.utc(day.year, day.month, day.day)).inHours.abs() <= 36 &&
      (day.isUtc ? at.difference(day).inHours.abs() <= 36 : true);
}

/// Trakt genres are slugs (`science-fiction`); Plex's are names.
String _titleCase(String slug) =>
    slug.split('-').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
