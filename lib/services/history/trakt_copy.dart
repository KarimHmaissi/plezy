import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';
import '../trackers/tracker_exceptions.dart';
import '../trackers/trakt/trakt_client.dart';
import 'history_models.dart';

/// Fork: what "Send Plex watches to Trakt" would do, worked out from the
/// merged history before anything is written.
class TraktCopyPlan {
  TraktCopyPlan._({required this.toSend, required this.alreadyOnTrakt, required this.noIds, required this.bulkDates});

  /// Plex watches with a real date that Trakt doesn't have, newest first.
  final List<HistoryPlay> toSend;

  /// Plex watches Trakt already has (same item, close date or an import).
  final int alreadyOnTrakt;

  /// Plex watches that can't be matched on Trakt (no IMDb/TMDB/TVDB id, or
  /// an episode without its season/number).
  final int noIds;

  /// Plex watches whose date is a mark-all-watched, not a viewing.
  final int bulkDates;

  int get films => toSend.where((p) => p.isMovie).length;
  int get episodes => toSend.length - films;

  /// Year → (films, episodes) to send, newest year first.
  Map<int, ({int films, int episodes})> get byYear {
    final out = <int, ({int films, int episodes})>{};
    for (final p in toSend) {
      final y = p.watchedAt.toLocal().year;
      final c = out[y] ?? (films: 0, episodes: 0);
      out[y] = p.isMovie ? (films: c.films + 1, episodes: c.episodes) : (films: c.films, episodes: c.episodes + 1);
    }
    return Map.fromEntries(out.entries.toList()..sort((a, b) => b.key.compareTo(a.key)));
  }
}

bool _hasTraktIds(HistoryPlay p) =>
    (p.imdb?.isNotEmpty ?? false) ||
    int.tryParse(p.tmdb ?? '') != null ||
    (!p.isMovie && int.tryParse(p.tvdb ?? '') != null) ||
    p.traktId != null;

/// Plex watches to add to Trakt: only real dates, only what Trakt lacks,
/// only what Trakt can identify. Bulk "mark watched" dates are skipped
/// rather than sent, so the Trakt timeline gets no made-up dates.
TraktCopyPlan planTraktCopy(MergedHistory history) {
  final toSend = <HistoryPlay>[];
  var already = 0, noIds = 0, bulk = 0;
  for (final p in history.plays) {
    if (!p.sources.contains(HistorySource.plex)) continue;
    if (p.sources.contains(HistorySource.trakt)) {
      already++;
    } else if (p.bulk) {
      bulk++;
    } else if (!_hasTraktIds(p) || (!p.isMovie && (p.season == null || p.episode == null))) {
      noIds++;
    } else {
      toSend.add(p);
    }
  }
  return TraktCopyPlan._(toSend: toSend, alreadyOnTrakt: already, noIds: noIds, bulkDates: bulk);
}

/// Trakt keeps `watched_at` to the minute; sending it that way makes a
/// resend land on the same entry (Trakt deduplicates item + watched_at).
String traktWatchedAt(DateTime at) {
  final u = at.toUtc();
  return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute).toIso8601String();
}

Map<String, dynamic> _ids(HistoryPlay p) => {
  if (p.traktId != null) 'trakt': p.traktId,
  if (p.imdb?.isNotEmpty ?? false) 'imdb': p.imdb,
  'tmdb': ?int.tryParse(p.tmdb ?? ''),
  if (!p.isMovie) 'tvdb': ?int.tryParse(p.tvdb ?? ''),
};

/// `POST /sync/history` bodies of at most [batchSize] watches each.
List<Map<String, dynamic>> traktHistoryBatches(List<HistoryPlay> plays, {int batchSize = 100}) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < plays.length; i += batchSize) {
    final chunk = plays.sublist(i, i + batchSize > plays.length ? plays.length : i + batchSize);
    final movies = [
      for (final p in chunk)
        if (p.isMovie) {'ids': _ids(p), 'watched_at': traktWatchedAt(p.watchedAt)},
    ];
    final shows = <String, ({Map<String, dynamic> ids, Map<int, List<Map<String, dynamic>>> seasons})>{};
    for (final p in chunk) {
      if (p.isMovie) continue;
      final show = shows.putIfAbsent(p.titleKey, () => (ids: _ids(p), seasons: {}));
      (show.seasons[p.season!] ??= []).add({'number': p.episode, 'watched_at': traktWatchedAt(p.watchedAt)});
    }
    out.add({
      if (movies.isNotEmpty) 'movies': movies,
      if (shows.isNotEmpty)
        'shows': [
          for (final s in shows.values)
            {
              'ids': s.ids,
              'seasons': [
                for (final e in s.seasons.entries) {'number': e.key, 'episodes': e.value},
              ],
            },
        ],
    });
  }
  return out;
}

/// The Trakt calls the copy needs (a seam for tests).
abstract interface class TraktHistoryWriter {
  Future<Map<String, dynamic>> add(Map<String, dynamic> body);
  Future<Map<String, dynamic>> removeIds(List<int> ids);

  /// Every history entry since [startAt]: its id and when.
  Future<List<({int id, DateTime watchedAt})>> entriesSince(DateTime startAt);
}

class TraktClientHistoryWriter implements TraktHistoryWriter {
  TraktClientHistoryWriter(this._client);
  final TraktClient _client;

  @override
  Future<Map<String, dynamic>> add(Map<String, dynamic> body) => _client.addToHistoryCounted(body);

  @override
  Future<Map<String, dynamic>> removeIds(List<int> ids) => _client.removeHistoryIds(ids);

