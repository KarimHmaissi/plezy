import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/ai_agent.dart';
import 'package:plezy/services/ai/ai_key_store.dart';
import 'package:plezy/services/ai/ai_tools.dart';
import 'package:plezy/services/ai/claude_client.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/brain/history_profiles.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/index_mapping.dart';
import 'package:plezy/services/library_index/library_index.dart';
import 'package:plezy/services/reel/reel_ledger.dart';
import 'package:plezy/services/reel/reel_store.dart';

import '../../test_helpers/prefs.dart';

/// One saved ask: the request and the model's turns as they were recorded
/// (tool calls, then show_picks). Invented titles only.
typedef SavedAsk = ({String request, List<List<Map<String, Object?>>> turns});

/// What one replay of an ask sent to the model.
typedef Replay = ({String system, Map<String, String> results, List<String> picks});

/// V2-44 acceptance: the saved asks replayed before and after the Reel's
/// pick ledger reaches Ask. Facts, not weights: the only difference the
/// model sees is a fact on the lines of titles the Reel showed or the user
/// passed on (and the prompt lines that explain them); every other line,
/// and every ask from a household that never used the Reel, is unchanged.
void main() {
  late IndexDatabase indexDb;
  late ForkDatabase forkDb;
  late LibraryIndex index;
  late ReelStore reel;
  late DateTime now;
  final titleIds = <String, String>{};

  Future<void> add(String key, String title, String imdb, {int views = 0, DateTime? lastViewed}) async {
    final row = indexRowFromPlex(
      {
        'ratingKey': key,
        'type': 'movie',
        'title': title,
        'year': 2019,
        'audienceRating': 7.4,
        'duration': 6600000,
        'viewCount': views,
        if (lastViewed != null) 'lastViewedAt': lastViewed.millisecondsSinceEpoch ~/ 1000,
        'Genre': [
          {'tag': 'Drama'},
        ],
        'Guid': [
          {'id': 'imdb://$imdb'},
        ],
      },
      serverId: 's',
      serverName: 'Server A',
      libraryKey: '1',
      libraryTitle: 'Movies',
    );
    await indexDb.into(indexDb.indexTitles).insert(row);
    final stored = await (indexDb.select(indexDb.indexTitles)..where((t) => t.ratingKey.equals(key))).getSingle();
    titleIds[title] = LibraryRef.of(stored).titleId;
  }

  setUp(() async {
    resetSharedPreferencesForTest();
    await AiKeyStore.write('sk-ant-test');
    forkDb = ForkDatabase.memory();
    final settings = LocalCustomisationStore(forkDb);
    Customisation.debugSetStore(settings);
    indexDb = IndexDatabase.memory();
    index = LibraryIndex(openDatabase: Future.value(indexDb), requestGap: Duration.zero);
    now = DateTime(2026, 3, 10, 20);
    reel = ReelStore(database: () async => forkDb, settings: () async => settings, clock: () => now);
    titleIds.clear();
    await add('1', 'Harbor Lights', 'tt9100001');
    await add('2', 'Copper Valley', 'tt9100002');
    // Shown in the Reel, then watched on Plex since.
    await add('3', 'Northern Static', 'tt9100003', views: 1, lastViewed: DateTime(2026, 3, 9, 21));
    await add('4', 'Lantern Road', 'tt9100004');
    await add('5', 'Paper Orchard', 'tt9100005');
  });

  tearDown(() async {
    Customisation.debugSetStore(null);
    await indexDb.close();
    await forkDb.close();
  });

  Future<void> reelAt(DateTime at, Future<void> Function() write) async {
    final was = now;
    now = at;
    await write();
    now = was;
  }

  /// What the Reel saw: Harbor Lights sampled on three evenings, Copper
  /// Valley passed on, Northern Static sampled (then watched on Plex),
  /// Lantern Road only quick-skipped (not a showing).
  Future<void> useTheReel() async {
    for (final d in [9, 6, 2]) {
      await reelAt(DateTime(2026, 3, 10 - d, 21), () => reel.record(titleIds['Harbor Lights']!, ReelAction.sampled));
    }
    await reelAt(DateTime(2026, 2, 18, 21), () => reel.record(titleIds['Copper Valley']!, ReelAction.sampled));
    await reelAt(DateTime(2026, 2, 18, 21, 1), () => reel.notForMe(titleIds['Copper Valley']!));
    await reelAt(DateTime(2026, 3, 5, 21), () => reel.record(titleIds['Northern Static']!, ReelAction.toEnd));
    await reelAt(DateTime(2026, 3, 8, 21), () => reel.record(titleIds['Lantern Road']!, ReelAction.quickSkip));
  }

  Map<String, Object?> call(String id, String name, Map<String, Object?> input) => {
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': input,
  };

  Map<String, Object?> picks(List<String> ids) => call('done', 'show_picks', {
    'title': 'Picks',
    'intro': 'Some picks:',
    'picks': [
      for (final id in ids) {'id': id, 'reason': ''},
    ],
  });

  final saved = <SavedAsk>[
    (
      request: 'a calm drama for tonight',
      turns: [
        [
          call('t1', 'find_titles', {
            'titles': [
              {'title': 'Harbor Lights'},
              {'title': 'Copper Valley'},
              {'title': 'Lantern Road'},
              {'title': 'Not On Any Server'},
            ],
          }),
          call('t2', 'search_library', {
            'type': 'movie',
            'genres_all': ['Drama'],
            'sort': 'title',
          }),
        ],
        [
          picks(['s:1', 's:4', 's:5']),
        ],
      ],
    ),
    (
      request: 'is Harbor Lights on my server?',
      turns: [
        [
          call('t1', 'get_title', {'id': 's:1'}),
        ],
        [
          picks(['s:1']),
        ],
      ],
    ),
    (
      request: 'something like Northern Static',
      turns: [
        [
          call('t1', 'get_title', {'id': 's:3'}),
          call('t2', 'find_titles', {
            'titles': [
              {'title': 'Paper Orchard'},
              {'title': 'Lantern Road'},
            ],
          }),
        ],
        [
          picks(['s:5', 's:4']),
        ],
      ],
    ),
  ];

  /// Replays [ask] through the agent against a fake Claude that repeats
  /// the recorded turns, with [ledger] (or none).
  Future<Replay> replay(SavedAsk ask, {ReelLedger? ledger}) async {
    final sent = <Map<String, dynamic>>[];
    var step = 0;
    final mock = MockClient((request) async {
      sent.add(jsonDecode(request.body) as Map<String, dynamic>);
      final turn = ask.turns[step++];
      return http.Response(
        jsonEncode({
          'content': turn,
          'stop_reason': 'tool_use',
          'usage': {'input_tokens': 100, 'output_tokens': 10},
        }),
        200,
      );
    });
    final agent = AiAgent(
      index: index,
      claudeClient: ClaudeClient('sk-ant-test', httpClient: mock),
      ledger: ledger?.snapshot,
    );
    final answer = await agent.ask(ask.request);
    final results = <String, String>{};
    for (final m in (sent.last['messages'] as List).cast<Map>()) {
      if (m['role'] != 'user' || m['content'] is! List) continue;
      for (final b in (m['content'] as List).cast<Map>()) {
        if (b['type'] == 'tool_result') results['${b['tool_use_id']}'] = '${b['content']}';
      }
    }
    return (
      system: (((sent.first['system'] as List).first as Map)['text'] as String),
      results: results,
      picks: [for (final p in answer.picks) p.title.title],
    );
  }

  ReelLedger ledger() => ReelLedger(store: reel, host: () => true, clock: () => now, cacheFor: Duration.zero);

  /// Every line of an ask's tool results, in order.
  List<String> lines(Replay r) => [for (final t in r.results.values) ...t.split('\n')];

  test('replayed saved asks: only Reel-touched titles gain a fact', () async {
    await useTheReel();
    final passedOn = 'passed on in ${SeenState.monthName(2)}';
    const shown = 'shown 3× in the Reel lately, not played yet';

    for (final ask in saved) {
      final before = await replay(ask);
      final after = await replay(ask, ledger: ledger());

      expect(before.system, isNot(contains('Reel facts on title lines')), reason: ask.request);
      expect(after.system, contains('Reel facts on title lines'), reason: ask.request);
      expect(after.system, startsWith(before.system), reason: 'the ledger prompt only adds');
      expect(before.picks, isNotEmpty, reason: ask.request);
      expect(after.picks, before.picks, reason: 'the model decides; code never reorders or drops a pick');
      expect(after.results.keys, before.results.keys);

      final was = lines(before), got = lines(after);
      expect(got, hasLength(was.length), reason: ask.request);
      for (final (i, line) in got.indexed) {
        if (line.contains('Harbor Lights (2019)')) {
          expect(line, was[i].replaceFirst(' | unwatched |', ' | unwatched | $shown |'), reason: ask.request);
        } else if (line.contains('Copper Valley (2019)')) {
          expect(line, was[i].replaceFirst(' | unwatched |', ' | unwatched | $passedOn |'), reason: ask.request);
        } else {
          // Northern Static (watched since it was shown), Lantern Road
          // (only quick-skipped), Paper Orchard (never in the Reel) and
          // every non-title line read exactly as before.
          expect(line, was[i], reason: '${ask.request}: $line');
        }
      }
    }

    // The first ask shows the facts the model now weighs for itself.
    final first = await replay(saved.first, ledger: ledger());
    expect(first.results['t1'], contains('Harbor Lights (2019) | movie | Drama | ★7.4 | 110 min | unwatched | $shown'));
    expect(
      first.results['t1'],
      contains('Copper Valley (2019) | movie | Drama | ★7.4 | 110 min | unwatched | $passedOn'),
    );
    expect(first.results['t1'], contains('Not on the servers: Not On Any Server'));
  });

  test('a household that never used the Reel replays exactly as before', () async {
    for (final ask in saved) {
      final before = await replay(ask);
      final after = await replay(ask, ledger: ledger());
      expect(after.system, before.system, reason: 'no ledger facts, no ledger prompt');
      expect(after.results, before.results);
      expect(after.picks, before.picks);
    }
  });

  test('the tools count the title lines that carried a fact, for the ask log', () async {
    await useTheReel();
    final tools = AiTools(index: index, ledger: await ledger().snapshot());
    final out = await tools.run('find_titles', {
      'titles': [
        {'title': 'Harbor Lights'},
        {'title': 'Copper Valley'},
        {'title': 'Northern Static'},
        {'title': 'Paper Orchard'},
      ],
    });
    expect(out, contains('shown 3× in the Reel lately, not played yet'));
    expect(tools.ledgerFacts, 2, reason: 'Harbor Lights and Copper Valley; Northern Static was watched since');
  });

  test('a ledger that fails never holds up the ask', () async {
    final broken = ReelLedger(
      store: ReelStore(
        database: () async => throw StateError('no database'),
        settings: () async => throw StateError('no settings'),
      ),
      host: () => true,
      clock: () => now,
      cacheFor: Duration.zero,
    );
    final before = await replay(saved.first);
    final after = await replay(saved.first, ledger: broken);
    expect(after.results, before.results);
    expect(after.picks, before.picks);
  });
}
