import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

/// The clip core's preload ranks cross the channel by name (V2-09):
/// `ExoPlayerPlugin` maps `rank` to `ClipPreloadRank.fromWire`, and a call
/// with no rank is the next card.
Future<List<MethodCall>> _calls(Future<void> Function(PlayerAndroid player) body) async {
  final calls = <MethodCall>[];
  await withMockPlayerChannels(
    methodChannelName: 'com.plezy/exo_player',
    eventChannelName: 'com.plezy/exo_player/events',
    methodHandler: (call) async {
      calls.add(call);
      return call.method == 'initialize' ? true : null;
    },
    testBody: () async {
      final player = PlayerAndroid(clipMode: true);
      try {
        await body(player);
      } finally {
        await player.dispose();
      }
    },
  );
  return calls.where((c) => c.method == 'preloadClip' || c.method == 'clearPreloads').toList();
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
}
