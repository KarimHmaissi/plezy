import 'dart:convert';

import '../../utils/app_logger.dart';
import '../brain/history_brain.dart';
import '../library_index/index_database.dart';
import '../library_index/library_index.dart';
import '../trackers/trakt/trakt_client.dart';
import 'ai_history_tools.dart';
import 'ai_key_store.dart';
import 'ai_spend.dart';
import 'ai_tools.dart';
import 'claude_client.dart';

/// Fork: what a running request is doing: a short step, or the answer's
/// text so far.
class AiProgress {
  const AiProgress({this.step, this.text});
  final String? step;
  final String? text;
}

/// Fork: a step line for the tool the model is calling.
String? _stepFor(String? tool) => switch (tool) {
  'search_library' || 'text_search' || 'find_titles' => 'Searching your library',
  'get_title' => 'Reading up on a title',
  'get_history' || 'get_continue_watching' => 'Looking at what you watch',
  'history_query' || 'history_stats' => 'Checking your history',
  'similar_titles' => 'Finding similar titles',
  'get_ratings' => 'Checking ratings',
  'show_picks' || 'answer_question' => 'Writing it up',
  _ => null,
};

/// One tool call the model made, for the eval report.
typedef AiToolCall = ({String name, String input, int resultChars});

/// The helper's answer to one request.
class AiAnswer {
  AiAnswer({
    this.title,
    required this.intro,
    required this.picks,
    required this.text,
    required this.toolCalls,
    required this.elapsed,
    required this.cost,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
    required this.unknownPickIds,
    this.answer,
    this.writeup,
    this.notes = const [],
    this.followUps = const [],
    this.timing = '',
    this.error,
  });

  /// The model's short name for the row of picks.
  final String? title;
  final String? intro;

  /// Picks resolved against the index, in the model's order.
  final List<({IndexedTitle title, String reason})> picks;

  /// Any text the model wrote besides the picks.
  final String text;

  /// Fork: the written answer to a question about the user's history.
  final String? answer;

  /// Fork: why these picks and what ties them together (2-4 sentences),
  /// "worth knowing" notes, and refinements to offer next.
  final String? writeup;
  final List<String> notes;
  final List<String> followUps;

  /// Fork: where the time went ("model 12.1s (3 calls), tools 1.4s").
  final String timing;
  final List<AiToolCall> toolCalls;
  final Duration elapsed;
  final double cost;
  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;

  /// Pick ids that aren't in the index (should always be empty).
  final List<String> unknownPickIds;
  final String? error;
}

/// The AI helper's agent loop: send the request with the tools, run the
/// tools the model asks for on this device, send the results back, and stop
/// once it calls `show_picks` (or answers in text).
class AiAgent {
  AiAgent({
    required this.index,
    this.trakt,
    this.model = ClaudeModel.sonnet,
    ClaudeClient? claudeClient,
    HistoryBrain? brain,
  }) : _client = claudeClient,
       brain = brain ?? (HistoryBrain.instance.status.value.profiles > 0 ? HistoryBrain.instance : null);

  final LibraryIndex index;
  final TraktClient? trakt;

  /// Fork: the watch history brain, when this host has built one.
  final HistoryBrain? brain;
  final ClaudeModel model;
  ClaudeClient? _client;

  static const int maxSteps = 10;

  /// Thinking effort for each step.
  static String effort = 'low';