  @override
  Future<List<({int id, DateTime watchedAt})>> entriesSince(DateTime startAt) async {
    final out = <({int id, DateTime watchedAt})>[];
    for (final type in const ['movies', 'episodes']) {
      for (var page = 1; page <= 100; page++) {
        final res = await _client.getHistory(type, page: page, startAt: startAt, extended: 'min');
        for (final e in res.items) {
          final id = e['id'];
          final at = DateTime.tryParse('${e['watched_at'] ?? ''}');
          if (id is int && at != null) out.add((id: id, watchedAt: at.toUtc()));
        }
        if (!res.hasMore) break;
      }
    }
    return out;
  }
}

/// What one send added, kept so it can be undone.
class TraktSendRecord {
  const TraktSendRecord({
    required this.sentAt,
    required this.films,
    required this.episodes,
    required this.notFound,
    required this.historyIds,
  });

  final DateTime sentAt;
  final int films;
  final int episodes;
  final int notFound;

  /// The Trakt history entries this send created.
  final List<int> historyIds;

  Map<String, dynamic> toJson() => {
    'sentAt': sentAt.millisecondsSinceEpoch,
    'films': films,
    'episodes': episodes,
    'notFound': notFound,
    'ids': historyIds,
  };

  static TraktSendRecord fromJson(Map<String, dynamic> j) => TraktSendRecord(
    sentAt: DateTime.fromMillisecondsSinceEpoch(j['sentAt'] as int),
    films: j['films'] as int? ?? 0,
    episodes: j['episodes'] as int? ?? 0,
    notFound: j['notFound'] as int? ?? 0,
    historyIds: [for (final id in (j['ids'] as List? ?? const [])) id as int],
  );
}

/// Fork: sends a [TraktCopyPlan] to Trakt politely (one write at a time,
/// [writeGap] apart, waiting out rate limits) and can undo the last send by
/// removing exactly the history entries it created.
class TraktCopier {
  TraktCopier(
    this._writer, {
    Future<File> Function()? recordFile,
    this.writeGap = const Duration(milliseconds: 1100),
    Future<void> Function(Duration)? sleep,
  }) : _recordFile = recordFile ?? _defaultRecordFile,
       _sleep = sleep ?? Future<void>.delayed;

  final TraktHistoryWriter _writer;
  final Future<File> Function() _recordFile;
  final Duration writeGap;
  final Future<void> Function(Duration) _sleep;

  static const int _maxRetries = 5;

  static Future<File> _defaultRecordFile() async =>
      File(p.join((await getApplicationSupportDirectory()).path, 'trakt_history_send.json'));

  Future<T> _write<T>(Future<T> Function() call) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await call();
      } on TrackerRateLimitException catch (e) {
        if (attempt >= _maxRetries) rethrow;
        final wait = Duration(seconds: (e.retryAfterSeconds ?? 10).clamp(1, 120));
        appLogger.d('History copy: Trakt rate limit, waiting ${wait.inSeconds}s');
        await _sleep(wait);
      }
    }
  }

  Future<TraktSendRecord> send(TraktCopyPlan plan, {void Function(int done, int total)? onProgress}) async {
    final batches = traktHistoryBatches(plan.toSend);
    final earliest = plan.toSend.map((p) => p.watchedAt).reduce((a, b) => a.isBefore(b) ? a : b);
    final since = earliest.subtract(const Duration(days: 1));
    final before = {for (final e in await _writer.entriesSince(since)) e.id};

    var films = 0, episodes = 0, notFound = 0;
    for (final (i, body) in batches.indexed) {
      if (i > 0) await _sleep(writeGap);
      final res = await _write(() => _writer.add(body));
      final added = res['added'];
      if (added is Map) {
        films += (added['movies'] as num?)?.toInt() ?? 0;
        episodes += (added['episodes'] as num?)?.toInt() ?? 0;
      }
      final missing = res['not_found'];
      if (missing is Map) {
        for (final list in missing.values) {
          if (list is List) notFound += list.length;
        }
      }
      onProgress?.call(i + 1, batches.length);
    }

    // The entries this send created: new since the snapshot, at one of the
    // minutes it sent.
    final sentMinutes = {for (final p in plan.toSend) traktWatchedAt(p.watchedAt)};
    await _sleep(writeGap);
    final created = [
      for (final e in await _writer.entriesSince(since))
        if (!before.contains(e.id) && sentMinutes.contains(traktWatchedAt(e.watchedAt))) e.id,
    ];
    final record = TraktSendRecord(
      sentAt: DateTime.now(),
      films: films,
      episodes: episodes,
      notFound: notFound,
      historyIds: created,
    );
    await (await _recordFile()).writeAsString(json.encode(record.toJson()));
    appLogger.d('History copy: sent $films films, $episodes episodes; ${created.length} entries recorded');
    return record;
  }

  Future<TraktSendRecord?> lastSend() async {
    try {
      final file = await _recordFile();
      if (!await file.exists()) return null;
      return TraktSendRecord.fromJson(json.decode(await file.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      appLogger.d('History copy: send record unreadable', error: e);
      return null;
    }
  }

  /// Remove exactly what the last send added. Returns how many entries.
  Future<int> undoLastSend() async {
    final record = await lastSend();
    if (record == null) return 0;
    var removed = 0;
    for (var i = 0; i < record.historyIds.length; i += 500) {
      if (i > 0) await _sleep(writeGap);
      final ids = record.historyIds.sublist(i, i + 500 > record.historyIds.length ? record.historyIds.length : i + 500);
      final res = await _write(() => _writer.removeIds(ids));
      final deleted = res['deleted'];
      if (deleted is Map) {
        removed += ((deleted['movies'] as num?)?.toInt() ?? 0) + ((deleted['episodes'] as num?)?.toInt() ?? 0);
      }
    }
    await (await _recordFile()).delete();
    return removed;
  }
}
