package com.edde746.plezy.exoplayer

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import java.util.concurrent.atomic.AtomicInteger

/**
 * Process-wide counts for the `[ReelCore]` log: player cores built and released, and the
 * MediaCodec instances they made.
 *
 * Why codecs. The Shield's Android 11 build gives every `MediaCodec` a
 * `DisplayManager.DisplayListener` of its own (each display event logs
 * `MediaCodec: Display changed, check if the current mode matches content`). It is
 * registered on the looper of the thread that creates the codec, and `MediaCodec.release()`
 * leaves it registered. media3 creates its codecs on the playback thread, and that thread
 * quits when the player is released. After that, every codec a released core made shows up
 * at the next display event (a standby wake, a refresh-rate switch) as a "sending message to
 * a Handler on a dead thread" warning.
 *
 * media3's own display listener is not the leak. That is the vsync sampler of
 * `VideoFrameReleaseHelper` (1.11.0), which registers in `onStarted` and unregisters in
 * `onStopped`, and the playback thread stops every renderer in each release, whichever of
 * the player and the preload manager goes first.
 *
 * So after a wake, the number of distinct dead-thread `DisplayListenerDelegate` handlers
 * should equal [codecsOnReleasedCores] (MPV's codecs land on the main looper, which never
 * dies). The release order can't change that. Only fewer codec instances can.
 */
internal object PlayerCoreCounts {
  private val created = AtomicInteger()
  private val released = AtomicInteger()
  private val codecs = AtomicInteger()
  private val codecsOnReleased = AtomicInteger()

  /** A new core: returns its serial number. */
  fun onCreated(): Int = created.incrementAndGet()

  /** A MediaCodec made by any core (called on that core's playback thread). */
  fun onCodecCreated() {
    codecs.incrementAndGet()
  }

  /** A core released, having made [coreCodecs] codecs over its life. */
  fun onReleased(coreCodecs: Int) {
    released.incrementAndGet()
    codecsOnReleased.addAndGet(coreCodecs)
  }

  val codecsOnReleasedCores: Int get() = codecsOnReleased.get()

  fun summary(): String {
    val made = created.get()
    val gone = released.get()
    return "cores created=$made released=$gone live=${made - gone} " +
      "codecs=${codecs.get()} codecsOnReleasedCores=${codecsOnReleased.get()}"
  }

  internal fun resetForTest() {
    created.set(0)
    released.set(0)
    codecs.set(0)
    codecsOnReleased.set(0)
  }
}

/**
 * Passes every codec adapter through from [delegate] and reports each one (one adapter is one
 * MediaCodec) to [onCreated], after the codec exists. Called on the playback thread.
 */
@OptIn(UnstableApi::class)
internal class CountingCodecAdapterFactory(
  private val delegate: MediaCodecAdapter.Factory,
  private val onCreated: (MediaCodecAdapter.Configuration) -> Unit
) : MediaCodecAdapter.Factory {
  override fun createAdapter(configuration: MediaCodecAdapter.Configuration): MediaCodecAdapter =
    delegate.createAdapter(configuration).also { onCreated(configuration) }
}
