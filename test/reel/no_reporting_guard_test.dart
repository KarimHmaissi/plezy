import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Clips never report watch state (Reel spec §8): no timeline, scrobble,
/// tracker, Discord, OS media session or local history. Four layers:
/// 1. the clip playback path (what runs while a clip plays) reaches none of
///    the reporting modules, nor the Plex client, through ANY chain of
///    imports;
/// 2. every other Reel file is a root too (V2-62): it may reach them only
///    through one of the known benign exits in [_benignExits];
/// 3. no Reel file imports any of them directly (the Reel reaches servers
///    only through the narrow `ReelServers` seam, and Watch, which is a real
///    play, is a callback the app hands in);
/// 4. no Reel source names a timeline or scrobble call.
/// reel_seam_test.dart checks the same at run time: a Reel session calls
/// only extras, clipUrl and fetchItem on a server.
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

/// Imports from a Reel file into app code that reaches a reporting module
/// (or the Plex client) further down, each read and found benign: the Reel
/// uses that module for something else, and none of its calls report.
/// Every other exit from the Reel into such code fails the guard. An entry
/// that no longer leads to reporting code must be removed.
const _benignExits = {
  // A server's client for card art (`tryGetMediaClientWithFallback`): the
  // image helper builds a URL from it and calls nothing on the server.
  'lib/screens/reel/reel_card_view.dart → lib/utils/provider_extensions.dart',
  'lib/screens/reel/reel_decide_view.dart → lib/utils/provider_extensions.dart',
  'lib/screens/reel/reel_feed_view.dart → lib/utils/provider_extensions.dart',
  'lib/screens/reel/reel_remote_view.dart → lib/utils/provider_extensions.dart',
  // On TV mode's link between the phone and the TV: it carries Reel steps
  // and actions, never a timeline.
  'lib/screens/reel/reel_remote_view.dart → lib/providers/companion_remote_provider.dart',
  'lib/screens/reel/reel_screen.dart → lib/providers/companion_remote_provider.dart',
  // The Reel's settings page: its tiles reach the app's settings plumbing.
  'lib/screens/reel/reel_screen.dart → lib/screens/settings/reel_settings_screen.dart',
  // The Decks screen loads the deck list through ReelApp, the app glue that
  // also hands Watch over to real playback, which reports as a play should.
  'lib/screens/reel/reel_sheet.dart → lib/screens/settings/reel_decks_screen.dart',
  // Read-only facts for decks and cards: the day's AI briefing picks, the
  // local history and the library index's titles and seen state.
  'lib/services/reel/reel_decks.dart → lib/services/ai/ai_briefing.dart',
  // The AI page's saved suggestion lists (`AiSuggestions.cached`), read as
  // For You candidates (V2-41).
  'lib/services/reel/reel_decks.dart → lib/services/ai/ai_suggestions.dart',
  'lib/services/reel/reel_decks.dart → lib/services/ai/facts/title_facts.dart',
  'lib/services/reel/reel_decks.dart → lib/services/brain/history_brain.dart',
  'lib/services/reel/reel_library.dart → lib/services/ai/facts/index_title_facts_source.dart',
  'lib/services/reel/reel_library.dart → lib/services/ai/facts/title_facts.dart',
  // A month's name for the daily build's "last watched" facts.
  'lib/services/reel/reel_pool.dart → lib/services/ai/facts/seen_state.dart',
};

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

  /// Every import from a Reel file into app code, with the reporting
  /// modules it leads to and one chain that gets there.
  Map<String, ({Set<String> reaches, String chain})> exitsToReporting() {
    final reel = _reelFiles().toSet();
    final exits = <String, ({Set<String> reaches, String chain})>{};
    final graphs = <String, Map<String, List<String>>>{};
    for (final f in reel) {
      for (final to in _importsOf(f)) {
        if (reel.contains(to)) continue;
        final graph = graphs[to] ??= reachable([to]);
        final hits = _forbidden.where(graph.containsKey).toSet();
        if (hits.isEmpty) continue;
        exits['$f → $to'] = (reaches: hits, chain: [f, ...graph[hits.first]!].join(' → '));
      }
    }
    return exits;
  }

  late final exits = exitsToReporting();

  test('every Reel file reaches reporting code only through a known benign exit', () {
    final files = _reelFiles();
    expect(files, containsAll(['lib/services/reel/reel_controller.dart', 'lib/screens/reel/reel_screen.dart']));
    // Any chain from a Reel file to a reporting module leaves the Reel for
    // the last time through one of these exits, so checking each exit
    // covers every chain from every Reel file.
    final leaks = [
      for (final MapEntry(key: exit, value: (:reaches, :chain)) in exits.entries)
        if (!_benignExits.contains(exit)) '$exit reaches ${reaches.join(', ')}\n  $chain',
    ];
    expect(leaks, isEmpty, reason: leaks.join('\n'));
  });

  test('the benign exits are all still live', () {
    final live = exits.keys.toSet();
    final stale = _benignExits.difference(live);
    expect(stale, isEmpty, reason: 'no longer leads to reporting code; remove it:\n${stale.join('\n')}');
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
