package com.edde746.plezy.exoplayer

import android.app.Activity
import android.media.MediaFormat
import android.os.Looper
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ExoPlayerInitializationCleanupTest {

  @Test
  fun disposeRemovesPartiallyAttachedViewAndLayoutListener() {
    val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    activity.setContentView(FrameLayout(activity))
    val content = activity.findViewById<ViewGroup>(android.R.id.content)
    val container = FrameLayout(activity)
    content.addView(container)
    var layoutCallbacks = 0
    val listener = ViewTreeObserver.OnGlobalLayoutListener { layoutCallbacks++ }
    content.viewTreeObserver.addOnGlobalLayoutListener(listener)

    val core = ExoPlayerCore(activity)
    core.setPrivateField("surfaceContainer", container)
    core.setPrivateField("overlayLayoutListener", listener)

    core.dispose()
    content.viewTreeObserver.dispatchOnGlobalLayout()
    shadowOf(Looper.getMainLooper()).idle()

    assertEquals(0, layoutCallbacks)
    assertNull(container.parent)
    assertNull(core.getPrivateField("overlayLayoutListener"))
  }

  @Test
  fun initializePreservesDefaultUncaughtExceptionHandlerAcrossPlayerLifecycles() {
    val original = Thread.getDefaultUncaughtExceptionHandler()
    val sentinel = Thread.UncaughtExceptionHandler { _, _ -> Unit }
    Thread.setDefaultUncaughtExceptionHandler(sentinel)
    val cores = mutableListOf<ExoPlayerCore>()

    try {
      repeat(2) {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        activity.setContentView(FrameLayout(activity))
        val core = ExoPlayerCore(activity)
        cores += core

        assertTrue(core.initialize())
        assertSame(sentinel, Thread.getDefaultUncaughtExceptionHandler())

        core.dispose()
        shadowOf(Looper.getMainLooper()).idle()
        assertSame(sentinel, Thread.getDefaultUncaughtExceptionHandler())
      }
    } finally {
      cores.forEach { it.dispose() }
      shadowOf(Looper.getMainLooper()).idle()
      Thread.setDefaultUncaughtExceptionHandler(original)
    }
  }

  @Test
  fun aClipCoreCountsItsCodecsAndReportsThemWhenReleased() {
    PlayerCoreCounts.resetForTest()
    val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    activity.setContentView(FrameLayout(activity))
    val core = ExoPlayerCore(activity)
    try {
      assertTrue(core.initialize(clipMode = true))
      assertEquals(
        "cores created=1 released=0 live=1 codecs=0 codecsOnReleasedCores=0",
        PlayerCoreCounts.summary()
      )

      // The playback thread opening one video and one audio codec through the core's factory.
      val factory = core.getPrivateField("renderersFactory") as PlezyRenderersFactory
      val hook = checkNotNull(factory.onCodecCreated)
      hook(codecConfiguration(MimeTypes.VIDEO_H264))
      hook(codecConfiguration(MimeTypes.AUDIO_AAC))

      core.dispose()
      shadowOf(Looper.getMainLooper()).idle()

      assertEquals(2, PlayerCoreCounts.codecsOnReleasedCores)
      assertEquals(
        "cores created=1 released=1 live=0 codecs=2 codecsOnReleasedCores=2",
        PlayerCoreCounts.summary()
      )
    } finally {
      core.dispose()
      shadowOf(Looper.getMainLooper()).idle()
      PlayerCoreCounts.resetForTest()
    }
  }

  private fun codecConfiguration(mimeType: String): MediaCodecAdapter.Configuration {
    val info = MediaCodecInfo.newInstance("test.decoder", mimeType, mimeType, null, false, false, false, false, false)
    val format = Format.Builder().setSampleMimeType(mimeType).build()
    return if (MimeTypes.isVideo(mimeType)) {
      MediaCodecAdapter.Configuration.createForVideoDecoding(info, MediaFormat.createVideoFormat(mimeType, 1920, 1080), format, null, null)
    } else {
      MediaCodecAdapter.Configuration.createForAudioDecoding(info, MediaFormat.createAudioFormat(mimeType, 48000, 2), format, null, null)
    }
  }

  private fun Any.setPrivateField(name: String, value: Any?) {
    javaClass.getDeclaredField(name).apply {
      isAccessible = true
      set(this@setPrivateField, value)
    }
  }

  private fun Any.getPrivateField(name: String): Any? = javaClass.getDeclaredField(name).apply { isAccessible = true }.get(this)
}
