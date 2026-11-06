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
}
