package com.edde746.plezy.exoplayer

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val TAG = "ReelCache"

/**
 * Fork: Dart's `ReelClipCache` (plan V2-10) on `com.plezy/reel_clip_cache`. Works whether or not
 * a clip core is open, since the cache is process-wide ([ClipDiskCache]):
 *
 * - `usage` returns `{bytes, capBytes}` for the Reel settings page's Clear Reel cache row;
 * - `clear` empties the cache and returns the bytes it held;
 * - `onDisk(keys)` returns the keys whose clip is on disk (a neighbouring deck's head, D15).
 *
 * Disk work runs on one background thread; results come back on the main thread.
 */
internal class ReelClipCacheChannel(private val context: Context) {
  companion object {
    private const val CHANNEL = "com.plezy/reel_clip_cache"
    private val METHODS = setOf("usage", "clear", "onDisk")
  }

  private var channel: MethodChannel? = null
  private var executor: ExecutorService? = null
  private val main = Handler(Looper.getMainLooper())

  fun attach(messenger: BinaryMessenger) {
    dispose()
    val io = Executors.newSingleThreadExecutor { r -> Thread(r, "reel-clip-cache").apply { isDaemon = true } }
    executor = io
    val methodChannel = MethodChannel(messenger, CHANNEL)
    channel = methodChannel
    methodChannel.setMethodCallHandler { call, result ->
      val method = call.method
      if (method !in METHODS) {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val keys = call.argument<List<String>>("keys").orEmpty()
      io.execute {
        val outcome = runCatching {
          when (method) {
            "usage" -> ClipDiskCache.usage(context)
            "clear" -> ClipDiskCache.clear(context)
            else -> ClipDiskCache.onDisk(keys)
          }
        }
        main.post {
          outcome.fold(
            onSuccess = { result.success(it) },
            onFailure = { error ->
              Log.w(TAG, "[ReelCache] $method failed: ${error.javaClass.simpleName}")
              result.error("REEL_CACHE", error.javaClass.simpleName, null)
            }
          )
        }
      }
    }
  }

  fun dispose() {
    channel?.setMethodCallHandler(null)
    channel = null
    executor?.shutdown()
    executor = null
  }
}
