package com.edde746.plezy.exoplayer

import android.content.Context
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo
import androidx.media3.exoplayer.mediacodec.MediaCodecRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import java.lang.reflect.Proxy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class PlayerCoreCountsTest {

  private val context: Context get() = RuntimeEnvironment.getApplication()

  @Before
  fun setUp() {
    PlayerCoreCounts.resetForTest()
  }

  @After
  fun tearDown() {
    PlayerCoreCounts.resetForTest()
  }

  @Test
  fun theSummaryCountsCoresAndTheCodecsLeftOnReleasedCores() {
    assertEquals(1, PlayerCoreCounts.onCreated())
    assertEquals(2, PlayerCoreCounts.onCreated())
    repeat(5) { PlayerCoreCounts.onCodecCreated() }
    PlayerCoreCounts.onReleased(coreCodecs = 2)

    assertEquals(2, PlayerCoreCounts.codecsOnReleasedCores)
    assertEquals(
      "cores created=2 released=1 live=1 codecs=5 codecsOnReleasedCores=2",
      PlayerCoreCounts.summary()
    )
  }

  @Test
  fun theCountingFactoryHandsBackTheDelegatesAdapterAndReportsEachCodec() {
    val adapter = fakeAdapter()
    var delegateCalls = 0
    val seen = mutableListOf<String?>()
    val factory = CountingCodecAdapterFactory(
      { _ ->
        delegateCalls++
        adapter
      }
    ) { configuration -> seen += configuration.format.sampleMimeType }

    assertSame(adapter, factory.createAdapter(videoConfiguration()))
    assertSame(adapter, factory.createAdapter(audioConfiguration()))

    assertEquals(2, delegateCalls)
    assertEquals(listOf(MimeTypes.VIDEO_H264, MimeTypes.AUDIO_AAC), seen)
  }

  @Test
  fun aCodecThatFailsToOpenIsNotCounted() {
    var seen = 0
    val factory = CountingCodecAdapterFactory({ _ -> throw java.io.IOException("no codec") }) { seen++ }

    runCatching { factory.createAdapter(videoConfiguration()) }

    assertEquals(0, seen)
  }

  @Test
  fun everyMediaCodecRendererTheFactoryBuildsCountsItsCodecs() {
    val seen = mutableListOf<String?>()
    val factory = PlezyRenderersFactory(context).apply {
      onCodecCreated = { configuration -> seen += configuration.format.sampleMimeType }
    }

    val renderers = factory.createRenderers(
      Handler(Looper.getMainLooper()),
      object : VideoRendererEventListener {},
      object : AudioRendererEventListener {},
      { _ -> },
      { _ -> }
    )
    val codecRenderers = renderers.filterIsInstance<MediaCodecRenderer>()

    // The video and the audio MediaCodec renderer, both on the counting factory.
    assertEquals(setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO), codecRenderers.map { it.trackType }.toSet())
    val factories = codecRenderers.map { renderer ->
      MediaCodecRenderer::class.java.getDeclaredField("codecAdapterFactory")
        .apply { isAccessible = true }
        .get(renderer)
    }
    assertTrue(factories.all { it is CountingCodecAdapterFactory })

    // A codec made through either one reaches the core's hook. (The wrapped default factory
    // would open a real MediaCodec, so the hook is called directly.)
    for (counting in factories) {
      @Suppress("UNCHECKED_CAST")
      val hook = CountingCodecAdapterFactory::class.java.getDeclaredField("onCreated")
        .apply { isAccessible = true }
        .get(counting) as (MediaCodecAdapter.Configuration) -> Unit
      hook(audioConfiguration())
    }
    assertEquals(codecRenderers.size, seen.size)
  }

  private fun fakeAdapter(): MediaCodecAdapter = Proxy.newProxyInstance(
    MediaCodecAdapter::class.java.classLoader,
    arrayOf(MediaCodecAdapter::class.java)
  ) { _, _, _ -> null } as MediaCodecAdapter

  private fun codecInfo(mimeType: String) = MediaCodecInfo.newInstance(
    "test.decoder",
    mimeType,
    mimeType,
    null,
    false,
    false,
    false,
    false,
    false
  )

  private fun videoConfiguration() = MediaCodecAdapter.Configuration.createForVideoDecoding(
    codecInfo(MimeTypes.VIDEO_H264),
    MediaFormat.createVideoFormat(MimeTypes.VIDEO_H264, 1920, 1080),
    Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H264).build(),
    null,
    null
  )

  private fun audioConfiguration() = MediaCodecAdapter.Configuration.createForAudioDecoding(
    codecInfo(MimeTypes.AUDIO_AAC),
    MediaFormat.createAudioFormat(MimeTypes.AUDIO_AAC, 48000, 2),
    Format.Builder().setSampleMimeType(MimeTypes.AUDIO_AAC).build(),
    null,
    null
  )
}
