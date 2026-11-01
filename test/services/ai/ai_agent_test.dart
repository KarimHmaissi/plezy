import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/ai_agent.dart';
import 'package:plezy/services/ai/ai_key_store.dart';
import 'package:plezy/services/ai/ai_spend.dart';
import 'package:plezy/services/ai/claude_client.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/index_mapping.dart';
import 'package:plezy/services/library_index/library_index.dart';

import '../../test_helpers/prefs.dart';

void main() {
  late IndexDatabase indexDb;
  late ForkDatabase forkDb;
  late LibraryIndex index;
  final requests = <Map<String, dynamic>>[];

  setUp(() async {
    resetSharedPreferencesForTest();
    await AiKeyStore.write('sk-ant-test');
    forkDb = ForkDatabase.memory();
    Customisation.debugSetStore(LocalCustomisationStore(forkDb));
    indexDb = IndexDatabase.memory();
    index = LibraryIndex(openDatabase: Future.value(indexDb), requestGap: Duration.zero);
    await indexDb
        .into(indexDb.indexTitles)
        .insert(
          indexRowFromPlex(
            {
              'ratingKey': '1',
              'type': 'movie',
              'title': 'Heat',
              'year': 1995,
              'Genre': [
                {'tag': 'Crime'},
              ],
              'Guid': [
                {'id': 'imdb://tt0113277'},
              ],
            },
            serverId: 's',
            serverName: 'S',
            libraryKey: '1',
            libraryTitle: 'Movies',
          ),
        );
    requests.clear();
  });
  tearDown(() async {
    Customisation.debugSetStore(null);
    await indexDb.close();
    await forkDb.close();
  });

  http.Response reply(List<Map<String, Object?>> content, String stop) => http.Response(
    jsonEncode({
      'content': content,
      'stop_reason': stop,
      'usage': {'input_tokens': 1000, 'output_tokens': 100, 'cache_read_input_tokens': 500},
    }),
    200,
  );

  test('runs tools locally, sends results back, and stops at show_picks', () async {
    var step = 0;
    final mock = MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      expect(request.headers['anthropic-version'], ClaudeClient.apiVersion);
      step++;
      if (step == 1) {
        return reply([
          {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'find_titles',
            'input': {
              'titles': [
                {'title': 'Heat', 'year': 1995},
                {'title': 'Thief', 'year': 1981},
              ],
            },
          },
        ], 'tool_use');
      }
      return reply([
        {
          'type': 'tool_use',
          'id': 't2',
          'name': 'show_picks',
          'input': {
            'intro': 'A great crime film:',
            'picks': [
              {'id': 's:1', 'reason': 'Classic heist thriller'},
              {'id': 's:999', 'reason': 'Invented'},
            ],
          },
        },
      ], 'tool_use');
    });
    final agent = AiAgent(
      index: index,
      claudeClient: ClaudeClient('sk-ant-test', httpClient: mock),
    );
    final answer = await agent.ask('crime films');

    expect(answer.picks.map((p) => p.title.title), ['Heat']);
    expect(answer.unknownPickIds, ['s:999']);
    expect(answer.intro, 'A great crime film:');
    expect(requests, hasLength(2), reason: 'no extra round trip after show_picks');

    // The second request carries the thinking block back unchanged and the tool result.
    final messages = (requests[1]['messages'] as List).cast<Map>();
    expect(((messages[1]['content'] as List).first as Map)['type'], 'thinking');
    final result = (messages[2]['content'] as List).single as Map;
    expect(result['tool_use_id'], 't1');
    expect(result['content'], contains('Heat (1995)'));
    expect(result['content'], contains('Not on the servers: Thief (1981)'));

    // Request shape: Sonnet with adaptive thinking, cached system, fallbacks.
    expect(requests[0]['model'], 'claude-sonnet-5-5');
    expect(requests[0]['thinking'], {'type': 'adaptive'});
    expect(requests[0]['fallbacks'], 'default');
    expect(((requests[0]['system'] as List).single as Map)['cache_control'], {'type': 'ephemeral'});

    final spend = await AiSpend.month();
    expect(spend.requests, 2);
    expect(spend.dollars, closeTo(2 * (1000 * 2 + 100 * 10 + 500 * 0.2) / 1e6, 1e-9));
  });

  test('a rejected key gives a clear error', () async {
    final mock = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'},
        }),
        401,
      ),
    );
    final agent = AiAgent(
      index: index,
      claudeClient: ClaudeClient('sk-ant-test', httpClient: mock),
    );
    final answer = await agent.ask('anything');
    expect(answer.error, contains('rejected'));
    expect(answer.picks, isEmpty);
  });
}
