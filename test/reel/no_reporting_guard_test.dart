import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Clips never report watch state (Reel spec §8): no timeline, scrobble,
/// tracker, Discord, OS media session or local history. Three layers:
/// 1. the clip playback path (what runs while a clip plays) reaches none of
///    the reporting modules, nor the Plex client, through ANY chain of
///    imports;
/// 2. no Reel file imports any of them directly (the Reel reaches servers
///    only through the narrow `ReelServers` seam, and Watch, which is a real
///    play, is a callback the app hands in);
/// 3. no Reel source names a timeline or scrobble call.
/// The live check (viewOffset / On Deck unchanged after clips) is the proof
/// on the device; this keeps a future edit from quietly wiring reporting in.
const _forbidden = {
  'lib/services/playback_progress_tracker.dart',
  'lib/services/trackers/tracker_coordinator.dart',
  'lib/services/discord_rpc_service.dart',
  'lib/services/media_controls_manager.dart',
  'lib/services/local_playback_history.dart',
  'lib/screens/video_player/companion_remote_binding.dart',
  'lib/screens/video_player_screen.dart',
  'lib/utils/video_player_navigation.dart',
  // The Plex client also sends timelines and scrobbles.
  'lib/services/plex_client.dart',
};

/// What runs while a clip plays.
const _clipPath = [
  'lib/services/reel/clip_player.dart',
  'lib/services/reel/clip_filter.dart',
  // The phone feed's players.
  'lib/services/reel/feed_players.dart',
];

List<String> _reelFiles() => [
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

Iterable<String> _importsOf(String file) sync* {
  for (final m in _import.allMatches(File(file).readAsStringSync())) {
    final to = _resolve(file, m.group(1)!);
    if (to != null && File(to).existsSync()) yield to;
  }
}

/// Every app file reachable from [roots], with the chain that reached it.
Map<String, List<String>> reachable(Iterable<String> roots) {
  final chain = <String, List<String>>{};
  final queue = <String>[];
  for (final r in roots) {
    chain[r] = [r];
    queue.add(r);
  }
  while (queue.isNotEmpty) {
    final f = queue.removeLast();
    for (final to in _importsOf(f)) {
      if (chain.containsKey(to)) continue;
      chain[to] = [...chain[f]!, to];
      queue.add(to);
    }
  }
  return chain;
}

void main() {
  test('the clip playback path reaches no reporting code through any import chain', () {
    for (final r in _clipPath) {
      expect(File(r).existsSync(), isTrue, reason: '$r is a guard root');
    }
    final graph = reachable(_clipPath);
    final leaks = {
      for (final f in _forbidden)
        if (graph[f] case final chain?) f: chain.join(' → '),
    };
    expect(leaks, isEmpty, reason: leaks.values.join('\n'));
  });

  test('no Reel file imports reporting code or the Plex client', () {
    final files = _reelFiles();
    expect(files, contains('lib/services/reel/clip_player.dart'));
    final direct = [
      for (final f in files)
        for (final to in _importsOf(f))
          if (_forbidden.contains(to)) '$f → $to',
    ];
    expect(direct, isEmpty, reason: direct.join('\n'));
  });

  test('no Reel source names a timeline or scrobble call', () {
    final bad = RegExp(
      r'timeline|scrobble|updateProgress|markWatched|markAsWatched|reportPlayback',
      caseSensitive: false,
    );
    final hits = [
      for (final f in _reelFiles())
        for (final (i, line) in File(f).readAsLinesSync().indexed)
          if (!line.trimLeft().startsWith('//') && bad.hasMatch(line)) '$f:${i + 1}: ${line.trim()}',
    ];
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  test('the guard sees a leak when one exists', () {
    final graph = reachable(['lib/screens/video_player_screen.dart']);
    expect(graph.keys.toSet().intersection(_forbidden), isNotEmpty);
  });
}
