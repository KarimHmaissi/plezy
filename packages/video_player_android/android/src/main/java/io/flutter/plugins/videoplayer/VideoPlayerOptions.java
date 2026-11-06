// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

public class VideoPlayerOptions {
  public boolean mixWithOthers;

  /**
   * The duration of the back buffer in milliseconds, used to configure ExoPlayer's load control.
   */
  @Nullable public Long backBufferDurationMs;

  // PLEZY DELTA: media3 buffer durations, set all four together or none (PlezyLoadControl).
  @Nullable public Integer minBufferMs;
  @Nullable public Integer maxBufferMs;
  @Nullable public Integer bufferForPlaybackMs;
  @Nullable public Integer bufferForPlaybackAfterRebufferMs;

  /** PLEZY DELTA: whether the buffer durations are set (all four). */
  public boolean hasBufferDurations() {
    return minBufferMs != null
        && maxBufferMs != null
        && bufferForPlaybackMs != null
        && bufferForPlaybackAfterRebufferMs != null;
  }

  public VideoPlayerOptions() {}

  /** Copy constructor to ensure all options are reliably copied. */
  public VideoPlayerOptions(@NonNull VideoPlayerOptions other) {
    this.mixWithOthers = other.mixWithOthers;
    this.backBufferDurationMs = other.backBufferDurationMs;
    // PLEZY DELTA
    this.minBufferMs = other.minBufferMs;
    this.maxBufferMs = other.maxBufferMs;
    this.bufferForPlaybackMs = other.bufferForPlaybackMs;
    this.bufferForPlaybackAfterRebufferMs = other.bufferForPlaybackAfterRebufferMs;
  }
}
