import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/ids.dart';
import '../../media/media_server_client.dart';
import '../../providers/companion_remote_provider.dart';
import '../../utils/app_logger.dart';
import '../trackers/trakt/trakt_client.dart';
import 'ai_agent.dart';
import 'ai_activity.dart';
import 'ai_briefing.dart';
import 'ai_history.dart';
import 'ai_key_store.dart';
import 'ai_pick_reasons.dart';
import 'ai_rows.dart';
import 'claude_client.dart';

/// Host side of the phone's AI tab: requests from a connected phone run here
/// (this app's key and library index), are saved like ones typed on the TV,
/// and the picks go back to the phone. The TV keeps whatever it's showing.
abstract final class AiRemoteAsks {
  /// The id of an answer a phone's request just saved, so an open AI tab
  /// can show it.
  static final ValueNotifier<String?> landed = ValueNotifier(null);

  static Future<void> run(
    Map<String, dynamic> data, {
    required CompanionRemoteProvider remote,
    required MediaServerClient? Function(ServerId serverId) clientFor,
    TraktClient? trakt,
  }) async {
    final rid = data['rid'] as String? ?? '';
    final request = (data['request'] as String?)?.trim() ?? '';
    // Ask about this: a written answer is the point; picks are optional.
    final about = data['about'] == true;
    void reply(String status, [Map<String, dynamic> more = const {}]) =>
        remote.sendAiAnswer({'rid': rid, 'status': status, ...more});

    if (request.isEmpty) return reply('error', {'message': 'Empty request'});
    if ((await AiKeyStore.read() ?? '').isEmpty) {
      return reply('error', {'message': 'No Anthropic API key on the TV (Settings ▸ AI)'});
    }
    reply('working');
    AiActivity.running.value++;
    try {
      // The phone shows the step and the answer as it's written, a few
      // updates a second at most.
      DateTime? lastSent;
      AiProgress? held;
      Timer? flush;
      void send(AiProgress p) => reply('working', {'step': ?p.step, 'text': ?p.text});
      final result = await buildAiRow(
        request: request,
        model: ClaudeModel.sonnet,
        clientFor: clientFor,
        trakt: trakt,
        useTitle: true,
        onProgress: (p) {
          final now = DateTime.now();
          if (lastSent == null || now.difference(lastSent!) > const Duration(milliseconds: 250)) {
            lastSent = now;
            flush?.cancel();
            send(p);
          } else {
            held = p;
            flush ??= Timer(const Duration(milliseconds: 250), () {
              flush = null;
              if (held case final h?) send(h);
            });
          }
        },
      );
      flush?.cancel();
      final entry = result.entry;
      final answer = result.answer;
      final text = (answer.intro?.trim().isNotEmpty ?? false) ? answer.intro : answer.text;
      if (entry == null) {
        if (about && answer.error == null && (text?.trim().isNotEmpty ?? false)) {
          return reply('text', {'text': text});
        }
        return reply('error', {'message': answer.error ?? answer.intro ?? 'No picks'});
      }
      await AiHistory.add(entry);
      landed.value = entry.id;
      reply('done', {...entry.toJson(), if (about) 'text': text});
    } catch (e) {
      appLogger.w('AI: request from the phone failed', error: e);
      reply('error', {'message': '$e'});
    } finally {
      AiActivity.running.value--;
    }
  }

  /// A phone's Find more / Refresh on a saved answer, run here like the AI
  /// tab's own (see `AiScreen._findMore` / `_refreshRow`); the result is
  /// saved with [AiHistory.replace], which updates the TV and, through the
  /// next snapshot, the phone.
  ///
  /// `loadMore` (the row's Load more card) appends instead, and when the
  /// phone sends a `rid` it gets an `aiAnswer` back: `done`, `none` (nothing
  /// new) or `error`.
  static Future<void> runAction(
    Map<String, dynamic> data, {
    required MediaServerClient? Function(ServerId serverId) clientFor,
    TraktClient? trakt,
    CompanionRemoteProvider? remote,
  }) async {
    final action = data['action'] as String?;
    final id = data['id'] as String?;
    final rid = data['rid'] as String?;
    // A pick's reason for the phone's peek sheet.
    if (action == 'reason') {
      final key = data['key'] as String?;
      final text = id == null || key == null ? null : await AiPickReasons.reasonFor(id, key);
      if (rid != null) remote?.sendAiAnswer({'rid': rid, 'status': text == null ? 'error' : 'done', 'text': ?text});
      return;
    }
    // Tonight's cards made afresh (the phone's pull to refresh, confirmed).
    if (action == 'tonight') {
      final entry = await AiBriefing.today(clientFor: clientFor, force: true);
      if (rid != null) remote?.sendAiAnswer({'rid': rid, 'status': entry == null ? 'error' : 'done'});
      return;
    }
    var status = 'error';
    try {
      status = await _runAction(action, id, clientFor: clientFor, trakt: trakt);
    } finally {
      if (rid != null) remote?.sendAiAnswer({'rid': rid, 'status': status});
    }
  }

  static Future<String> _runAction(
    String? action,
    String? id, {
    required MediaServerClient? Function(ServerId serverId) clientFor,
    TraktClient? trakt,
  }) async {
    final entry = id == null ? null : await AiHistory.get(id);
    if (entry == null || (await AiKeyStore.read() ?? '').isEmpty) return 'error';
    final append = action == 'loadMore';
    final extend = append || action == 'findMore';
    if (!extend && action != 'refresh') return 'error';
    AiActivity.running.value++;
    try {
      final result = await buildAiRow(
        request: entry.request,
        model: ClaudeModel.sonnet,
        clientFor: clientFor,
        trakt: trakt,
        id: entry.id,
        useTitle: entry.title != null,
        keepTitle: extend ? entry.title : null,
        sentRequest: extend ? findMoreRequest(entry) : null,
        excludeKeys: extend ? {...entry.items.map((i) => i.globalKey)} : const {},
      );
      final found = result.entry;
      if (found == null) return result.answer.error == null ? 'none' : 'error';
      final merged = extend ? mergeFindMore(entry, found, append: append) : found;
      if (extend && merged.items.length == entry.items.length) return 'none';
      await AiHistory.replace(merged);
      return 'done';
    } catch (e) {
      appLogger.w('AI: $action from the phone failed', error: e);
      return 'error';
    } finally {
      AiActivity.running.value--;
    }
  }
}
