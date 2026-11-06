package com.edde746.plezy.exoplayer

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.trackselection.TrackSelector

/**
 * The Reel's clip core (`initialize(clipMode = true)`) plays short trailers and theme songs back
 * to back. Its output must never ask the TV or the soundbar to re-lock between cards, so these
 * rules are fixed in code rather than left to whatever the main player's settings say (V2-18):
 *
 * - **No Dolby Vision conversion.** [dvMode] is always [DvConversionMode.DISABLED]: no RPU
 *   rewriting, no extractor wrapper, and no "retry as DV 8.1" reload when a clip fails.
 * - **No frame-rate switch.** media3's own hint (`Surface.setFrameRate`, default
 *   `VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS`) is turned off with
 *   [VIDEO_CHANGE_FRAME_RATE_STRATEGY], and the app's display-mode switch refuses clip cores.
 * - **One selector the core can reach.** `DefaultPreloadManager.Builder.buildExoPlayer` replaces
 *   the `ExoPlayer.Builder`'s track selector with one from its own [TrackSelector.Factory]
 *   (media3 1.11.0, checked with javap), and `build()` asks the same factory for a second one
 *   for preloading. [RecordingTrackSelectorFactory] configures both the same way and keeps them,
 *   so preferences set on the core reach the player that actually plays the clip.
 */
@OptIn(UnstableApi::class)
internal object ClipCorePolicy {
  /** media3 never calls `Surface.setFrameRate` for a clip. */
  const val VIDEO_CHANGE_FRAME_RATE_STRATEGY: Int = C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF

  /** The DV conversion mode for a core: [configured] is only asked outside clip mode. */
  inline fun dvMode(clipMode: Boolean, configured: () -> DvConversionMode): DvConversionMode = if (clipMode) DvConversionMode.DISABLED else configured()

  /** The log word for a frame-rate strategy constant. */
  fun frameRateStrategyName(strategy: Int): String = when (strategy) {
    C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_OFF -> "off"
    C.VIDEO_CHANGE_FRAME_RATE_STRATEGY_ONLY_IF_SEAMLESS -> "only-if-seamless"
    else -> "other($strategy)"
  }

  /**
   * What a clip's video would ask of the display: `dv` for a Dolby Vision track, `pq` / `hlg`
   * for the two HDR transfers, `sdr` otherwise (an unknown transfer is SDR as far as the HDMI
   * link is concerned).
   */
  fun dynamicRange(format: Format?): String {
    if (format == null) return "none"
    if (format.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION) return "dv"
    return when (format.colorInfo?.colorTransfer) {
      C.COLOR_TRANSFER_ST2084 -> "pq"
      C.COLOR_TRANSFER_HLG -> "hlg"
      else -> "sdr"
    }
  }

  /**
   * The parameters the preload selector should carry after the player's changed: everything
   * except per-track overrides, which name track groups of the clip that is playing and mean
   * nothing for the next one.
   */
  fun preloadParameters(player: DefaultTrackSelector.Parameters): DefaultTrackSelector.Parameters = player.buildUpon().clearOverrides().build()

  /**
   * One `[ReelClip]` line per clip, on its first frame: what the TV and the soundbar are being
   * asked to show and play. [audioTrackInits] is the core's running count of AudioTracks: if it
   * has not moved since the last clip, the soundbar had nothing to re-lock to. [selectorAttached] is false if the core's selector is not the one
   * the player uses, which is the bug this policy fixes.
   */
  fun describeClip(
    generation: Int,
    video: Format?,
    audio: Format?,
    audioOutput: String,
    audioTrackInits: Int,
    dvMode: DvConversionMode,
    frameRateStrategy: Int,
    selectorAttached: Boolean
  ): String {
    val v = video?.let {
      val fps = if (it.frameRate > 0f) "${it.frameRate}fps" else "fps=?"
      "${it.sampleMimeType ?: "?"} ${it.width}x${it.height} $fps"
    } ?: "none"
    val a = audio?.let { "${it.sampleMimeType ?: "?"} ch=${it.channelCount} ${it.sampleRate}Hz" } ?: "none"
    return "clip gen=$generation video=[$v] range=${dynamicRange(video)} dv=${dvMode.name} " +
      "frameRate=${frameRateStrategyName(frameRateStrategy)} audio=[$a] output=[$audioOutput] audioTrackInits=$audioTrackInits " +
      "selector=${if (selectorAttached) "attached" else "DETACHED"}"
  }
}

/**
 * A [TrackSelector.Factory] that builds every selector with [configure] and keeps them in
 * creation order. `DefaultPreloadManager.Builder` calls it once in `buildExoPlayer` (the
 * player's selector) and once in `build()` (the preload manager's).
 */
@OptIn(UnstableApi::class)
internal class RecordingTrackSelectorFactory(private val configure: (DefaultTrackSelector) -> Unit) : TrackSelector.Factory {
  private val made = mutableListOf<DefaultTrackSelector>()

  val created: List<DefaultTrackSelector> get() = made.toList()

  override fun createTrackSelector(context: Context): TrackSelector = DefaultTrackSelector(context).also {
    configure(it)
    made += it
  }
}
