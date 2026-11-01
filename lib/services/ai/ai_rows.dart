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
    final picks = [...fetched.nonNulls];
    if (picks.isEmpty) return (answer: answer, entry: null);
    return (
      answer: answer,
      entry: AiHistoryEntry(
        id: id ?? AiHistory.newId(),
        request: request,
        title: keepTitle ?? (useTitle ? answer.title : null),
        intro: answer.intro,
        createdAt: DateTime.now(),
        items: [for (final p in picks) p.item],
        reasons: {for (final p in picks) p.item.globalKey: p.reason},
      ),
    );
  } finally {
    agent.close();
  }
}
