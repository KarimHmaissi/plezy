import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/brain/history_profiles.dart';
import 'package:plezy/services/history/history_models.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy_brain/plezy_brain.dart';

IndexedTitle _row(
  String id, {
  String type = 'movie',
  String title = 'T',
  String? imdb,
  String? tvdb,
  String? group,
  int? episodes,
  int? watchedEpisodes,
  int? viewCount,
}) => IndexedTitle(
  id: id,
  serverId: id.split(':').first,
  serverName: 'S',
  libraryKey: '1',
  libraryTitle: 'L',
  ratingKey: id.split(':').last,
  type: type,
  title: title,
  genres: 'Crime|Thriller',
  countries: '',
  directors: 'Dir',
  writers: '',
  cast: 'A|B',
  collections: '',
  groupKey: group ?? imdb ?? id,
  imdb: imdb,
  tvdb: tvdb,
  summary: 'A summary.',
  episodeCount: episodes,
  watchedEpisodeCount: watchedEpisodes,
  viewCount: viewCount,
);

HistoryPlay _play(
  HistoryKind kind,
  DateTime at, {
  String title = 'T',
  String? imdb,
  String? tvdb,
  String? server,
  String? key,
  int? season,
  int? episode,
  HistorySource source = HistorySource.plex,
  bool bulk = false,
  int? traktId,
}) => HistoryPlay(
  kind: kind,
  watchedAt: at,
  title: title,
  imdb: imdb,
  tvdb: tvdb,
  plexServerId: server,
  plexRatingKey: key,
  season: season,
  episode: episode,
  traktId: traktId,
  sources: {source},
)..bulk = bulk;

void main() {
  test('watches from Plex and Trakt land on one title, keyed by the best library copy', () {
    final hd = _row('s1:10', imdb: 'tt1', group: 'g1', viewCount: 3);
    final uhd = _row('s2:20', group: 'g1'); // A 4K copy without ids.
    final library = LibraryLookup([LibraryRef.of(hd), LibraryRef.of(uhd)]);
    final plays = [
      _play(HistoryKind.movie, DateTime.utc(2024, 5), server: 's2', key: '20'),
      _play(HistoryKind.movie, DateTime.utc(2025, 7), imdb: 'tt1', source: HistorySource.trakt),
    ];
    final watched = groupWatches(plays, library);
    expect(watched, hasLength(1));
    expect(watched.single.id, 'm:imdb:tt1');
    final p = watchedProfile(watched.single, row: hd);
    expect(p.watches, hasLength(2));
    expect(p.bulkPlays, 1, reason: "Plex's third play has no date");
    expect(p.rewatched, isTrue);
    expect((p.inLibrary, p.serverId, p.ratingKey), (true, 's1', '10'));
    expect(p.genres, ['Crime', 'Thriller']);
  });

  test('shows count distinct episodes, rewatches and bulk-dated plays apart', () {
    final row = _row('s1:30', type: 'show', tvdb: '99', episodes: 10);
    final library = LibraryLookup([LibraryRef.of(row)]);
    final plays = [
      for (var e = 1; e <= 3; e++)
        _play(HistoryKind.episode, DateTime.utc(2025, 1, e), tvdb: '99', season: 1, episode: e),
      _play(HistoryKind.episode, DateTime.utc(2025, 2), tvdb: '99', season: 1, episode: 1),
      _play(HistoryKind.episode, DateTime.utc(2020), tvdb: '99', season: 1, episode: 4, bulk: true),
    ];
    final p = watchedProfile(groupWatches(plays, library).single, row: row);
    expect(p.episodesWatched, 4);
    expect(p.episodesRewatched, 1);
    expect(p.watches, hasLength(4));
    expect(p.bulkPlays, 1);
    expect(p.progress(DateTime.utc(2026)), ShowProgress.dropped);
  });

  test('titles only on Trakt use its details; extras match by any id', () {
    final library = LibraryLookup(const []);
    final play = _play(HistoryKind.movie, DateTime.utc(2023), imdb: 'tt9', source: HistorySource.trakt, traktId: 5);
    final w = groupWatches([play], library).single;
    final p = watchedProfile(
      w,
      details: const TraktDetails(summary: 'From Trakt', genres: ['Drama'], directors: ['D']),
      extras: const TitleExtras(ratings: {'trakt:5': 9}, watchlist: {'imdb:tt9'}),
    );
    expect((p.inLibrary, p.summary, p.myRating, p.watchlist), (false, 'From Trakt', 9, true));
    expect(p.genres, ['Drama']);
  });

  test('unwatched library titles become profiles too', () {
    final p = libraryProfile(_row('s1:40', imdb: 'tt4'));
    expect((p.id, p.watched, p.inLibrary), ('m:imdb:tt4', false, true));
    expect(p.embedText, contains('A summary.'));
  });

  test('undated plays record where they were logged: Trakt imports and Plex counts', () {
    final row = _row('s1:50', imdb: 'tt5', viewCount: 2);
    final library = LibraryLookup([LibraryRef.of(row)]);
    final plays = [_play(HistoryKind.movie, DateTime.utc(2019), imdb: 'tt5', source: HistorySource.trakt, bulk: true)];
    final p = watchedProfile(groupWatches(plays, library).single, row: row);
    expect(p.watches, isEmpty);
    expect(p.bulkPlays, 2);
    expect(p.bulkVia, {'trakt', 'plexUndated'}, reason: 'one Trakt import, one Plex count with no date');
    final back = TitleProfile.fromJson(p.toJson());
    expect(back.bulkVia, {'trakt', 'plexUndated'});
    expect(TitleProfile.fromJson(libraryProfile(_row('s1:51')).toJson()).bulkVia, isEmpty);
  });
}
