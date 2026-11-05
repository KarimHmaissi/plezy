package com.edde746.plezy.exoplayer

import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.view.Display
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackCapabilitiesChannelTest {

  private val noDolbyVision = mapOf("decoder" to false)

  @Test
  fun sinkEncodingsAreNamedOnceInFirstSeenOrder() {
    // The Mi Box S in front of the Samsung QE55S95F + HW-Q930F lists these on HDMI.
    val miBox = intArrayOf(
      AudioFormat.ENCODING_PCM_16BIT,
      AudioFormat.ENCODING_E_AC3_JOC,
      AudioFormat.ENCODING_AC3,
      AudioFormat.ENCODING_E_AC3,
      AudioFormat.ENCODING_IEC61937
    )
    val second = intArrayOf(AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_DOLBY_TRUEHD, AudioFormat.ENCODING_AC3)

    val reply = playbackCapabilitiesMap(listOf(miBox, second), IntArray(0), noDolbyVision)

    assertEquals(true, reply["hdmiSink"])
    assertEquals(listOf("pcm", "eac3-joc", "ac3", "eac3", "iec61937", "truehd"), reply["sinkEncodings"])
  }

  @Test
  fun dtsFamilyAndUnknownEncodings() {
    assertEquals("dts", sinkEncodingName(AudioFormat.ENCODING_DTS))
    assertEquals("dts-hd", sinkEncodingName(AudioFormat.ENCODING_DTS_HD))
    assertEquals("dts-hd-ma", sinkEncodingName(ENCODING_DTS_HD_MA))
    assertEquals("dts-uhd", sinkEncodingName(ENCODING_DTS_UHD_P1))
    assertEquals("dts-uhd", sinkEncodingName(ENCODING_DTS_UHD_P2))
    assertEquals("dolby-mat", sinkEncodingName(AudioFormat.ENCODING_DOLBY_MAT))
    assertNull(sinkEncodingName(AudioFormat.ENCODING_MP3))
  }

  @Test
  fun noHdmiSinkMeansAnEmptyRoute() {
    val reply = playbackCapabilitiesMap(emptyList(), IntArray(0), noDolbyVision)

    assertEquals(false, reply["hdmiSink"])
    assertEquals(emptyList<String>(), reply["sinkEncodings"])
  }

  @Test
  fun hdrTypesAreNamedAndUnknownOnesDropped() {
    val reply = playbackCapabilitiesMap(
      emptyList(),
      intArrayOf(
        Display.HdrCapabilities.HDR_TYPE_HDR10,
        Display.HdrCapabilities.HDR_TYPE_HLG,
        Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION,
        Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS,
        Display.HdrCapabilities.HDR_TYPE_HDR10,
        99
      ),
      mapOf("decoder" to true, "profile8" to true)
    )

    assertEquals(listOf("hdr10", "hlg", "dolbyVision", "hdr10Plus"), reply["hdrTypes"])
    assertEquals(mapOf("decoder" to true, "profile8" to true), reply["dolbyVision"])
  }

  @Test
  fun onlyHdmiOutputsInvalidate() {
    val isHdmi = { type: Int -> type == AudioDeviceInfo.TYPE_HDMI || type == AudioDeviceInfo.TYPE_HDMI_ARC }

    assertTrue(touchesHdmiOutput(listOf(AudioDeviceInfo.TYPE_HDMI to true), isHdmi))
    assertTrue(touchesHdmiOutput(listOf(AudioDeviceInfo.TYPE_USB_HEADSET to true, AudioDeviceInfo.TYPE_HDMI_ARC to true), isHdmi))
    // An HDMI input (capture side) or a Bluetooth headset is not a playback route change.
    assertFalse(touchesHdmiOutput(listOf(AudioDeviceInfo.TYPE_HDMI to false), isHdmi))
    assertFalse(touchesHdmiOutput(listOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP to true), isHdmi))
    assertFalse(touchesHdmiOutput(emptyList(), isHdmi))
  }
}
