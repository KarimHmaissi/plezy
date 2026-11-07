import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

/// The clip core's preload ranks cross the channel by name (V2-09):
/// `ExoPlayerPlugin` maps `rank` to `ClipPreloadRank.fromWire`, and a call
/// with no rank is the next card.
Future<List<MethodCall>> _calls(Future<void> Function(PlayerAndroid player) body) async {
  final calls = await _allCalls(body);
  return calls.where((c) => c.method == 'preloadClip' || c.method == 'clearPreloads').toList();
}

Future<List<MethodCall>> _allCalls(Future<void> Function(PlayerAndroid player) body, {bool clipMode = true}) async {
  final calls = <MethodCall>[];
  await withMockPlayerChannels(
    methodChannelName: 'com.plezy/exo_player',
    eventChannelName: 'com.plezy/exo_player/events',
    methodHandler: (call) async {
      calls.add(call);
      return call.method == 'initialize' ? true : null;
    },
    testBody: () async {
      final player = PlayerAndroid(clipMode: clipMode);
      try {
        await body(player);
      } finally {
        await player.dispose();
      }
    },
  );
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  test('a preload names its rank and origin', () async {
    final calls = await _calls((p) async {
      await p.preloadClip('https://clips.example/a.mp4');
      await p.preloadClip('https://clips.example/b.webm', rank: 'deckNext', origin: 'animeTheme');
    });
    expect(calls.map((c) => c.arguments), [
      {'uri': 'https://clips.example/a.mp4', 'rank': 'next'},
      {'uri': 'https://clips.example/b.webm', 'rank': 'deckNext', 'origin': 'animeTheme'},
    ]);
  });

  test('a clear names its rank, or none for every rank', () async {
    final calls = await _calls((p) async {
      await p.preloadClip('https://clips.example/a.mp4');
      await p.clearPreloads(rank: 'previous');
      await p.clearPreloads();
    });
    expect(calls.skip(1).map((c) => c.arguments), [
      {'rank': 'previous'},
      <String, Object?>{},
    ]);
  });

  // V2-10: a Plex clip's disk cache key rides on its preload and its open;
  // AnimeThemes clips and the main player never send one.
  const key = 'plex:server-a:/library/parts/41/1700000000/file.mp4';
  const plex = 'https://server-a.invalid/library/parts/41/1700000000/file.mp4?X-Plex-Token=abc123';

  test('a Plex clip sends its cache key with its preload and its open', () async {
    final calls = await _allCalls((p) async {
      await p.preloadClip(plex, rank: 'ahead', origin: 'plexExtra', cacheKey: key);
      await p.preloadClip('https://clips.example/b.webm', rank: 'deckNext', origin: 'animeTheme');
      await p.open(const Media(plex));
      await p.open(const Media('https://clips.example/b.webm'));
    });
    final preloads = calls.where((c) => c.method == 'preloadClip').map((c) => c.arguments as Map).toList();
    expect(preloads[0], {'uri': plex, 'rank': 'ahead', 'origin': 'plexExtra', 'cacheKey': key});
    expect(preloads[1].containsKey('cacheKey'), isFalse);
    final opens = calls.where((c) => c.method == 'open').map((c) => c.arguments as Map).toList();
    expect(opens[0]['cacheKey'], key);
    expect(opens[1].containsKey('cacheKey'), isFalse);
  });

  test('a key remembered for an open goes with that clip only', () async {
    final calls = await _allCalls((p) async {
      p.rememberClipCacheKey(plex, key);
      await p.open(const Media(plex));
    });
    expect(calls.firstWhere((c) => c.method == 'open').arguments['cacheKey'], key);
  });

  test('the main player never sends a cache key', () async {
    final calls = await _allCalls((p) async {
      p.rememberClipCacheKey(plex, key);
      await p.open(const Media(plex));
    }, clipMode: false);
    expect((calls.firstWhere((c) => c.method == 'open').arguments as Map).containsKey('cacheKey'), isFalse);
  });

  // V2-23: a clip's lead-in crosses the channel with its preload and its
  // open; the core's answer comes back keyed by the cache key, never the URL.
  group('lead-in', () {
    test('a preload and an open carry the start and the measure flag; unknown sends no start', () async {
      final calls = await _allCalls((p) async {
        await p.setLeadInPolicy(enabled: true, measureOnly: false);
        await p.preloadClip(plex, rank: 'next', origin: 'plexExtra', cacheKey: key, startMs: 6006, measure: true);
        await p.preloadClip('https://clips.example/b.webm', origin: 'animeTheme', measure: false);
        p.rememberClipStart(plex, startMs: 6006, measure: true, origin: 'plexExtra');
        await p.open(const Media(plex));
        p.rememberClipStart(plex, measure: true, origin: 'plexExtra');
        await p.open(const Media(plex));
      });
      expect(calls.firstWhere((c) => c.method == 'setLeadInPolicy').arguments, {'enabled': true, 'measureOnly': false});
      final preloads = calls.where((c) => c.method == 'preloadClip').map((c) => c.arguments as Map).toList();
      expect(preloads[0]['startMs'], 6006);
      expect(preloads[0]['measure'], isTrue);
      expect(preloads[1].containsKey('startMs'), isFalse);
      expect(preloads[1]['measure'], isFalse);
      final opens = calls.where((c) => c.method == 'open').map((c) => c.arguments as Map).toList();
      expect(opens[0]['clipStartMs'], 6006);
      expect(opens[0]['measureLeadIn'], isTrue);
      expect(opens[0]['origin'], 'plexExtra');
      expect(opens[1].containsKey('clipStartMs'), isFalse, reason: 'unknown is never "from 0"');
    });

    test("the core's answer reaches leadIns with whether it was for the clip playing unclipped", () async {
      await _allCalls((p) async {
        final heard = <ReelLeadInEvent>[];
        final sub = p.leadIns.listen(heard.add);
        p.handlePlayerEvent('reel-lead-in', {
          'cacheKey': key,
          'startMs': 6006,
          'kind': 'coloured',
          'ver': 1,
          'reason': 'ok',
          'playingUnclipped': true,
        });
        p.handlePlayerEvent('reel-lead-in', {'cacheKey': key, 'startMs': 4004});
        p.handlePlayerEvent('reel-lead-in', {'startMs': 4004});
        await pumpEventQueue();
        await sub.cancel();
        expect(heard, hasLength(2), reason: 'an answer with no cache key is dropped');
        expect(heard[0], (
          cacheKey: key,
          startMs: 6006,
          kind: 'coloured',
          version: 1,
          reason: 'ok',
          playingUnclipped: true,
        ));
        expect(heard[1].playingUnclipped, isFalse);
        expect(heard[1].reason, 'ok');
      });
    });
  });
}
