// PLEZY DELTA: this whole file is a Plezy addition to the vendored package (see its README),
// under the package's own BSD-style license (LICENSE).

package io.flutter.plugins.videoplayer;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultLoadControl;
import io.flutter.Log;

/**
 * Builds the one load control a player gets from its options: upstream's back buffer, and the
 * buffer durations (media3's {@code DefaultLoadControl.Builder.setBufferDurationsMs}). Without
 * either, the player keeps media3's own default load control, exactly as upstream.
 */
public final class PlezyLoadControl {
  /** The logcat tag of the line each player built with buffer durations logs. */
  public static final String TAG = "PlezyLoadControl";

  private PlezyLoadControl() {}

  /** Copies the four buffer durations from a create call onto a player's options. */
  public static void copyBufferDurations(
      @NonNull CreationOptions creation, @NonNull VideoPlayerOptions options) {
    Long min = creation.getMinBufferMs();
    Long max = creation.getMaxBufferMs();
    Long forPlayback = creation.getBufferForPlaybackMs();
    Long afterRebuffer = creation.getBufferForPlaybackAfterRebufferMs();
    boolean any = min != null || max != null || forPlayback != null || afterRebuffer != null;
    boolean all = min != null && max != null && forPlayback != null && afterRebuffer != null;
    if (any && !all) {
      throw new IllegalArgumentException("buffer durations must be set all together or not at all");
    }
    options.minBufferMs = toMs(min, "minBufferMs");
    options.maxBufferMs = toMs(max, "maxBufferMs");
    options.bufferForPlaybackMs = toMs(forPlayback, "bufferForPlaybackMs");
    options.bufferForPlaybackAfterRebufferMs =
        toMs(afterRebuffer, "bufferForPlaybackAfterRebufferMs");
  }

  /**
   * The load control for {@code options}, or null to keep media3's default. Upstream's back buffer
   * checks are kept as they were: a negative value throws, and zero means none.
   */
  @OptIn(markerClass = UnstableApi.class)
  @Nullable
  public static DefaultLoadControl build(@NonNull VideoPlayerOptions options) {
    DefaultLoadControl.Builder builder = null;
    if (options.backBufferDurationMs != null) {
      if (options.backBufferDurationMs < 0) {
        throw new IllegalArgumentException("backBufferDurationMs must be at least 0");
      }
      if (options.backBufferDurationMs > 0) {
        // Clamp the value to ensure it fits within the int range expected by
        // DefaultLoadControl.
        int backBufferInt =
            (int) Math.min(options.backBufferDurationMs.longValue(), Integer.MAX_VALUE);
        builder = new DefaultLoadControl.Builder();
        builder.setBackBuffer(backBufferInt, /* retainBackBufferFromKeyframe= */ true);
      }
    }
    if (options.hasBufferDurations()) {
      if (builder == null) {
        builder = new DefaultLoadControl.Builder();
      }
      // media3 checks the order itself: playback and rebuffer at least 0 and at most the
      // minimum, and the maximum at least the minimum.
      builder.setBufferDurationsMs(
          options.minBufferMs,
          options.maxBufferMs,
          options.bufferForPlaybackMs,
          options.bufferForPlaybackAfterRebufferMs);
      // One line per player opened with them: the device check counts these.
      Log.i(
          TAG,
          "buffer durations min="
              + options.minBufferMs
              + " max="
              + options.maxBufferMs
              + " playback="
              + options.bufferForPlaybackMs
              + " rebuffer="
              + options.bufferForPlaybackAfterRebufferMs);
    }
    return builder == null ? null : builder.build();
  }

  @Nullable
  private static Integer toMs(@Nullable Long value, @NonNull String name) {
    if (value == null) {
      return null;
    }
    if (value < 0 || value > Integer.MAX_VALUE) {
      throw new IllegalArgumentException(name + " must be between 0 and Integer.MAX_VALUE");
    }
    return value.intValue();
  }
}
