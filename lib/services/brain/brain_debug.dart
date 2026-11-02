import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:plezy_brain/plezy_brain.dart';

import '../ai/ai_agent.dart';
import '../library_index/library_index.dart';
import 'history_brain.dart';

/// Fork, debug builds only: `ext.plezy.brain` reports on the history brain
/// and runs raw queries against it, for checking quality by hand.
///
/// Params: `op` = `status` | `sync` | `embed` (`q`, `query`) | `ask` (`q`) | `search` (`q`, optional `watched`,
/// `kind`) | `similar` (`id` or `title`, optional `watched`) | `profile`
/// (`id`); `limit`.
abstract final class BrainDebug {
  static const extensionName = 'ext.plezy.brain';
  static bool _registered = false;

  static void register() {
    if (kReleaseMode || _registered) return;
    _registered = true;
    developer.registerExtension(extensionName, (_, params) async {
      try {
        return developer.ServiceExtensionResponse.result(jsonEncode(await _run(params)));
      } catch (e) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          e.runtimeType.toString(),
        );
      }
    });
  }

  static Future<Map<String, Object?>> _run(Map<String, String> params) async {
    final brain = HistoryBrain.instance;
    final limit = int.tryParse(params['limit'] ?? '') ?? 10;
    bool? flag(String key) => switch (params[key]) {
      'true' => true,
      'false' => false,
      _ => null,
    };
    final kind = switch (params['kind']) {
      'movie' => TitleKind.movie,
      'show' => TitleKind.show,
      _ => null,
    };
    Map<String, Object?> hit(({TitleProfile profile, double score}) h) => {
      'id': h.profile.id,
      'title': h.profile.title,
      'year': h.profile.year,
      'kind': h.profile.kind.name,
      'watched': h.profile.watched,
      'score': double.parse(h.score.toStringAsFixed(3)),
    };
    switch (params['op']) {
      case 'sync':
        final r = await brain.sync(force: true);
        return r == null
            ? {'error': 'noHistory'}
            : {
                'titles': r.titles,
                'watched': r.watched,
                'changed': r.changed,
                'embedded': r.embedded,
                'remaining': r.remaining,
                'traktRequests': r.traktRequests,
                'dbBytes': r.dbBytes,
                'seconds': r.took.inMilliseconds / 1000,
              };
      case 'search':
        final hits = await brain.searchText(params['q'] ?? '', limit: limit, watched: flag('watched'), kind: kind);
        return {'hits': hits.map(hit).toList()};
      case 'similar':
        var id = params['id'];
        if (id == null && params['title'] != null) {
          final want = params['title']!.toLowerCase();
          id = (await brain.store).profiles().where((p) => p.title.toLowerCase() == want).firstOrNull?.id;
        }
        if (id == null) return {'error': 'notFound'};
        final hits = await brain.similar(id, limit: limit, watched: flag('watched'), kind: kind);
        return {'of': id, 'hits': hits.map(hit).toList()};
      case 'embed':
        // Compare against a reference implementation: the first dimensions.
        final e = await brain.embedder;
        final v = (await e.embed([params['q'] ?? ''], query: params['query'] == 'true')).single;
        return {'head': [for (final x in v.take(6)) double.parse(x.toStringAsFixed(4))]};
      case 'ask':
        // The real helper, answer not saved: for checking history questions.
        final agent = AiAgent(index: LibraryIndex.instance);
        try {
          final a = await agent.ask(params['q'] ?? '');
          return {
            'error': a.error,
            'title': a.title,
            'answer': a.answer,
            'intro': a.intro,
            'writeup': a.writeup,
            'notes': a.notes,
            'followUps': a.followUps,
            'timing': a.timing,
            'cards': [for (final p in a.picks) '${p.title.title} (${p.title.year}): ${p.reason}'],
            'unknownIds': a.unknownPickIds.length,
            'tools': [for (final c in a.toolCalls) '${c.name} ${c.input}'],
            'seconds': a.elapsed.inMilliseconds / 1000,
            'dollars': double.parse(a.cost.toStringAsFixed(4)),
          };
        } finally {
          agent.close();
        }
      case 'profile':
        return (await brain.profile(params['id'] ?? ''))?.toJson() ?? {'error': 'notFound'};
      default:
        final s = brain.status.value;
        return {
          'phase': s.phase.name,
          'profiles': s.profiles,
          'watched': s.watched,
          'vectors': s.vectors,
          'error': s.error,
          'lastSync': s.lastSync?.toIso8601String(),
        };
    }
  }
}
