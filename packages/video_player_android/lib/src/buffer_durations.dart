// PLEZY DELTA: this whole file is a Plezy addition to the vendored package (see its README),
// under the package's own BSD-style license (LICENSE).

import 'package:flutter/foundation.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// How much media3 buffers ahead, in milliseconds: the four values of
/// `DefaultLoadControl.Builder.setBufferDurationsMs`.
///
/// media3 loads until [maxBufferMs] is buffered, then waits until the buffer
/// drops under [minBufferMs] before loading again. Playback starts once
/// [bufferForPlaybackMs] is buffered, and resumes after a stall once
/// [bufferForPlaybackAfterRebufferMs] is. The constructor asserts the same
/// order media3 checks, so a bad set fails here rather than in the open.
@immutable
class BufferDurationsMs {
  const BufferDurationsMs({
    required this.minBufferMs,
    required this.maxBufferMs,
    required this.bufferForPlaybackMs,
    required this.bufferForPlaybackAfterRebufferMs,
  }) : assert(bufferForPlaybackMs >= 0, 'bufferForPlaybackMs must be at least 0'),
       assert(
         bufferForPlaybackAfterRebufferMs >= 0,
         'bufferForPlaybackAfterRebufferMs must be at least 0',
       ),
       assert(
         minBufferMs >= bufferForPlaybackMs,
         'minBufferMs must be at least bufferForPlaybackMs',
       ),
       assert(
         minBufferMs >= bufferForPlaybackAfterRebufferMs,
         'minBufferMs must be at least bufferForPlaybackAfterRebufferMs',
       ),
       assert(maxBufferMs >= minBufferMs, 'maxBufferMs must be at least minBufferMs');

  final int minBufferMs;
  final int maxBufferMs;
  final int bufferForPlaybackMs;
  final int bufferForPlaybackAfterRebufferMs;

  @override
  bool operator ==(Object other) =>
      other is BufferDurationsMs &&
      other.minBufferMs == minBufferMs &&
      other.maxBufferMs == maxBufferMs &&
      other.bufferForPlaybackMs == bufferForPlaybackMs &&
      other.bufferForPlaybackAfterRebufferMs == bufferForPlaybackAfterRebufferMs;

  @override
  int get hashCode =>
      Object.hash(minBufferMs, maxBufferMs, bufferForPlaybackMs, bufferForPlaybackAfterRebufferMs);

  @override
  String toString() =>
      'BufferDurationsMs($minBufferMs, $maxBufferMs, $bufferForPlaybackMs, $bufferForPlaybackAfterRebufferMs)';
}

/// [VideoPlayerOptions] that also carry [bufferDurationsMs] for this one
/// player. `video_player` hands its options to the platform unchanged, so a
/// controller built with these gets its own load control on Android, and
/// every other player keeps media3's defaults. Other platforms ignore it.
class AndroidBufferedVideoPlayerOptions extends VideoPlayerOptions {
  // ignore: prefer_const_constructors_in_immutables
  AndroidBufferedVideoPlayerOptions({
    required this.bufferDurationsMs,
    super.mixWithOthers,
    super.allowBackgroundPlayback,
    super.preventsDisplaySleepDuringVideoPlayback,
    super.webOptions,
    super.backBufferDurationMs,
  });

  final BufferDurationsMs bufferDurationsMs;
}