  static const String systemPrompt = '''
You are the film and TV helper inside Plezy, a Plex app on the user's TV. The user asks for something to watch; you find it on their own Plex servers and hand back a row of picks.

How to work:
- The user's library is large (about 30,000 films and 15,000 shows across two servers). You can't see it directly; use the tools.
- For "only what's here" requests (genres, years, recently added, unwatched, a person, a library such as Anime or 4K), use search_library and text_search.
- For taste-based requests ("like X", "awesome 80s action"), use your own knowledge to think of strong candidates, then check them with find_titles. Combine both approaches when useful.
- For "based on my history" or "for tonight" requests, use the summary of their watching when it's given (no need to call get_history for taste); otherwise call get_history first.
- Ratings in the library are audience ratings (usually IMDb, 0-10). Brand-new titles often show 9-10 from a handful of votes; before calling a recent title top rated or popular, check a shortlist with get_ratings and prefer titles with many votes.
- Only pick titles whose ids came back from the tools. Never invent ids or claim a title is available without a tool saying so.
- Prefer one entry per title (the tools already merge 4K copies and the second server).
- Respect explicit limits: unwatched means unwatched; runtime limits; "not too long" means roughly under 2 hours.
- Prefer films and shows from roughly the last 25 years unless the user asks for classics, a decade, or older titles; a few standout older picks are fine.
- How many picks: let the request decide, up to 50. List-style asks ("every...", "all the X on my server", "a big list", a full franchise or filmography): 40-50. Broad or open-ended requests (a genre, a mood, an era, "something like X", "based on my history"): about 30-40; the library is big, so a broad request should normally fill a long row. Narrow requests (a specific title, a yes/no question, "a random X", tight constraints): only the titles that genuinely fit, even if that's one or two. Never pad a list with weak matches to reach a number.
- Finish by calling show_picks exactly once, best first, each pick with one short, specific reason.
- Always finish with show_picks, even for yes/no questions ("is X on my server?", "do I have Y?"): put the answer in the intro and the title (or the closest matches) as picks so the user can play it. If nothing fits, call show_picks with an intro saying so and no picks.
- Keep it quick: usually two turns. In the first, call every tool you need at once, in parallel (e.g. find_titles for your candidates, plus search_library or similar_titles); then call show_picks. Only take another turn if the results leave real gaps.
- Keep each pick's reason under 15 words.''';

  /// Fork: added when the history brain is available.
  static const String historyPrompt = '''

Questions about the user's own watching:
- Show progress: "dropped" means a real go then nothing for 6+ months; recent unfinished shows are "paused" or in progress, and caught-up shows (even if still airing) are "finished". Say which you mean.
- "What was that film I watched...", "how many X have I seen", "which shows did I drop", "what did I watch most in 2024", "when did I last watch Y": use history_query (with `about` for a half-remembered plot or theme) and history_stats, then finish with answer_question instead of show_picks. That holds when the answer is a list ("which shows did I drop"): write a short summary (how many, the pattern) and put the titles in as cards.
- Cards: the titles the answer is about, up to 20 (for a count, the counted titles, most relevant first).
- Numbers come from history_stats or history_query totals, never from your own estimate. Dates are real viewing dates; "undated" plays were imported or marked as watched, so say so if they matter.
- "Watched last summer" means June to August of the most recent summer before today unless they say otherwise; seasons are northern hemisphere.
- For a franchise or studio ("Marvel films", "Pixar"), use the metadata first: the studio filter (e.g. "Marvel Studios" for the MCU; it can also catch non-MCU titles, so check the list), then collection. Only if those find nothing, fall back to your own knowledge of the titles with title_contains, and say the count covers what you could match.
- If the tools don't show it, say you don't know or can't find it. Never invent a title, a date or a count.
- Recommendation requests that lean on history ("something like what I loved last year") still end with show_picks; similar_titles with watched=false finds unwatched titles on the servers like one they watched.''';

