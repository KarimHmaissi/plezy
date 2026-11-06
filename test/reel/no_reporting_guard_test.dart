import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Clips never report watch state (Reel spec §8): no timeline, scrobble,
/// tracker, Discord, OS media session or local history. This walks the
/// TRANSITIVE import graph from the Reel's own code and fails if any of the
/// modules that report can be reached, so a future import can't quietly
/// wire reporting in.
const _forbidden = {
  'lib/services/playback_progress_tracker.dart',
  'lib/services/trackers/tracker_coordinator.dart',
  'lib/services/discord_rpc_service.dart',
  'lib/services/media_controls_manager.dart',
  'lib/services/local_playback_history.dart',
  'lib/screens/video_player/companion_remote_binding.dart',
  'lib/screens/video_player_screen.dart',
};

/// Everything the Reel owns. Watch (a real play, which does report) is
/// handed to the app through a callback, so nothing here imports the player.
List<String> _roots() => [
  for (final dir in ['lib/screens/reel', 'lib/services/reel'])
    if (Directory(dir).existsSync())
      for (final f in Directory(dir).listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart')) p.normalize(f.path),
]..sort();

final _import = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

String? _resolve(String fromFile, String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:plezy/')) return p.normalize('lib/${uri.substring('package:plezy/'.length)}');
  if (uri.startsWith('package:')) return null; // other packages can't import the app
  return p.normalize(p.join(p.dirname(fromFile), uri));
}

/// Every app file reachable from [roots], with the chain that reached it.
Map<String, List<String>> reachable(Iterable<String> roots) {
  final chain = <String, List<String>>{};
  final queue = <String>[];
  for (final r in roots) {
    if (File(r).existsSync()) {
      chain[r] = [r];
      queue.add(r);
    }
  }
  while (queue.isNotEmpty) {
    final f = queue.removeLast();
    final src = File(f).readAsStringSync();
    for (final m in _import.allMatches(src)) {
      final to = _resolve(f, m.group(1)!);
      if (to == null || chain.containsKey(to) || !File(to).existsSync()) continue;
      chain[to] = [...chain[f]!, to];
      queue.add(to);
    }
  }
  return chain;
}

void main() {
  test('the clip player reaches none of the reporting code', () {
    final roots = _roots();
    expect(roots, contains('lib/services/reel/clip_player.dart'), reason: 'the clip player is a guard root');
    final graph = reachable(roots);
    final leaks = {
      for (final f in _forbidden)
        if (graph[f] case final chain?) f: chain.join(' → '),
    };
    expect(leaks, isEmpty, reason: 'clip code must not import reporting code:\n${leaks.values.join('\n')}');
  });

  test('the guard sees a leak when one exists', () {
    // The real player screen does reach reporting code, so the walker works.
    final graph = reachable(['lib/screens/video_player_screen.dart']);
    expect(graph.keys.toSet().intersection(_forbidden), isNotEmpty);
  });
}
