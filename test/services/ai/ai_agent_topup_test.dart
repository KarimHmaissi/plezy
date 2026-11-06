import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/ai_agent.dart';
import 'package:plezy/services/ai/ai_key_store.dart';
import 'package:plezy/services/ai/claude_client.dart';
import 'package:plezy/services/brain/history_brain.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/index_mapping.dart';
import 'package:plezy/services/library_index/library_index.dart';
import 'package:plezy_brain/plezy_brain.dart';

import '../../test_helpers/prefs.dart';

/// Top-ups of a short broad row, against a fake Claude (no network).
void main() {
  late IndexDatabase indexDb;
  late ForkDatabase forkDb;
  late LibraryIndex index;
  late Directory dir;
  late HistoryBrain brain;

  /// The model's turns, in order, across every ask in a test.
  final turns = <List<Map<String, Object?>>>[];
  final sent = <String>[];

  Future<void> add(
    String key,
    String title, {
    double? rating = 8.0,
    String library = 'Movies',
    String? imdb,
    String? summary,
  }) => indexDb
      .into(indexDb.indexTitles)
      .insert(
        indexRowFromPlex(
          {
            'ratingKey': key,
            'type': 'movie',
            'title': title,
            'year': 2010,
            'audienceRating': ?rating,
            'summary': ?summary,
            'Genre': [
              {'tag': 'Science Fiction'},
            ],
            if (imdb != null)
              'Guid': [
                {'id': 'imdb://$imdb'},
              ],
          },
          serverId: 's',
          serverName: 'S',
          libraryKey: library,
          libraryTitle: library,
        ),
      );

  setUp(() async {
    resetSharedPreferencesForTest();
    await AiKeyStore.write('sk-ant-test');
    forkDb = ForkDatabase.memory();
    Customisation.debugSetStore(LocalCustomisationStore(forkDb));
    indexDb = IndexDatabase.memory();
    index = LibraryIndex(openDatabase: Future.value(indexDb), requestGap: Duration.zero);
    dir = Directory.systemTemp.createTempSync('ai_agent_topup_test');
    brain = HistoryBrain(folder: () async => dir);
    // Bulk-watched (Trakt marks): no play count on the copy.
    await add('1', 'The Glass Orchard', imdb: 'tt9000001');
    await add('2', 'Night Harbour', imdb: 'tt9000002');
    await add('3', 'Paper Lanterns', imdb: 'tt9000003');
    await add('10', 'Picked Film');
    await add('11', 'Unrated Gem', rating: null);
    await add('12', 'Weak Film', rating: 5.5);
    await add('13', 'Toy Racers Turbo', library: 'Kids Movies');
    await add('14', 'Heist In Orbit', summary: 'A daring heist on a space station.');
    (await brain.store).putProfiles([
      for (final (title, imdb) in [
        ('The Glass Orchard', 'tt9000001'),
        ('Night Harbour', 'tt9000002'),
        ('Paper Lanterns', 'tt9000003'),
      ])
        TitleProfile(
          id: 'm:imdb:$imdb',
          kind: TitleKind.movie,
          title: title,
          imdb: imdb,
          inLibrary: true,
          bulkPlays: 1,
        ),
    ]);
    turns.clear();
    sent.clear();
  });
  tearDown(() async {
    Customisation.debugSetStore(null);
    await indexDb.close();
    await forkDb.close();
    dir.deleteSync(recursive: true);
  });

  AiAgent agent() => AiAgent(
    index: index,
    brain: brain,
    claudeClient: ClaudeClient(
      'sk-ant-test',
      httpClient: MockClient((request) async {
        sent.add(request.body);
        return http.Response(
          jsonEncode({
            'content': turns.removeAt(0),
            'stop_reason': 'tool_use',
            'usage': {'input_tokens': 10, 'output_tokens': 10},
          }),
          200,
        );
      }),
    ),
  );

  Map<String, Object?> use(String id, String name, Map<String, Object?> input) => {
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': input,
  };

  List<Map<String, Object?>> find(List<String> titles) => [
    use('f', 'find_titles', {
      'titles': [
        for (final t in titles) {'title': t},
      ],
    }),
  ];

  /// A broad answer whose picks are [ids] (index ids).
  List<Map<String, Object?>> showPicks(List<String> ids) => [
    use('p', 'show_picks', {
      'title': 'Row',
      'scope': 'broad',
      'intro': 'Here you go',
      'headline': 'Picks',
      'writeup': '',
      'top_picks': <Object>[],
      'spotlights': <Object>[],
      'notes': <Object>[],
      'follow_ups': <Object>[],
      'picks': [
        for (final id in ids) {'id': id, 'reason': ''},
      ],
    }),
  ];

  List<String> titlesOf(AiAnswer a) => [for (final p in a.picks) p.title.title];

  test('a top-up skips seen, Kids-library and low-rated titles, adds an unrated one, and stays short', () async {
    turns
      ..add([
        ...find([
          'The Glass Orchard',
          'Night Harbour',
          'Paper Lanterns',
          'Picked Film',
          'Unrated Gem',
          'Weak Film',
          'Toy Racers Turbo',
        ]),
        use('t', 'text_search', {'query': 'heist'}),
      ])
      ..add(showPicks(['s:10']));
    final answer = await agent().ask('a film I haven\'t seen, like a twisty sci-fi thriller');

    expect(titlesOf(answer), ['Picked Film', 'Unrated Gem']);
    // The model was told the three are seen, not unwatched.
    final results = jsonEncode((jsonDecode(sent[1]) as Map)['messages']);
    for (final t in ['The Glass Orchard', 'Night Harbour', 'Paper Lanterns']) {
      expect(results, contains('$t (2010) | movie | Science Fiction | ★8.0 | seen (logged, no date)'));
    }
  });

  test('text_search candidates never fill a row', () async {
    turns
      ..add([
        ...find(['Picked Film']),
        use('t', 'text_search', {'query': 'heist'}),
      ])
      ..add(showPicks(['s:10']));
    final answer = await agent().ask('space films');
    expect(sent[1], contains('Heist In Orbit'), reason: 'the search did find it');
    expect(titlesOf(answer), ['Picked Film']);
  });

  test('Kids-library titles can fill a row the model already chose Kids titles for', () async {
    await add('15', 'Kids Pick', library: 'Kids Movies');
    turns
      ..add(find(['Kids Pick', 'Toy Racers Turbo']))
      ..add(showPicks(['s:15']));
    expect(titlesOf(await agent().ask('films for the kids')), ['Kids Pick', 'Toy Racers Turbo']);
  });

  test('a rewatch ask still tops up with seen titles', () async {
    turns
      ..add(find(['The Glass Orchard', 'Night Harbour', 'Paper Lanterns']))
      ..add(showPicks(['s:1', 's:2']));
    expect(titlesOf(await agent().ask('something I\'ve seen')), [
      'The Glass Orchard',
      'Night Harbour',
      'Paper Lanterns',
    ]);
  });

  test('a title the top-up dropped in one ask can come back in the next', () async {
    final helper = agent();
    turns
      ..add([
        ...find(['Picked Film']),
        use('t', 'text_search', {'query': 'heist'}),
      ])
      ..add(showPicks(['s:10']));
    final first = await helper.ask('space films');
    expect(titlesOf(first), isNot(contains('Heist In Orbit')));

    turns
      ..add(find(['Picked Film', 'Heist In Orbit']))
      ..add(showPicks(['s:10']));
    final second = await helper.ask('more space films', previous: [(request: 'space films', answer: first)]);
    expect(titlesOf(second), ['Picked Film', 'Heist In Orbit']);
  });
}
