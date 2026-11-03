import 'dart:convert';
import 'dart:io';

import '../trackers/trakt/trakt_constants.dart';
import '../../utils/app_logger.dart';
import '../history/history_models.dart';
import '../trackers/tracker_exceptions.dart';
import '../trackers/trakt/trakt_client.dart';
import 'history_profiles.dart';

/// Fork: Trakt's details for watched titles that aren't on the servers
/// (the library index has everything else), fetched once and kept in a
/// JSON file. Read-only on Trakt, one request at a time, at most one a
/// second, backing off when Trakt says to slow down.
class TraktDetailsCache {
  TraktDetailsCache(this._file, {this.gap = const Duration(milliseconds: 1100)});

  final File _file;
  final Duration gap;
  Map<String, Object?> _entries = {};
  bool _loaded = false;
  int requests = 0;

  /// A title Trakt didn't know is asked about again after this long.
  static const Duration missingRetry = Duration(days: 30);
  static const int _maxBusy = 3;

  Future<Map<String, TraktDetails>> load() async {
    await _read();
    return {
      for (final e in _entries.entries)
        if (e.value case final Map<String, Object?> j when j['missing'] != true) e.key: TraktDetails.fromJson(j),
    };
  }

  /// Fetch what's missing for [titles] (id → one watch of it). Stops early
  /// on repeated rate limits or [cancelled]; what it got is saved.
  Future<int> fill(TraktClient client, Map<String, HistoryPlay> titles, {bool Function()? cancelled}) async {
    await _read();
    final now = DateTime.now().millisecondsSinceEpoch;
    final todo = [
      for (final e in titles.entries)
        if (switch (_entries[e.key]) {
          null => true,
          {'missing': true, 'at': final int at} => now - at > missingRetry.inMilliseconds,
          _ => false,
        })
          e,
    ];
    var fetched = 0, busy = 0;
    for (final MapEntry(key: id, value: play) in todo) {
      if (cancelled?.call() ?? false) break;
      final traktId = play.traktId?.toString() ?? play.imdb;
      if (traktId == null) continue;
      final type = play.isMovie ? TraktCatalogType.movies : TraktCatalogType.shows;
      try {
        final summary = await _call(() => client.getSummary(type, traktId));
        if (summary == null) {
          _entries[id] = {'missing': true, 'at': now};
          continue;
        }
        var directors = const <String>[], cast = const <String>[];
        if (play.isMovie) {
          // Shows' people include every guest star; their summary is enough.
          final people = await _call(() => client.getPeople(type, traktId));
          directors = [
            for (final c in people.crew)
              if ((c.job ?? c.jobs?.firstOrNull) == 'Director' && c.person?.name != null) c.person!.name!,
          ];
          cast = [
            for (final c in people.cast.take(8))
              if (c.person?.name != null) c.person!.name!,
          ];
        }
        _entries[id] = detailsFromTrakt(summary, directors: directors, cast: cast).toJson();
        fetched++;
        busy = 0;
      } on TrackerRateLimitException catch (e) {
        if (++busy >= _maxBusy) {
          appLogger.w('Brain: Trakt kept rate limiting; stopping details for now');
          break;
        }
        await Future<void>.delayed(Duration(seconds: (e.retryAfterSeconds ?? 10).clamp(1, 120) * busy));
      } catch (e) {
        appLogger.d('Brain: Trakt details failed for one title', error: e);
      }
    }
    if (todo.isNotEmpty) await _write();
    return fetched;
  }

  Future<T> _call<T>(Future<T> Function() call) async {
    if (requests++ > 0) await Future<void>.delayed(gap);
    return call();
  }

  Future<void> _read() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (await _file.exists()) _entries = (jsonDecode(await _file.readAsString()) as Map).cast<String, Object?>();
    } catch (e) {
      appLogger.d('Brain: Trakt details cache unreadable, starting fresh', error: e);
    }
  }

  Future<void> _write() async {
    try {
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(_entries));
      await tmp.rename(_file.path);
    } catch (e) {
      appLogger.d('Brain: Trakt details cache not written', error: e);
    }
  }
}

/// [TraktDetails] from Trakt's `extended=full` summary.
TraktDetails detailsFromTrakt(
  Map<String, dynamic> m, {
  List<String> directors = const [],
  List<String> cast = const [],
}) {
  String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  return TraktDetails(
    summary: str(m['overview']),
    tagline: str(m['tagline']),
    genres: [
      for (final g in (m['genres'] as List? ?? const []))
        '$g'.split('-').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' '),
    ],
    runtime: (m['runtime'] as num?)?.toInt(),
    rating: (m['rating'] as num?)?.toDouble(),
    certification: str(m['certification']),
    country: str(m['country'])?.toUpperCase(),
    airedEpisodes: (m['aired_episodes'] as num?)?.toInt(),
    directors: directors,
    cast: cast,
  );
}
