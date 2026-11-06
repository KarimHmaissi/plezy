import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/services/reel/reel_volume.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

/// The native side as ExoPlayerPlugin and ExoPlayerCore have it: a new core
/// plays at ExoPlayer's default volume (full), and a `setVolume` that
/// arrives with no core (before `initialize`) is dropped
/// (`playerCore?.setVolume(...)`).
class _Plugin {
  bool core = false;
  double volume = 1.0;

  /// The core's volume at each `open` (with `autoPlay`, the clip is heard
  /// from there).
  final opened = <double>[];

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    switch (call.method) {
      case 'initialize':
        if (!core) volume = 1.0;
        core = true;
        return true;
      case 'setVolume':
        if (core) volume = (args['volume'] as num).toDouble() / 100;
        return null;
      case 'open':
        opened.add(volume);
        return null;
      case 'requestAudioFocus':
        return true;
      case 'dispose':
        core = false;
        return null;
    }
    return null;
  }
}

const _a = ClipSource(uri: 'https://s1.example/a.mp4', origin: ClipOrigin.plexExtra);
const _b = ClipSource(uri: 'https://s1.example/b.mp4', origin: ClipOrigin.plexExtra);

/// The TV's clip core is built afresh on every visit (a launch, the tab
/// shown, the Shield woken, Back from Watch, a retry). Its first clip must
/// open at the level the Reel asked for: silent while muted (every TV visit
/// starts muted), and from silence before the fade-in.
void main() {
  late _Plugin plugin;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    ReelVolume.reset();
    plugin = _Plugin();
  });

  /// [body] plays on a Reel clip player over the real clip core; the
  /// player is let go before the channels are, so the next test's core
  /// never waits on this one's.
  Future<void> withClips(Future<void> Function(ClipPlayer clips) body, {bool muted = false}) => withMockPlayerChannels(
    methodChannelName: 'com.plezy/exo_player',
    eventChannelName: 'com.plezy/exo_player/events',
    methodHandler: plugin.handle,
    testBody: () async {
      final clips = ClipPlayer(engine: ExoClipEngine.new, muted: muted);
      try {
        await body(clips);
      } finally {
        await clips.release();
      }
    },
  );

  test('a muted Reel opens its first clip on a new core silent, not at full volume', () async {
    await withClips(muted: true, (clips) async {
      await clips.play(_a, first: true);
      expect(plugin.opened, [0.0]);
      expect(plugin.volume, 0.0, reason: 'muted: nothing raises it after the open');
    });
  });

  test('every visit builds a new core, and each opens silent while muted', () async {
    await withClips(muted: true, (clips) async {
      await clips.play(_a, first: true);
      await clips.release();
      expect(plugin.core, isFalse);

      await clips.play(_b, first: true);
      expect(plugin.opened, [0.0, 0.0]);
    });
  });

  test('with sound, the first clip on a new core still opens from silence (its fade-in starts there)', () async {
    await withClips((clips) async {
      await clips.play(_a, first: true);
      expect(plugin.opened, [0.0]);
    });
  });

  /// [body] on the clip core alone, disposed before the channels go.
  Future<void> withEngine(Future<void> Function(ExoClipEngine engine) body) => withMockPlayerChannels(
    methodChannelName: 'com.plezy/exo_player',
    eventChannelName: 'com.plezy/exo_player/events',
    methodHandler: plugin.handle,
    testBody: () async {
      final engine = ExoClipEngine();
      try {
        await body(engine);
      } finally {
        await engine.dispose();
      }
    },
  );

  test('a core brought up by a preload is silent, and a Reel volume change before any ask keeps it so', () async {
    await withEngine((engine) async {
      await engine.preload(_b.uri);
      expect(plugin.volume, 0.0);
      ReelVolume.adjust(-1);
      await pumpEventQueue();
      expect(plugin.volume, 0.0);
    });
  });

  test('a level asked before the core is up is the one it comes up at', () async {
    await withEngine((engine) async {
      await engine.setVolume(40);
      expect(plugin.core, isFalse, reason: 'no core yet: the plugin dropped it');
      await engine.preload(_b.uri);
      expect(plugin.volume, 0.4);
    });
  });
}
