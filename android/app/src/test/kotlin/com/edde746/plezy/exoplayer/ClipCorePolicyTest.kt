package com.edde746.plezy.exoplayer

import android.app.Activity
import android.os.Looper
import android.widget.FrameLayout
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * V2-18. The clip core's player is built by media3's `DefaultPreloadManager.Builder`, which in
 * 1.11.0 swaps the `ExoPlayer.Builder`'s track selector for one from its own factory. These
 * tests build real cores, so a media3 upgrade that changes that wiring fails here.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ClipCorePolicyTest {

  private fun <T> withCore(clipMode: Boolean, body: (ExoPlayerCore) -> T): T {
    val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    activity.setContentView(FrameLayout(activity))
    val core = ExoPlayerCore(activity)
    try {
      assertTrue(core.initialize(clipMode = clipMode))
      return body(core)
    } finally {
      core.dispose()
      shadowOf(Looper.getMainLooper()).idle()
    }
  }

  private fun ExoPlayerCore.field(name: String): Any? = ExoPlayerCore::class.java.getDeclaredField(name).apply { isAccessible = true }.get(this)

  private val ExoPlayerCore.player: ExoPlayer get() = field("exoPlayer") as ExoPlayer
  private val ExoPlayerCore.selector: DefaultTrackSelector? get() = field("trackSelector") as DefaultTrackSelector?
  private val ExoPlayerCore.preloadSelector: DefaultTrackSelector? get() = field("preloadTrackSelector") as DefaultTrackSelector?

  @Test
  fun theClipCoreHoldsTheSelectorItsPlayerUses() {
    withCore(clipMode = true) { core ->
      val selector = core.selector
      assertNotNull(selector)
      assertSame(selector, core.player.trackSelector)
    }
  }

  @Test
  fun theClipCoreKeepsThePreloadManagersOwnSelectorToo() {
    withCore(clipMode = true) { core ->
      val preload = core.preloadSelector
      assertNotNull(preload)
      assertNotSame(core.selector, preload)
    }
  }

  @Test
  fun bothClipSelectorsStartFromTheMainPlayersParameters() {
    withCore(clipMode = true) { core ->
      for (selector in listOf(core.selector!!, core.preloadSelector!!)) {
        val p = selector.parameters
        assertFalse(p.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT))
        assertTrue(p.allowInvalidateSelectionsOnRendererCapabilitiesChange)
      }
    }
  }

  @Test
  fun aPreferenceSetOnTheClipCoreReachesThePlayerAndThePreloadSelector() {
    withCore(clipMode = true) { core ->
      core.selectSubtitleTrack("no")
      assertTrue(core.player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT))
      assertTrue(core.preloadSelector!!.parameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT))
    }
  }

  @Test
  fun theClipCoreNeverAsksForAFrameRateChange() {
    withCore(clipMode = true) { core ->
      assertEquals(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF, core.player.videoChangeFrameRateStrategy)
      var switched: Boolean? = null
      core.setVideoFrameRate(23.976f, 60_000L, 0L, 1920, 1080, false) { switched = it }
      assertEquals(false, switched)
    }
  }

  @Test
  fun theClipCoreNeverConvertsDolbyVision() {
    withCore(clipMode = true) { core ->
      assertEquals(DvConversionMode.DISABLED, core.field("dvMode"))
      // Even a forced debug conversion mode stays off on a clip core.
      core.setDebugDvConversionMode("dv81")
      assertEquals(DvConversionMode.DISABLED, core.field("dvMode"))
    }
  }

  @Test
  fun theMainPlayerIsUnchanged() {
    withCore(clipMode = false) { core ->
      assertSame(core.selector, core.player.trackSelector)
      assertNull(core.preloadSelector)
      assertEquals(C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS, core.player.videoChangeFrameRateStrategy)
    }
  }

  @Test
  fun dvModeOnlyAsksTheDisplayOutsideClipMode() {
    var asked = 0
    val clip = ClipCorePolicy.dvMode(clipMode = true) {
      asked++
      DvConversionMode.DV81
    }
    assertEquals(DvConversionMode.DISABLED, clip)
    assertEquals(0, asked)
    assertEquals(DvConversionMode.HEVC_STRIP, ClipCorePolicy.dvMode(clipMode = false) { DvConversionMode.HEVC_STRIP })
  }

  @Test
  fun preloadParametersDropPerTrackOverridesOnly() {
    val group = TrackGroup(Format.Builder().setSampleMimeType(MimeTypes.TEXT_VTT).build())
    val player = DefaultTrackSelector.Parameters.Builder()
      .setPreferredTextLanguage("en")
      .setOverrideForType(TrackSelectionOverride(group, 0))
      .build()
    val preload = ClipCorePolicy.preloadParameters(player)
    assertTrue(preload.overrides.isEmpty())
    assertEquals(listOf("en"), preload.preferredTextLanguages)
  }

  @Test
  fun dynamicRangeNamesWhatTheDisplayIsAskedFor() {
    fun video(transfer: Int?, mime: String = MimeTypes.VIDEO_H265) = Format.Builder()
      .setSampleMimeType(mime)
      .apply { if (transfer != null) setColorInfo(ColorInfo.Builder().setColorTransfer(transfer).build()) }
      .build()
    assertEquals("none", ClipCorePolicy.dynamicRange(null))
    assertEquals("sdr", ClipCorePolicy.dynamicRange(video(null)))
    assertEquals("sdr", ClipCorePolicy.dynamicRange(video(C.COLOR_TRANSFER_SDR)))
    assertEquals("pq", ClipCorePolicy.dynamicRange(video(C.COLOR_TRANSFER_ST2084)))
    assertEquals("hlg", ClipCorePolicy.dynamicRange(video(C.COLOR_TRANSFER_HLG)))
    assertEquals("dv", ClipCorePolicy.dynamicRange(video(null, MimeTypes.VIDEO_DOLBY_VISION)))
  }

  @Test
  fun theClipLineCarriesEveryDeviceCheckField() {
    val video = Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H264).setWidth(1280).setHeight(720).setFrameRate(24f).build()
    val audio = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_AAC).setChannelCount(6).setSampleRate(48_000).build()
    val line = ClipCorePolicy.describeClip(
      generation = 7,
      video = video,
      audio = audio,
      audioOutput = "encoding=2, channels=6",
      audioTrackInits = 3,
      dvMode = DvConversionMode.DISABLED,
      frameRateStrategy = C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF,
      selectorAttached = true
    )
    assertEquals(
      "clip gen=7 video=[video/avc 1280x720 24.0fps] range=sdr dv=DISABLED frameRate=off " +
        "audio=[audio/mp4a-latm ch=6 48000Hz] output=[encoding=2, channels=6] audioTrackInits=3 selector=attached",
      line
    )
    assertTrue(
      ClipCorePolicy.describeClip(1, null, null, "not yet", 0, DvConversionMode.DISABLED, 0, selectorAttached = false)
        .endsWith("selector=DETACHED")
    )
  }
}
