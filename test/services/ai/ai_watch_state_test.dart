import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/ai/ai_suggestions.dart';
import 'package:plezy/services/ai/ai_tools.dart';
import 'package:plezy/services/ai/ai_watch_state.dart';
import 'package:plezy/services/brain/history_brain.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/index_mapping.dart';
import 'package:plezy/services/library_index/library_index.dart';
import 'package:plezy_brain/plezy_brain.dart';

/// The three films the item names: bulk-watched in the brain (one logged
/// play, no date), view_count NULL on every copy.
const _bulkWatched = [
  ('1', 'The Prestige', 2006, 'tt0482571'),
  ('2', 'Ex Machina', 2014, 'tt0470752'),
  ('3', 'The Departed', 2006, 'tt0407887'),
];

void main() {
  late IndexDatabase db;
  late LibraryIndex index;
  late Directory dir;
  late HistoryBrain brain;

  Future<void> add(
    String key,
    String title, {
    int year = 2010,
    String? imdb,
    String server = 's',
    String type = 'movie',
    int? leafCount,
    int? viewedLeafCount,
    int? viewCount,
    int? lastViewedAt,
  }) => db
      .into(db.indexTitles)
      .insert(
        indexRowFromPlex(
          {
            'ratingKey': key,
            'type': type,
            'title': title,
            'year': year,
            'audienceRating': 8.0,
            'leafCount': ?leafCount,
            'viewedLeafCount': ?viewedLeafCount,
            'viewCount': ?viewCount,
            'lastViewedAt': ?lastViewedAt,
            'Genre': [
              {'tag': 'Drama'},
            ],
            if (imdb != null)
              'Guid': [
                {'id': 'imdb://$imdb'},
              ],
          },
          serverId: server,
          serverName: server.toUpperCase(),
          libraryKey: '1',
          libraryTitle: 'Movies',
        ),
      );

  setUp(() async {
    db = IndexDatabase.memory();
    index = LibraryIndex(openDatabase: Future.value(db), requestGap: Duration.zero);
    dir = Directory.systemTemp.createTempSync('ai_watch_state_test');
    brain = HistoryBrain(folder: () async => dir);
    final store = await brain.store;
    for (final (key, title, year, imdb) in _bulkWatched) {
      // Two copies each (Main and Xtra), neither with a play count.
      await add(key, title, year: year, imdb: imdb);
      await add(key, title, year: year, imdb: imdb, server: 'x');
    }
    await add('4', 'Arrival', year: 2016, imdb: 'tt2543164');
    await add('5', 'Dark', type: 'show', imdb: 'tt5753856', leafCount: 26, viewedLeafCount: 0);
    store.putProfiles([
      for (final (_, title, year, imdb) in _bulkWatched)
        TitleProfile(
          id: 'm:imdb:$imdb',
          kind: TitleKind.movie,
          title: title,
          year: year,
          imdb: imdb,
          inLibrary: true,
          bulkPlays: 1,
        ),
      TitleProfile(
        id: 's:imdb:tt5753856',
        kind: TitleKind.show,
        title: 'Dark',
        imdb: 'tt5753856',
        inLibrary: true,
        watches: [DateTime.utc(2025, 3, 2), DateTime.utc(2025, 3, 9)],
        episodesWatched: 12,
        episodeCount: 26,
      ),
    ]);
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<IndexedTitle> row(String id) => (db.select(db.indexTitles)..where((r) => r.id.equals(id))).getSingle();

  test('The Prestige, Ex Machina and The Departed read as seen, though no copy counts a play', () async {
    final watch = await WatchStates.load(brain);
    for (final key in ['s:1', 'x:1', 's:2', 's:3']) {
      final t = await row(key);
      expect(t.viewCount, isNull);
      expect(watch.of(t).seen, isTrue, reason: t.title);
      expect(AiTools.line(t, watch: watch.of(t)), contains('| seen (logged, no date) |'));
    }
    final arrival = await row('s:4');
    expect(watch.of(arrival).unwatched, isTrue);
    expect(AiTools.line(arrival, watch: watch.of(arrival)), contains('| unwatched |'));
    // A show: the brain's episodes, out of the server's count.
    final dark = await row('s:5');
    expect(AiTools.line(dark, watch: watch.of(dark)), contains('| watched 12/26 eps |'));
  });

  test('a dated watch prints its month; a row with no brain falls back to its own counts', () async {
    await add(
      '6',
      'Heat',
      year: 1995,
      viewCount: 1,
      lastViewedAt: DateTime.utc(2025, 3, 14).millisecondsSinceEpoch ~/ 1000,
    );
    final heat = await row('s:6');
    expect(WatchState.of(heat).label, 'seen 2025-03');
    // Without the brain, the bulk-watched three look unwatched (the bug).
    expect(WatchStates.none.of(await row('s:1')).label, 'unwatched');
  });

  test('search_library watch:unwatched drops brain-watched titles, over-fetching to fill', () async {
    final tools = AiTools(index: index, watch: await WatchStates.load(brain));
    final result = await tools.run('search_library', {'watch': 'unwatched', 'limit': 1});
    expect(result, contains('Arrival'));
    for (final (_, title, _, _) in _bulkWatched) {
      expect(result, isNot(contains(title)));
    }
    expect(result, isNot(contains('Dark')));
    // Any watch state still lists them, described as seen (rewatch asks).
    final any = await tools.run('search_library', {'limit': 10});
    expect(any, contains('The Prestige (2006) | movie | Drama | ★8.0 | seen (logged, no date)'));
  });

  test('find_titles describes seen titles as seen', () async {
    final tools = AiTools(index: index, watch: await WatchStates.load(brain));
    final result = await tools.run('find_titles', {
      'titles': [
        {'title': 'Ex Machina', 'year': 2014},
        {'title': 'Arrival'},
      ],
    });
    expect(result, contains('Ex Machina (2014) | movie | Drama | ★8.0 | seen (logged, no date)'));
    expect(result, contains('Arrival (2016) | movie | Drama | ★8.0 | unwatched'));
  });

  test('suggested lists leave out brain-watched titles', () async {
    final titles = [
      for (final t in await AiSuggestions.fill(index, brain, {
        'genres_all': ['Drama'],
      }))
        t.title,
    ];
    expect(titles, ['Arrival']);
  });

  test('top-up candidates come from find_titles and search_library only', () {
    final tools = AiTools(index: index);
    tools.noteCandidates('text_search', 's:10 | Surface Match | movie | x');
    tools.noteCandidates('similar_titles', 's:11 | Similar Kids Film | movie | x');
    tools.noteCandidates('history_query', 's:12 | From History | movie | x');
    tools.noteCandidates('search_library', 's:13 | Searched | movie | x');
    tools.noteCandidates('find_titles', 's:14 | Model Named | movie | x');
    // Seen first by text_search, then by the model: it counts as the model's.
    tools.noteCandidates('find_titles', 's:10 | Surface Match | movie | x');
    expect(tools.topUpCandidates, ['s:14', 's:10', 's:13']);
  });
}
