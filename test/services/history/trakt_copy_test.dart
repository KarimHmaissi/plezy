import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/history/history_models.dart';
import 'package:plezy/services/history/trakt_copy.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_exceptions.dart';

HistoryPlay _plexMovie(String at, {String? imdb = 'tt1', Set<HistorySource>? sources}) => HistoryPlay(
  kind: HistoryKind.movie,
  watchedAt: DateTime.parse(at),
  title: 'Film',
  imdb: imdb,
  sources: sources ?? {HistorySource.plex},
);

HistoryPlay _plexEpisode(String at, {int episode = 1, String? tvdb = '77'}) => HistoryPlay(
  kind: HistoryKind.episode,
  watchedAt: DateTime.parse(at),
  title: 'Show A',
  tvdb: tvdb,
  season: 1,
  episode: episode,
  sources: {HistorySource.plex},
);

void main() {
  group('planTraktCopy', () {
    test('sends only dated Plex-only watches Trakt can identify, and says why the rest are skipped', () {
      final bulk = _plexMovie('2023-01-01T09:00:00Z', imdb: 'tt9')..bulk = true;
      final plan = planTraktCopy(
        MergedHistory(
          plays: [
            _plexMovie('2025-05-01T20:00:00Z'),
            _plexEpisode('2025-05-02T20:00:00Z'),
            _plexMovie('2025-05-03T20:00:00Z', sources: {HistorySource.plex, HistorySource.trakt}),
            _plexMovie('2025-05-04T20:00:00Z', sources: {HistorySource.trakt}),
            _plexMovie('2025-05-05T20:00:00Z', imdb: null),
            bulk,
          ],
          undated: 0,
          matched: 0,
        ),
      );
      expect(plan.films, 1);
      expect(plan.episodes, 1);
      expect(plan.alreadyOnTrakt, 1);
      expect(plan.noIds, 1);
      expect(plan.bulkDates, 1);
      expect(plan.byYear, {2025: (films: 1, episodes: 1)});
    });
  });

  test('batches group episodes under their show and season, with minute-precision dates', () {
    final batches = traktHistoryBatches([
      _plexMovie('2025-05-01T20:00:42.5Z'),
      _plexEpisode('2025-05-02T20:00:00Z', episode: 1),
      _plexEpisode('2025-05-02T21:00:00Z', episode: 2),
    ], batchSize: 100);
    expect(batches, hasLength(1));
    expect(batches.single['movies'], [
      {
        'ids': {'imdb': 'tt1'},
        'watched_at': '2025-05-01T20:00:00.000Z',
      },
    ]);
    final show = (batches.single['shows'] as List).single as Map;
    expect(show['ids'], {'tvdb': 77});
    final season = (show['seasons'] as List).single as Map;
    expect(season['number'], 1);
    expect((season['episodes'] as List).map((e) => (e as Map)['number']), [1, 2]);
    expect(
      traktHistoryBatches(List.generate(250, (i) => _plexMovie('2025-01-01T00:00:00Z')), batchSize: 100),
      hasLength(3),
    );
  });

  group('TraktCopier', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('trakt_copy'));
    tearDown(() => dir.delete(recursive: true));

    test('sends in paced batches, waits out a rate limit, records the entries it made, and undoes them', () async {
      final writer = _FakeWriter(rateLimitOnce: true);
      final sleeps = <Duration>[];
      final copier = TraktCopier(
        writer,
        recordFile: () async => File('${dir.path}/send.json'),
        sleep: (d) async => sleeps.add(d),
      );
      final plan = planTraktCopy(
        MergedHistory(
          plays: [_plexMovie('2025-05-01T20:00:00Z'), _plexEpisode('2025-05-02T20:00:00Z')],
          undated: 0,
          matched: 0,
        ),
      );

      final record = await copier.send(plan);

      expect(writer.bodies, hasLength(1));
      expect(sleeps, contains(const Duration(seconds: 3)));
      expect(record.films, 1);
      expect(record.episodes, 1);
      // The pre-existing entry (id 1) isn't claimed as ours.
      expect(record.historyIds, unorderedEquals([100, 101]));
      expect((await copier.lastSend())?.historyIds, unorderedEquals([100, 101]));

      expect(await copier.undoLastSend(), 2);
      expect(writer.removed, unorderedEquals([100, 101]));
      expect(await copier.lastSend(), isNull);
    });
  });
}

class _FakeWriter implements TraktHistoryWriter {
  _FakeWriter({this.rateLimitOnce = false});

  bool rateLimitOnce;
  final bodies = <Map<String, dynamic>>[];
  final removed = <int>[];
  final entries = <({int id, DateTime watchedAt})>[(id: 1, watchedAt: DateTime.utc(2025, 5, 1, 20))];

  @override
  Future<Map<String, dynamic>> add(Map<String, dynamic> body) async {
    if (rateLimitOnce) {
      rateLimitOnce = false;
      throw const TrackerRateLimitException(service: TrackerService.trakt, retryAfterSeconds: 3);
    }
    bodies.add(body);
    var id = 100;
    for (final m in (body['movies'] as List? ?? const [])) {
      entries.add((id: id++, watchedAt: DateTime.parse((m as Map)['watched_at'] as String)));
    }
    for (final s in (body['shows'] as List? ?? const [])) {
      for (final season in ((s as Map)['seasons'] as List)) {
        for (final e in ((season as Map)['episodes'] as List)) {
          entries.add((id: id++, watchedAt: DateTime.parse((e as Map)['watched_at'] as String)));
        }
      }
    }
    return {
      'added': {
        'movies': (body['movies'] as List?)?.length ?? 0,
        'episodes': id - 100 - ((body['movies'] as List?)?.length ?? 0),
      },
      'not_found': {'movies': [], 'shows': [], 'episodes': []},
    };
  }

  @override
  Future<Map<String, dynamic>> removeIds(List<int> ids) async {
    removed.addAll(ids);
    return {
      'deleted': {'movies': 1, 'episodes': ids.length - 1},
    };
  }

  @override
  Future<List<({int id, DateTime watchedAt})>> entriesSince(DateTime startAt) async => [
    for (final e in entries)
      if (!e.watchedAt.isBefore(startAt)) e,
  ];
}
