package com.edde746.plezy.exoplayer

import android.app.Activity
import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

private const val TAG = "PlaybackCapabilities"

/**
 * Fork: what this device and the TV/soundbar behind it can play, read in one call for Dart's
 * `PlaybackCapabilitiesService` (Best Copy's playability gates, The Reel's clip player). Reads
 * only; nothing here changes how a stream opens.
 *
 * - `getPlaybackCapabilities` returns the movie-route HDMI sink encodings ([movieHdmiSinkEncodings]),
 *   the active display's HDR types and the Dolby Vision decoder support ([DoviBridge]).
 *   HEVC/AV1 decoders are not repeated here: Dart reads them from `VideoDecodeCapabilities`.
 * - `onInvalidated` is pushed to Dart when an HDMI output appears or disappears (TV or soundbar
 *   swapped, AVR switched on), so the cached answer is read again on next use.
 */
internal class PlaybackCapabilitiesChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/playback_capabilities"
  }

  private var channel: MethodChannel? = null
  private var deviceCallback: AudioDeviceCallback? = null

  fun attach(messenger: BinaryMessenger) {
    dispose()
    val methodChannel = MethodChannel(messenger, CHANNEL)
    channel = methodChannel
    methodChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "getPlaybackCapabilities" -> result.success(read())
        else -> result.notImplemented()
      }
    }
    watchHdmiRoutes()
  }

  private fun read(): Map<String, Any?> {
    val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val sinks = runCatching { movieHdmiSinkEncodings(manager) }.getOrElse { error ->
      Log.w(TAG, "HDMI sink inspection failed", error)
      emptyList()
    }
    return playbackCapabilitiesMap(
      hdmiSinkEncodings = sinks,
      displayHdrTypes = DoviBridge.displayHdrTypes(activity),
      dolbyVision = mapOf(
        "decoder" to DoviBridge.hasNativeDolbyVisionDecoder,
        "profile5" to DoviBridge.canPlayDolbyVisionP5(),
        "profile7" to DoviBridge.deviceSupportsDvProfile7,
        "profile8" to DoviBridge.deviceSupportsDvProfile8,
        "p7Conversion" to DoviBridge.isAvailable()
      )
    )
  }

  private fun watchHdmiRoutes() {
    val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val callback = object : AudioDeviceCallback() {
      // Registration replays every connected device as "added"; that first batch is not a change.
      private var primed = false

      override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
        if (!primed) {
          primed = true
          return
        }
        onRouteChange(addedDevices)
      }

      override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = onRouteChange(removedDevices)
    }
    manager.registerAudioDeviceCallback(callback, Handler(Looper.getMainLooper()))
    deviceCallback = callback
  }

  private fun onRouteChange(devices: Array<out AudioDeviceInfo>) {
    if (!touchesHdmiOutput(devices.map { it.type to it.isSink })) return
    channel?.invokeMethod("onInvalidated", null)
  }

  fun dispose() {
    deviceCallback?.let { callback ->
      (activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager).unregisterAudioDeviceCallback(callback)
    }
    deviceCallback = null
    channel?.setMethodCallHandler(null)
    channel = null
  }
}

/**
 * The wire name Dart's `SinkAudioEncoding` reads for an `AudioDeviceInfo.getEncodings()` entry,
 * or null for one it does not model. All linear PCM widths collapse to `pcm`.
 */
internal fun sinkEncodingName(encoding: Int): String? = when {
  isPcmEncoding(encoding) -> "pcm"
  else -> when (encoding) {
    AudioFormat.ENCODING_AC3 -> "ac3"
    AudioFormat.ENCODING_E_AC3 -> "eac3"
    AudioFormat.ENCODING_E_AC3_JOC -> "eac3-joc"
    AudioFormat.ENCODING_AC4 -> "ac4"
    AudioFormat.ENCODING_DOLBY_TRUEHD -> "truehd"
    AudioFormat.ENCODING_DOLBY_MAT -> "dolby-mat"
    AudioFormat.ENCODING_DTS -> "dts"
    AudioFormat.ENCODING_DTS_HD -> "dts-hd"
    ENCODING_DTS_HD_MA -> "dts-hd-ma"
    ENCODING_DTS_UHD_P1, ENCODING_DTS_UHD_P2 -> "dts-uhd"
    AudioFormat.ENCODING_IEC61937 -> "iec61937"
    else -> null
  }
}

/** The wire name Dart's `DisplayHdrType` reads for a `Display.HdrCapabilities.HDR_TYPE_*` value. */
internal fun hdrTypeName(type: Int): String? = when (type) {
  Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "dolbyVision"
  Display.HdrCapabilities.HDR_TYPE_HDR10 -> "hdr10"
  Display.HdrCapabilities.HDR_TYPE_HLG -> "hlg"
  Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "hdr10Plus"
  else -> null
}

/**
 * The `getPlaybackCapabilities` reply. `hdmiSink` says whether a movie would play through HDMI
 * at all (false on optical, USB or Bluetooth routes); `sinkEncodings` is the union of what those
 * HDMI sinks list, in first-seen order.
 */
internal fun playbackCapabilitiesMap(
  hdmiSinkEncodings: List<IntArray>,
  displayHdrTypes: IntArray,
  dolbyVision: Map<String, Boolean>
): Map<String, Any?> = mapOf(
  "hdmiSink" to hdmiSinkEncodings.isNotEmpty(),
  "sinkEncodings" to hdmiSinkEncodings.flatMap { it.asList() }.mapNotNull(::sinkEncodingName).distinct(),
  "hdrTypes" to displayHdrTypes.asList().mapNotNull(::hdrTypeName).distinct(),
  "dolbyVision" to dolbyVision
)

/** Whether an audio-device add/remove batch of (type, isSink) pairs includes an HDMI output. */
internal fun touchesHdmiOutput(
  devices: List<Pair<Int, Boolean>>,
  isHdmiOutput: (Int) -> Boolean = ::isHdmiOutputType
): Boolean = devices.any { (type, isSink) -> isSink && isHdmiOutput(type) }
