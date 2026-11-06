import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/feed_players.dart';
import 'package:video_player_android/video_player_android.dart';
// The vendored plugin's own Pigeon messages: the test reads the create call
// exactly as the Android side would decode it.
// ignore: implementation_imports
import 'package:video_player_android/src/messages.g.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const _pluginApi = 'dev.flutter.pigeon.video_player_android.AndroidVideoPlayerApi';
const _instanceApi = 'dev.flutter.pigeon.video_player_android.VideoPlayerInstanceApi';
const _events = 'dev.flutter.pigeon.video_player_android.VideoEventChannel.videoEvents';
const _playerId = 7;

/// Answers the vendored plugin's channels the way the Android side would, and
/// keeps every create call it decodes.
class _FakeAndroidSide {
  _FakeAndroidSide() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = AndroidVideoPlayerApi.pigeonChannelCodec;
    void answer(String channel, Object? Function(List<Object?> args) reply) {
      messenger.setMockMessageHandler(channel, (ByteData? message) async {
        final args = (codec.decodeMessage(message) as List<Object?>?) ?? const <Object?>[];
        return codec.encodeMessage(<Object?>[reply(args)]);
      });
    }

    answer('$_pluginApi.initialize', (_) => null);
    answer('$_pluginApi.setMixWithOthers', (_) => null);
    answer('$_pluginApi.dispose', (_) => null);
    answer('$_pluginApi.createForTextureView', (args) {
      created.add(args.single! as CreationOptions);
      return TexturePlayerIds(playerId: _playerId, textureId: 70);
    });
    for (final m in ['setLooping', 'setVolume', 'setPlaybackSpeed', 'play', 'pause', 'seekTo']) {
      answer('$_instanceApi.$m.$_playerId', (_) => null);
    }
    for (final m in ['getCurrentPosition', 'getBufferedPosition']) {
      answer('$_instanceApi.$m.$_playerId', (_) => 0);
    }
    messenger.setMockStreamHandler(
      const EventChannel('$_events.$_playerId', pigeonMethodCodec),
      MockStreamHandler.inline(
        onListen: (_, events) =>
            events.success(InitializationEvent(duration: 30000, width: 1280, height: 720, rotationCorrection: 0)),
      ),
    );
  }

  final created = <CreationOptions>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('feed players buffer like the TV clip core (V2-08 step 2)', () {
    test('the durations are the clip core numbers', () {
      expect(
        FeedBuffer.durations,
        const BufferDurationsMs(
          minBufferMs: 2500,
          maxBufferMs: 12000,
          bufferForPlaybackMs: 500,
          bufferForPlaybackAfterRebufferMs: 1500,
        ),
      );
    });

    test('and stay equal to LoadControlPolicy.kt CLIP_* if either changes', () {
      final kotlin = File(
        'android/app/src/main/kotlin/com/edde746/plezy/exoplayer/LoadControlPolicy.kt',
      ).readAsStringSync();
      int clip(String name) {
        final m = RegExp('const val $name = ([0-9_]+)').firstMatch(kotlin);
        expect(m, isNotNull, reason: '$name is in LoadControlPolicy.kt');
        return int.parse(m!.group(1)!.replaceAll('_', ''));
      }

      expect(FeedBuffer.durations.minBufferMs, clip('CLIP_MIN_BUFFER_MS'));
      expect(FeedBuffer.durations.maxBufferMs, clip('CLIP_MAX_BUFFER_MS'));
      expect(FeedBuffer.durations.bufferForPlaybackMs, clip('CLIP_BUFFER_FOR_PLAYBACK_MS'));
      expect(FeedBuffer.durations.bufferForPlaybackAfterRebufferMs, clip('CLIP_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS'));
    });

    test('every feed player is built with them, whatever the sound setting', () {
      for (final mix in [false, true]) {
        final options = feedPlayerOptions(mixWithOthers: mix);
        expect(options, isA<AndroidBufferedVideoPlayerOptions>());
        expect((options as AndroidBufferedVideoPlayerOptions).bufferDurationsMs, FeedBuffer.durations);
        expect(options.mixWithOthers, mix);
        // The back buffer stays media3's default (none).
        expect(options.backBufferDurationMs, isNull);
      }
    });

    test('a feed player hands all four to the Android plugin when it opens', () async {
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = AndroidVideoPlayer();
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final android = _FakeAndroidSide();

      final video = PluginFeedVideo(Uri.parse('https://example.com/harbor-lights.mp4'));
      await video.initialize();

      expect(video.failed, isFalse);
      expect(video.ready, isTrue);
      expect(android.created, hasLength(1));
      final sent = android.created.single;
      expect(sent.uri, 'https://example.com/harbor-lights.mp4');
      expect(sent.minBufferMs, 2500);
      expect(sent.maxBufferMs, 12000);
      expect(sent.bufferForPlaybackMs, 500);
      expect(sent.bufferForPlaybackAfterRebufferMs, 1500);
      expect(sent.backBufferDurationMs, isNull);

      await video.dispose();
    });

    test('a plain video_player controller still opens with media3 defaults', () async {
      // Anything outside the feed that builds a controller without the
      // buffered options sends no durations, so the plugin keeps media3's
      // default load control for it.
      final previous = VideoPlayerPlatform.instance;
      final platform = AndroidVideoPlayer();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final android = _FakeAndroidSide();

      await platform.init();
      final id = await platform.createWithOptions(
        VideoCreationOptions(
          dataSource: DataSource(sourceType: DataSourceType.network, uri: 'https://example.com/b.mp4'),
          viewType: VideoViewType.textureView,
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        ),
      );

      expect(id, _playerId);
      final sent = android.created.single;
      expect(sent.minBufferMs, isNull);
      expect(sent.maxBufferMs, isNull);
      expect(sent.bufferForPlaybackMs, isNull);
      expect(sent.bufferForPlaybackAfterRebufferMs, isNull);
      await platform.dispose(_playerId);
    });
  });
}
