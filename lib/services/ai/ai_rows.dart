import '../../media/ids.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../library_index/library_index.dart';
import '../trackers/trakt/trakt_client.dart';
import 'ai_agent.dart';
import 'ai_history.dart';
import 'claude_client.dart';

/// Ask the helper and turn its picks into playable items, as a saved-answer
/// entry with [id] (a new one when not given); no entry when nothing came
/// back. Used by the AI tab and by Home's auto-refresh.
Future<({AiAnswer answer, AiHistoryEntry? entry})> buildAiRow({
  required String request,
  required ClaudeModel model,
  required MediaServerClient? Function(ServerId serverId) clientFor,
  TraktClient? trakt,
  List<({String request, AiAnswer answer})> previous = const [],
  String? id,
  bool useTitle = false,
  String? keepTitle,
  String? sentRequest,
  Set<String> excludeKeys = const {},
}) async {
  final agent = AiAgent(index: LibraryIndex.instance, trakt: trakt, model: model);
  try {
    final answer = await agent.ask(sentRequest ?? request, previous: previous);
    if (answer.error != null) return (answer: answer, entry: null);
    final fetched = await Future.wait([
      for (final pick in answer.picks)
        () async {
          try {
            final item = await clientFor(ServerId(pick.title.serverId))?.fetchItem(pick.title.ratingKey);
            return item == null ? null : (item: item, reason: pick.reason);
          } catch (e) {
            appLogger.d('AI: fetching ${pick.title.title} failed', error: e);
            return null;
          }
        }(),
    ]);
    // Find more: the model is told what's already shown, but drop repeats anyway.
    final picks = [...fetched.nonNulls.where((p) => !excludeKeys.contains(p.item.globalKey))];
    // A written answer stands without cards ("you've seen 23 of them").
    if (picks.isEmpty && answer.answer == null) return (answer: answer, entry: null);
    return (
      answer: answer,
      entry: AiHistoryEntry(
        id: id ?? AiHistory.newId(),
        request: request,
        title: keepTitle ?? (useTitle ? answer.title : null),
        intro: answer.intro,
        answer: answer.answer,
        createdAt: DateTime.now(),
        items: [for (final p in picks) p.item],
        reasons: {for (final p in picks) p.item.globalKey: p.reason},
      ),
    );
  } finally {
    agent.close();
  }
}

/// The request sent for Find more: the same ask, minus the titles [entry]
/// already has, and at most [atMost] new picks when given.
String findMoreRequest(AiHistoryEntry entry, {int? atMost}) {
  final shown = entry.items.map((i) => i.year == null ? i.title : '${i.title} (${i.year})').join('; ');
  return '${entry.request}\n\n'
      'Find more: the user already has these picks for this request and wants different titles that fit it '
      'just as well. Do not repeat any of them: $shown.${atMost == null ? '' : ' Return $atMost picks at most.'} '
      'If nothing else genuinely fits, call show_picks with no picks.';
}

/// [found]'s new picks first, then [old]'s, without repeats, capped at
/// [AiHistory.maxItemsPerEntry]. Keeps the answer's name and intro, and its
/// age unless [createdAt] is given (auto-refresh restarts the clock).
/// [append] puts the new picks after the old ones instead (Load more).
AiHistoryEntry mergeFindMore(AiHistoryEntry old, AiHistoryEntry found, {DateTime? createdAt, bool append = false}) {
  final seen = <String>{};
  final items = [
    for (final item in append ? [...old.items, ...found.items] : [...found.items, ...old.items])
      if (seen.add(item.globalKey)) item,
  ].take(AiHistory.maxItemsPerEntry).toList();
  return AiHistoryEntry(
    id: old.id,
    request: old.request,
    title: old.title,
    intro: old.intro,
    answer: old.answer,
    createdAt: createdAt ?? old.createdAt,
    items: items,
    reasons: {...old.reasons, ...found.reasons},
    extended: true,
  );
}
