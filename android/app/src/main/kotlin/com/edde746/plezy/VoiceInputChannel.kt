package com.edde746.plezy

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Fork: speech to text for AI requests through the system recogniser (Google's voice input on
 * phones and on Android TV, where the remote's mic button opens it). The recogniser app owns the
 * microphone and its own UI, so Plezy needs no audio permission.
 */
internal class VoiceInputChannel(private val activity: Activity) {
  companion object {
    private const val CHANNEL = "com.plezy/voice_input"
    const val REQUEST_CODE = 7462
  }

  private var pendingResult: MethodChannel.Result? = null

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isAvailable" -> result.success(recogniseIntent(null).resolveActivity(activity.packageManager) != null)
      "listen" -> listen(call.argument<String>("prompt"), result)
      else -> result.notImplemented()
    }
  }

  private fun recogniseIntent(prompt: String?) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
    if (prompt != null) putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
  }

  /** What was said, or null when the user backed out or nothing was heard. */
  private fun listen(prompt: String?, result: MethodChannel.Result) {
    // A second press while listening replaces the first.
    pendingResult?.success(null)
    pendingResult = result
    try {
      activity.startActivityForResult(recogniseIntent(prompt), REQUEST_CODE)
    } catch (e: ActivityNotFoundException) {
      pendingResult = null
      result.error("UNAVAILABLE", "No speech recogniser on this device", null)
    }
  }

  fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_CODE) return false
    val result = pendingResult ?: return true
    pendingResult = null
    val text = if (resultCode == Activity.RESULT_OK) {
      data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }
    } else {
      null
    }
    result.success(text)
    return true
  }

  fun dispose() {
    pendingResult?.success(null)
    pendingResult = null
  }
}