  /// [previous] carries earlier turns of this conversation (request and
  /// picks), so follow-ups like "lighter" or "only films" make sense.
  ///
  /// Fork: [onProgress] hears what's happening while it runs: a short step
  /// ("Checking your history") and, as the final tool is written, its text
  /// so far (streamed).
  Future<AiAnswer> ask(
    String request, {
    List<({String request, AiAnswer answer})> previous = const [],
    void Function(AiProgress progress)? onProgress,
  }) async {
    final started = DateTime.now();
    final brain = this.brain;
    final tools = AiTools(
      index: index,
      trakt: trakt,
      history: brain == null ? null : AiHistoryTools(brain: brain, index: index),
    );
    final calls = <AiToolCall>[];
    var cost = 0.0;
    var input = 0;
    var output = 0;
    var cached = 0;
    final texts = <String>[];
    String? error;
    var modelTime = Duration.zero, toolTime = Duration.zero;
    var modelCalls = 0;
    final key = await AiKeyStore.read();
    if (key == null) {
      return _answer(tools, texts, calls, started, 0, 0, 0, 0, 'No API key; add one in Settings ▸ AI.');
    }
    final client = _client ??= ClaudeClient(key);
    final today = DateTime.now().toIso8601String().substring(0, 10);
    var taste = '';
    try {
      taste = await brain?.taste() ?? '';
    } catch (e) {
      appLogger.d('AI: no taste summary', error: e);
    }
    final messages = <Map<String, Object?>>[
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Today is $today.\n\n${_previousContext(previous)}$request'},
        ],
      },
    ];
    try {
      for (var step = 0; step < maxSteps; step++) {
        final modelStart = DateTime.now();
        final stream = StreamedMessage();
        String? streamed;
        final response = await client.streamMessage(
          {
            'model': model.id,
            'max_tokens': 16000,
            'thinking': {'type': 'adaptive'},
            'output_config': {'effort': effort},
            'system': [
              {
                'type': 'text',
                'text': brain == null ? systemPrompt : '$systemPrompt$historyPrompt',
                'cache_control': {'type': 'ephemeral'},
              },
              // Fork: their taste up front, so a recommendation needs no
              // history lookups first. Changes only after a sync.
              if (taste.isNotEmpty)
                {
                  'type': 'text',
                  'text': "The user's watching, from their history (for taste; use the tools for exact counts):\n$taste",
                  'cache_control': {'type': 'ephemeral'},
                },
            ],
            'tools': tools.definitions(),
            'messages': messages,
            // Caches the growing conversation between tool steps.
            'cache_control': {'type': 'ephemeral'},
            if (model == ClaudeModel.sonnet) 'fallbacks': 'default',
          },
          betas: model == ClaudeModel.sonnet ? const ['server-side-fallback-2026-07-01'] : const [],
          onEvent: (event) {
            stream.add(event);
            // The final tool's text, shown as it's written.
            if (event['type'] == 'content_block_delta' && (event['delta'] as Map?)?['type'] == 'input_json_delta') {
              final json = stream.partialInput(event['index'] as int);
              final text = partialJsonString(json, 'writeup') ?? partialJsonString(json, 'answer');
              if (text != null && text.isNotEmpty && text != streamed) {
                streamed = text;
                onProgress?.call(AiProgress(step: null, text: text));
              }
            } else if (event['type'] == 'content_block_start') {
              final block = event['content_block'] as Map?;
              if (block?['type'] == 'tool_use') onProgress?.call(AiProgress(step: _stepFor(block?['name'] as String?)));
            }
          },
        );
        modelTime += DateTime.now().difference(modelStart);
        modelCalls++;
        final usage = (response['usage'] as Map?)?.cast<String, dynamic>() ?? const {};
        cost += await AiSpend.record(model, usage);
        input +=
            ((usage['input_tokens'] as num?) ?? 0).toInt() +
            ((usage['cache_creation_input_tokens'] as num?) ?? 0).toInt();
        output += ((usage['output_tokens'] as num?) ?? 0).toInt();
        cached += ((usage['cache_read_input_tokens'] as num?) ?? 0).toInt();

        final content = [...(response['content'] as List? ?? const []).whereType<Map<String, dynamic>>()];
        // The whole assistant turn goes back unchanged (thinking blocks too).
        messages.add({'role': 'assistant', 'content': content});
        for (final block in content) {
          if (block['type'] == 'text' && (block['text'] as String?)?.trim().isNotEmpty == true) {
            texts.add(block['text'] as String);
          }
        }
        final stop = response['stop_reason'] as String?;
        if (stop == 'refusal') {
          error = 'The model declined this request.';
          break;
        }
        if (stop != 'tool_use') break;

        final uses = content.where((b) => b['type'] == 'tool_use').toList();
        final toolStart = DateTime.now();
        final results = await Future.wait([
          for (final use in uses)
            () async {
              final name = use['name'] as String;
              final args = (use['input'] as Map?)?.cast<String, dynamic>() ?? const {};
              String result;
              var isError = false;
              final toolStarted = DateTime.now();
              try {
                result = await tools.run(name, args);
                appLogger.d('AI: tool $name took ${DateTime.now().difference(toolStarted).inMilliseconds} ms');
              } catch (e) {
                appLogger.w('AI: tool $name failed', error: e);
                result = 'Tool failed: $e';
                isError = true;
              }
              calls.add((name: name, input: jsonEncode(args), resultChars: result.length));
              return {
                'type': 'tool_result',
                'tool_use_id': use['id'],
                'content': result,
                if (isError) 'is_error': true,
              };
            }(),
        ]);
        toolTime += DateTime.now().difference(toolStart);
        messages.add({'role': 'user', 'content': results});
        // The picks are the answer; no need for another round trip.
        if (uses.any((u) => AiTools.finalTools.contains(u['name']))) break;
      }
    } on ClaudeApiException catch (e) {
      error = e.isAuth ? 'The API key was rejected; check Settings ▸ AI.' : 'Claude API error: ${e.message}';
    } catch (e) {
      error = 'Request failed: $e';
    }
    final timing =
        'model ${(modelTime.inMilliseconds / 1000).toStringAsFixed(1)}s ($modelCalls calls), '
        'tools ${(toolTime.inMilliseconds / 1000).toStringAsFixed(1)}s, '
        'tokens $input in + $cached cached, $output out, effort $effort';
    appLogger.i(
      'AI: ${DateTime.now().toIso8601String()} ask done in '
      '${(DateTime.now().difference(started).inMilliseconds / 1000).toStringAsFixed(1)}s: $timing, '
      '${calls.length} tools, \$${cost.toStringAsFixed(4)}${error == null ? '' : ', failed'}',
    );
    return _answer(tools, texts, calls, started, cost, input, output, cached, error, timing: timing);
  }

  static String _previousContext(List<({String request, AiAnswer answer})> previous) {
    if (previous.isEmpty) return '';
    final recent = previous.length > 3 ? previous.sublist(previous.length - 3) : previous;
    final lines = [
      for (final turn in recent)
        'Earlier request: "${turn.request}" -> you picked: '
            '${turn.answer.picks.map((p) => '${p.title.title}${p.title.year == null ? '' : ' (${p.title.year})'}').join(', ')}',
    ];
    return 'This is a follow-up in the same conversation.\n${lines.join('\n')}\n'
        'New request (avoid repeating earlier picks unless asked): ';
  }

  /// The request behind the AI tab's greeting and "Tonight" picks.
  static const String tonightRequest =
      'Greet me in one short, warm sentence (as the show_picks intro) and suggest 6 to 10 things for tonight: mix '
      "finishing something I'm partway through with fresh picks that fit my recent history. Use get_history "
      'and get_continue_watching.';

  Future<AiAnswer> _answer(
    AiTools tools,
    List<String> texts,
    List<AiToolCall> calls,
    DateTime started,
    double cost,
    int input,
    int output,
    int cached,
    String? error, {
    String timing = '',
  }) async {
    final db = await index.database;
    final picks = <({IndexedTitle title, String reason})>[];
    final unknown = <String>[];
    for (final p in tools.picks) {
      final t = await (db.select(db.indexTitles)..where((r) => r.id.equals(p.id))).getSingleOrNull();
      t == null ? unknown.add(p.id) : picks.add((title: t, reason: p.reason));
    }
    return AiAnswer(
      title: tools.title,
      intro: tools.intro,
      picks: picks,
      text: texts.join('\n').trim(),
      toolCalls: calls,
      elapsed: DateTime.now().difference(started),
      cost: cost,
      inputTokens: input,
      outputTokens: output,
      cachedTokens: cached,
      unknownPickIds: unknown,
      answer: tools.answer,
      writeup: tools.writeup ?? tools.answer,
      notes: tools.notes,
      followUps: tools.followUps,
      timing: timing,
      error: error,
    );
  }

  void close() => _client?.close();
}
