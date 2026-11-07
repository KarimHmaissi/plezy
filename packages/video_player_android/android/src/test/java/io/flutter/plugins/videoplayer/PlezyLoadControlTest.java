// PLEZY DELTA: this whole file is a Plezy addition to the vendored package (see its README),
// under the package's own BSD-style license (LICENSE).

package io.flutter.plugins.videoplayer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mockConstruction;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

import androidx.media3.exoplayer.DefaultLoadControl;
import java.util.HashMap;
import org.junit.Test;
import org.mockito.MockedConstruction;

public final class PlezyLoadControlTest {
  private static CreationOptions creation(Long min, Long max, Long forPlayback, Long rebuffer) {
    return new CreationOptions(
        "https://example.com/clip.mp4",
        null,
        new HashMap<>(),
        null,
        null,
        min,
        max,
        forPlayback,
        rebuffer);
  }

  private static VideoPlayerOptions clipOptions() {
    VideoPlayerOptions options = new VideoPlayerOptions();
    PlezyLoadControl.copyBufferDurations(creation(2500L, 12000L, 500L, 1500L), options);
    return options;
  }

  @Test
  public void copyBufferDurations_copiesAllFour() {
    VideoPlayerOptions options = clipOptions();

    assertTrue(options.hasBufferDurations());
    assertEquals(Integer.valueOf(2500), options.minBufferMs);
    assertEquals(Integer.valueOf(12000), options.maxBufferMs);
    assertEquals(Integer.valueOf(500), options.bufferForPlaybackMs);
    assertEquals(Integer.valueOf(1500), options.bufferForPlaybackAfterRebufferMs);
  }

  @Test
  public void copyBufferDurations_noneLeavesThemUnset() {
    VideoPlayerOptions options = new VideoPlayerOptions();
    PlezyLoadControl.copyBufferDurations(creation(null, null, null, null), options);

    assertEquals(false, options.hasBufferDurations());
    assertNull(options.minBufferMs);
  }

  @Test
  public void copyBufferDurations_partialSetThrows() {
    VideoPlayerOptions options = new VideoPlayerOptions();

    assertThrows(
        IllegalArgumentException.class,
        () -> PlezyLoadControl.copyBufferDurations(creation(2500L, 12000L, null, 1500L), options));
  }

  @Test
  public void copyBufferDurations_outOfIntRangeThrows() {
    VideoPlayerOptions options = new VideoPlayerOptions();

    assertThrows(
        IllegalArgumentException.class,
        () ->
            PlezyLoadControl.copyBufferDurations(
                creation(2500L, (long) Integer.MAX_VALUE + 1, 500L, 1500L), options));
  }

  @Test
  public void copyConstructor_keepsBufferDurations() {
    VideoPlayerOptions copy = new VideoPlayerOptions(clipOptions());

    assertTrue(copy.hasBufferDurations());
    assertEquals(Integer.valueOf(12000), copy.maxBufferMs);
  }

  @Test
  public void build_withNothingSet_keepsMedia3Default() {
    try (MockedConstruction<DefaultLoadControl.Builder> builders =
        mockConstruction(DefaultLoadControl.Builder.class)) {
      assertNull(PlezyLoadControl.build(new VideoPlayerOptions()));
      assertEquals(0, builders.constructed().size());
    }
  }

  @Test
  public void build_withBufferDurations_setsThemOnOneBuilder() {
    VideoPlayerOptions options = clipOptions();

    try (MockedConstruction<DefaultLoadControl.Builder> builders =
        mockConstruction(DefaultLoadControl.Builder.class)) {
      PlezyLoadControl.build(options);

      assertEquals(1, builders.constructed().size());
      DefaultLoadControl.Builder builder = builders.constructed().get(0);
      verify(builder).setBufferDurationsMs(2500, 12000, 500, 1500);
      verify(builder, never()).setBackBuffer(anyInt(), anyBoolean());
      verify(builder).build();
    }
  }

  @Test
  public void build_withBackBufferAndDurations_setsBothOnOneBuilder() {
    VideoPlayerOptions options = clipOptions();
    options.backBufferDurationMs = 1000L;

    try (MockedConstruction<DefaultLoadControl.Builder> builders =
        mockConstruction(DefaultLoadControl.Builder.class)) {
      PlezyLoadControl.build(options);

      assertEquals(1, builders.constructed().size());
      DefaultLoadControl.Builder builder = builders.constructed().get(0);
      verify(builder).setBackBuffer(1000, true);
      verify(builder).setBufferDurationsMs(2500, 12000, 500, 1500);
    }
  }

  @Test
  public void build_withBackBufferOnly_isUpstreamBehaviour() {
    VideoPlayerOptions options = new VideoPlayerOptions();
    options.backBufferDurationMs = 20000L;

    try (MockedConstruction<DefaultLoadControl.Builder> builders =
        mockConstruction(DefaultLoadControl.Builder.class)) {
      PlezyLoadControl.build(options);

      DefaultLoadControl.Builder builder = builders.constructed().get(0);
      verify(builder).setBackBuffer(20000, true);
      verify(builder, never()).setBufferDurationsMs(anyInt(), anyInt(), anyInt(), anyInt());
    }
  }

  @Test
  public void build_withNegativeBackBuffer_throwsAsUpstream() {
    VideoPlayerOptions options = new VideoPlayerOptions();
    options.backBufferDurationMs = -1L;

    assertThrows(IllegalArgumentException.class, () -> PlezyLoadControl.build(options));
  }

  @Test
  public void build_realMedia3_acceptsTheClipValues() {
    // No mock: media3's own argument checks run on the clip values.
    assertTrue(PlezyLoadControl.build(clipOptions()) != null);
  }

  @Test
  public void build_realMedia3_rejectsAnOutOfOrderSet() {
    VideoPlayerOptions options = new VideoPlayerOptions();
    PlezyLoadControl.copyBufferDurations(creation(2500L, 1000L, 500L, 1500L), options);

    assertThrows(IllegalArgumentException.class, () -> PlezyLoadControl.build(options));
  }
}
