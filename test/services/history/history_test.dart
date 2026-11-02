import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/history/history_models.dart';
import 'package:plezy/services/history/history_service.dart';
import 'package:plezy/services/history/history_stats.dart';
import 'package:plezy/services/library_index/library_index.dart' show IndexSource;

HistoryPlay _movie(
  String at, {
  HistorySource source = HistorySource.trakt,
  String imdb = 'tt1',
  int? runtime,
  int? year = 1999,
  List<String> genres = const [],
  List<String> directors = const [],
}) => HistoryPlay(
  kind: HistoryKind.movie,
  watchedAt: DateTime.parse(at),
  title: 'Film $imdb',
  imdb: imdb,
  year: year,
  runtimeMinutes: runtime,
  genres: genres,
  directors: directors,
  sources: {source},
);

HistoryPlay _episode(String at, {int season = 1, int episode = 1, HistorySource source = HistorySource.trakt}) =>
    HistoryPlay(
      kind: HistoryKind.episode,
      watchedAt: DateTime.parse(at),
      title: 'Show A',
      tvdb: '100',
      season: season,
      episode: episode,
      runtimeMinutes: 30,
      sources: {source},
    );

void main() {
  group('mergeHistory', () {
    test('a Plex watch close to a Trakt watch of the same film is listed once, with both sources', () {
      final merged = mergeHistory(
        trakt: [_movie('2025-03-01T20:00:00Z')],
        plex: [
          _movie('2025-03-02T06:00:00Z', source: HistorySource.plex, runtime: 120, genres: ['Drama']),
        ],
      );
      expect(merged.plays, hasLength(1));
      expect(merged.plays.single.sources, {HistorySource.trakt, HistorySource.plex});
      expect(merged.plays.single.runtimeMinutes, 120);
      expect(merged.plays.single.genres, ['Drama']);
      expect(merged.matched, 1);
    });

    test('a Plex watch far from any Trakt watch is a separate watch', () {
      final merged = mergeHistory(
        trakt: [_movie('2020-03-01T20:00:00Z')],
        plex: [_movie('2025-03-01T20:00:00Z', source: HistorySource.plex)],
      );
      expect(merged.plays, hasLength(2));
      expect(merged.plays.first.watchedAt.year, 2025);
    });

    test('episodes match on show and episode number, not just the show', () {
      final merged = mergeHistory(
        trakt: [_episode('2025-01-01T20:00:00Z', episode: 1)],
        plex: [_episode('2025-01-01T21:00:00Z', episode: 2, source: HistorySource.plex)],
      );
      expect(merged.plays, hasLength(2));
    });

    test('undated Trakt entries are left out and counted', () {
      final merged = mergeHistory(trakt: [_movie('1970-01-01T00:00:00Z'), _movie('2024-05-05T10:00:00Z')], plex: []);
      expect(merged.plays, hasLength(1));
      expect(merged.undated, 1);
    });
  });

  group('bulk dates', () {
    List<HistoryPlay> imported(String at, int n, HistorySource source) => [
      for (var i = 1; i <= n; i++) _episode(at, episode: i, source: source),
    ];

    test('many watches minutes apart are flagged as bulk', () {
      final plays = [...imported('2020-01-01T10:00:00Z', 15, HistorySource.trakt), _movie('2020-01-01T10:01:00Z')];
      markBulkDates(plays);
      expect(plays.every((p) => p.bulk), isTrue);
      final season = imported('2020-01-01T10:00:00Z', 6, HistorySource.trakt);
      markBulkDates(season);
      expect(season.every((p) => p.bulk), isTrue, reason: 'a season marked watched at once');
      final few = imported('2020-01-01T10:00:00Z', 3, HistorySource.trakt);
      markBulkDates(few);
      expect(few.any((p) => p.bulk), isFalse);
    });

    test('a Trakt import and a real Plex date of the same episode are one watch, on the Plex date', () {
      final merged = mergeHistory(
        trakt: imported('2020-01-01T10:00:00Z', 20, HistorySource.trakt),
        plex: [_episode('2024-06-01T20:00:00Z', episode: 3, source: HistorySource.plex)],
      );
      expect(merged.plays, hasLength(20));
      final ep3 = merged.plays.firstWhere((p) => p.episode == 3);
      expect(ep3.watchedAt.year, 2024);
      expect(ep3.sources, {HistorySource.plex, HistorySource.trakt});
      expect(ep3.bulk, isFalse);
    });

    test('a Plex mark-as-watched of something on Trakt adds nothing', () {
      final merged = mergeHistory(
        trakt: [_episode('2021-03-01T20:00:00Z', episode: 3)],
        plex: imported('2023-01-01T09:00:00Z', 20, HistorySource.plex),
      );
      expect(merged.plays, hasLength(20));
      expect(merged.plays.where((p) => p.episode == 3).single.watchedAt.year, 2021);
    });

    test('bulk watches count in all time only, never in months, streaks or binges', () {
      final plays = mergeHistory(
        trakt: [...imported('2020-01-01T10:00:00Z', 20, HistorySource.trakt), _movie('2025-02-01T20:00:00Z')],
        plex: const [],
      ).plays;
      final all = HistoryStats.compute(plays, now: DateTime(2025, 2, 1, 22));
      expect(all.episodes, 20);
      expect(all.bulkCounted, 20);
      expect(all.plays, hasLength(1));
      expect(all.longestBinge, isNull);
      expect(all.byMonth.keys, [DateTime(2025, 2)]);
      expect(HistoryStats.compute(plays, year: 2020).episodes, 0);
      expect(HistoryStats.yearsOf(plays), [2025]);
    });

    test('a Plex episode without show ids matches a Trakt show of the same name', () {
      final plex = HistoryPlay(
        kind: HistoryKind.episode,
        watchedAt: DateTime.parse('2025-01-01T21:00:00Z'),
        title: 'show a',
        season: 1,
        episode: 1,
        sources: {HistorySource.plex},
      );
      final merged = mergeHistory(trakt: [_episode('2025-01-01T20:00:00Z')], plex: [plex]);
      expect(merged.plays, hasLength(1));
    });
  });

  group('HistoryStats', () {
    test('counts films, episodes, shows and hours, estimating missing runtimes', () {
      final stats = HistoryStats.compute([
        _movie('2025-01-01T20:00:00Z', runtime: 90),
        _movie('2025-01-02T20:00:00Z', imdb: 'tt2'),
        _episode('2025-01-03T20:00:00Z'),
      ], now: DateTime(2025, 1, 3, 23));
      expect(stats.films, 2);
      expect(stats.episodes, 1);
      expect(stats.shows, 1);
      expect(stats.minutes, 90 + HistoryStats.fallbackFilmMinutes + 30);
      expect(stats.minutesEstimated, 1);
    });

    test('streaks count consecutive local days, current only when it reaches today', () {
      final plays = [
        for (final d in ['2025-02-01', '2025-02-02', '2025-02-03', '2025-02-10', '2025-02-11'])
          _movie('${d}T12:00:00', imdb: 'tt$d'),
      ];
      expect(HistoryStats.compute(plays, now: DateTime(2025, 2, 11, 20)).currentStreak, 2);
      expect(HistoryStats.compute(plays, now: DateTime(2025, 2, 11, 20)).bestStreak, 3);
      expect(HistoryStats.compute(plays, now: DateTime(2025, 2, 20)).currentStreak, 0);
    });

    test('a year filter keeps only that year; months, decades, rewatches and binges', () {
      final plays = [
        _movie('2024-12-31T12:00:00', year: 1985),
        _movie('2025-03-01T12:00:00', year: 1985, directors: ['Director A']),
        _movie('2025-03-09T12:00:00', year: 1985, directors: ['Director A']),
        _episode('2025-04-01T12:00:00', episode: 1),
        _episode('2025-04-01T13:00:00', episode: 2),
        _episode('2025-04-01T14:00:00', episode: 3),
      ];
      final stats = HistoryStats.compute(plays, year: 2025, now: DateTime(2025, 6, 1));
      expect(stats.plays, hasLength(5));
      expect(stats.byMonth[DateTime(2025, 3)], 2);
      expect(stats.byMonth[DateTime(2025, 4)], 3);
      expect(stats.decades, {1980: 2});
      expect(stats.topDirectors.single.key, 'Director A');
      expect(stats.topDirectors.single.value, 2);
      expect(stats.rewatches.single.value, 2);
      expect(stats.longestBinge?.episodes, 3);
      expect(HistoryStats.yearsOf(plays), [2025, 2024]);
    });
  });

  group('parsing', () {
    test('a Plex film and episode keep their dates, ids and Plex location', () {
      final movie = plexMoviePlay({
        'ratingKey': '10',
        'title': 'Film A',
        'year': 2001,
        'duration': 5400000,
        'lastViewedAt': 1735760000,
        'Guid': [
          {'id': 'imdb://tt9'},
        ],
        'Genre': [
          {'tag': 'Drama'},
        ],
      }, serverId: 'srv')!;
      expect(movie.runtimeMinutes, 90);
      expect(movie.imdb, 'tt9');
      expect(movie.plexRatingKey, '10');
      expect(movie.watchedAt, DateTime.fromMillisecondsSinceEpoch(1735760000 * 1000, isUtc: true));

      final episode = plexEpisodePlay(
        {
          'grandparentRatingKey': '20',
          'grandparentTitle': 'Show A',
          'parentIndex': 2,
          'index': 5,
          'lastViewedAt': 1735760000,
        },
        show: {
          'Guid': [
            {'id': 'tvdb://77'},
          ],
        },
        serverId: 'srv',
      )!;
      expect(episode.watchKey, 's:tvdb:77:2x5');
      expect(episode.plexRatingKey, '20');
      expect(plexMoviePlay({'ratingKey': '1', 'title': 'x'}, serverId: 'srv'), isNull);
    });

    test('Trakt entries become plays; genres are title-cased', () {
      final movie = traktPlayFromJson({
        'id': 1,
        'type': 'movie',
        'watched_at': '2025-05-01T20:00:00.000Z',
        'movie': {
          'title': 'Film A',
          'year': 2000,
          'runtime': 100,
          'genres': ['science-fiction'],
          'ids': {'trakt': 5, 'imdb': 'tt5', 'tmdb': 6},
        },
      })!;
      expect(movie.genres, ['Science Fiction']);
      expect(movie.tmdb, '6');
      expect(movie.traktHistoryId, 1);
      final episode = traktPlayFromJson({
        'id': 2,
        'type': 'episode',
        'watched_at': '2025-05-01T20:00:00.000Z',
        'episode': {'season': 1, 'number': 3, 'title': 'Ep', 'runtime': 45},
        'show': {
          'title': 'Show A',
          'ids': {'trakt': 9, 'tvdb': 77},
        },
      })!;
      expect(episode.watchKey, 's:tvdb:77:1x3');
      expect(episode.runtimeMinutes, 45);
    });

    test('a Trakt watch dated on its release day is flagged', () {
      final play = traktPlayFromJson({
        'id': 3,
        'type': 'movie',
        'watched_at': '1999-03-31T00:00:00.000Z',
        'movie': {
          'title': 'Film A',
          'released': '1999-03-31',
          'ids': {'imdb': 'tt7'},
        },
      })!;
      expect(play.datedAtRelease, isTrue);
      markBulkDates([play]);
      expect(play.bulk, isTrue);
      expect(HistoryPlay.fromJson(play.toJson()).datedAtRelease, isTrue);
    });

    test('plays round-trip through the cache format', () {
      final play = _movie('2025-05-01T20:00:00Z', genres: ['Drama'])..plexRatingKey = '3';
      final back = HistoryPlay.fromJson(play.toJson());
      expect(back.watchKey, play.watchKey);
      expect(back.watchedAt, play.watchedAt);
      expect(back.genres, ['Drama']);
      expect(back.plexRatingKey, '3');
    });
  });

  group('HistoryService', () {
    test('reads watched films from Plex, caches them, and shows the cache next time', () async {
      final dir = await Directory.systemTemp.createTemp('history');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/cache.json');
      final source = _FakeSource();
      final service = HistoryService(cacheFile: () async => file, requestGap: Duration.zero);
      await service.load(plex: () => [source]);
      expect(service.state.value.history!.plays, hasLength(1));
      expect(source.filters.single, containsPair('lastViewedAt>>', '1'));
      expect(file.existsSync(), isTrue);

      final again = HistoryService(cacheFile: () async => file, requestGap: Duration.zero);
      await again.load(plex: () => []);
      expect(again.state.value.history!.plays, hasLength(1));
    });
  });
}

class _FakeSource implements IndexSource {
  final filters = <Map<String, String>>[];

  @override
  String get serverId => 'srv';

  @override
  String get serverName => 'Server';

  @override
  Future<List<Map<String, dynamic>>> sections() async => [
    {'key': '1', 'type': 'movie'},
  ];

  @override
  Future<({List<Map<String, dynamic>> items, int total})> page(
    String sectionKey, {
    required int plexType,
    required int start,
    required int size,
    Map<String, String> filters = const {},
  }) async {
    this.filters.add(filters);
    return (
      items: [
        {'ratingKey': '1', 'title': 'Film A', 'lastViewedAt': 1735760000, 'duration': 6000000},
      ],
      total: 1,
    );
  }
}
