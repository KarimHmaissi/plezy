package com.edde746.plezy.cast

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.edde746.plezy.TvDetection
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.HlsSegmentFormat
import com.google.android.gms.cast.HlsVideoSegmentFormat
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.images.WebImage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Fork: Google Cast sender for phones, over the official Cast SDK.
 *
 * Dart owns the picker UI, so devices come from MediaRouter directly (the same routes the
 * stock Cast dialog lists) and selecting one hands the route to the Cast framework, which
 * opens the [CastSession]. Media loads into Google's Default Media Receiver; Dart builds the
 * stream URL (see `PlexClient.buildCastStream`).
 *
 * Native → Dart: `onRoutes` (devices found while discovering), `onSession` (none / connecting /
 * connected, with the device name) and `onMedia` (the receiver's player state and position,
 * plus the custom data the load carried, so a resumed session can pick up its title again).
 *
 * Not available on TVs (they are cast targets, not senders) or without Google Play services
 * (Fire OS); [init] then answers false and the Dart side hides every Cast surface.
 */
internal class GoogleCastChannel(private val context: Context) {
  companion object {
    private const val TAG = "GoogleCastChannel"
    private const val CHANNEL = "com.plezy/google_cast"
    private const val PROGRESS_INTERVAL_MS = 1000L
  }

  private var channel: MethodChannel? = null
  private var castContext: CastContext? = null
  private var initStarted = false
  private val pendingInit = mutableListOf<MethodChannel.Result>()
  private var discovering = false
  private var mediaClient: RemoteMediaClient? = null

  private val router: MediaRouter by lazy { MediaRouter.getInstance(context) }

  private val selector: MediaRouteSelector
    get() = castContext?.mergedSelector ?: MediaRouteSelector.Builder()
      .addControlCategory(
        CastMediaControlIntent.categoryForCast(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
      )
      .build()

  fun attach(messenger: BinaryMessenger) {
    channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(::onMethodCall) }
  }

  fun dispose() {
    stopDiscovery()
    detachMediaClient()
    castContext?.sessionManager?.removeSessionManagerListener(sessionListener, CastSession::class.java)
    channel?.setMethodCallHandler(null)
    channel = null
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method == "init") {
      init(result)
      return
    }
    val cast = castContext
    if (cast == null) {
      result.error("unavailable", "Google Cast is not available on this device", null)
      return
    }
    when (call.method) {
      "startDiscovery" -> {
        startDiscovery()
        result.success(null)
      }
      "stopDiscovery" -> {
        stopDiscovery()
        result.success(null)
      }
      "selectRoute" -> {
        val id = call.argument<String>("id")
        val route = router.routes.firstOrNull { it.id == id }
        if (route == null) {
          result.error("not_found", "That device is no longer available", null)
        } else {
          router.selectRoute(route)
          result.success(null)
        }
      }
      "endSession" -> {
        cast.sessionManager.endCurrentSession(call.argument<Boolean>("stopCasting") ?: true)
        result.success(null)
      }
      "getState" -> {
        pushSession()
        pushMedia()
        result.success(null)
      }
      "load" -> load(call, result)
      "play" -> withMedia(result) { it.play() }
      "pause" -> withMedia(result) { it.pause() }
      "stop" -> withMedia(result) { it.stop() }
      "seek" -> {
        val position = call.argument<Number>("positionMs")?.toLong() ?: 0L
        withMedia(result) { it.seek(MediaSeekOptions.Builder().setPosition(position).build()) }
      }
      else -> result.notImplemented()
    }
  }

  private fun init(result: MethodChannel.Result) {
    if (castContext != null) {
      result.success(true)
      return
    }
    if (TvDetection.isTv(context) ||
      GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) != ConnectionResult.SUCCESS
    ) {
      result.success(false)
      return
    }
    pendingInit += result
    if (initStarted) return
    initStarted = true
    CastContext.getSharedInstance(context, Executors.newSingleThreadExecutor())
      .addOnSuccessListener { cast ->
        castContext = cast
        cast.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
        // A session the framework resumed (app restarted while casting) is live already.
        cast.sessionManager.currentCastSession?.takeIf { it.isConnected }?.let { attachMediaClient(it) }
        completeInit(true)
      }
      .addOnFailureListener { error ->
        Log.w(TAG, "Cast framework unavailable", error)
        initStarted = false
        completeInit(false)
      }
  }

  private fun completeInit(available: Boolean) {
    val waiting = pendingInit.toList()
    pendingInit.clear()
    waiting.forEach { it.success(available) }
  }

  // Discovery

  private val routerCallback = object : MediaRouter.Callback() {
    override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = pushRoutes()
    override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = pushRoutes()
    override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = pushRoutes()
  }

  private fun startDiscovery() {
    if (discovering) return
    discovering = true
    router.addCallback(
      selector,
      routerCallback,
      MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY or MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN
    )
    pushRoutes()
  }

  private fun stopDiscovery() {
    if (!discovering) return
    discovering = false
    router.removeCallback(routerCallback)
  }

  private fun pushRoutes() {
    val current = selector
    val routes = router.routes
      .filter { !it.isDefaultOrBluetooth && it.isEnabled && it.matchesSelector(current) }
      .map {
        mapOf(
          "id" to it.id,
          "name" to it.name,
          "description" to (it.description ?: ""),
          "selected" to it.isSelected
        )
      }
    channel?.invokeMethod("onRoutes", routes)
  }

  // Session

  private val sessionListener = object : SessionManagerListener<CastSession> {
    override fun onSessionStarting(session: CastSession) = pushSession("connecting", session)
    override fun onSessionStarted(session: CastSession, sessionId: String) {
      attachMediaClient(session)
      pushSession()
    }
    override fun onSessionStartFailed(session: CastSession, error: Int) = sessionEnded(error)
    override fun onSessionEnding(session: CastSession) {}
    override fun onSessionEnded(session: CastSession, error: Int) = sessionEnded(error)
    override fun onSessionResuming(session: CastSession, sessionId: String) = pushSession("connecting", session)
    override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
      attachMediaClient(session)
      pushSession()
    }
    override fun onSessionResumeFailed(session: CastSession, error: Int) = sessionEnded(error)
    override fun onSessionSuspended(session: CastSession, reason: Int) = pushSession("connecting", session)
  }

  private fun sessionEnded(error: Int) {
    detachMediaClient()
    channel?.invokeMethod("onSession", mapOf("state" to "none", "error" to error))
  }

  private fun pushSession(state: String? = null, session: CastSession? = null) {
    val current = session ?: castContext?.sessionManager?.currentCastSession
    val resolved = state ?: if (current?.isConnected == true) "connected" else "none"
    channel?.invokeMethod(
      "onSession",
      mapOf("state" to resolved, "device" to current?.castDevice?.friendlyName)
    )
  }

  // Media

  private val mediaCallback = object : RemoteMediaClient.Callback() {
    override fun onStatusUpdated() = pushMedia()
    override fun onMetadataUpdated() = pushMedia()
  }

  private val progressListener = RemoteMediaClient.ProgressListener { _, _ -> pushMedia() }

  private fun attachMediaClient(session: CastSession) {
    val client = session.remoteMediaClient ?: return
    if (client === mediaClient) return
    detachMediaClient()
    mediaClient = client
    client.registerCallback(mediaCallback)
    client.addProgressListener(progressListener, PROGRESS_INTERVAL_MS)
    pushMedia()
  }

  private fun detachMediaClient() {
    mediaClient?.unregisterCallback(mediaCallback)
    mediaClient?.removeProgressListener(progressListener)
    mediaClient = null
  }

  private fun pushMedia() {
    val client = mediaClient
    val status = client?.mediaStatus
    val info = client?.mediaInfo
    if (client == null || status == null || info == null) {
      channel?.invokeMethod("onMedia", null)
      return
    }
    channel?.invokeMethod(
      "onMedia",
      mapOf(
        "state" to when (status.playerState) {
          MediaStatus.PLAYER_STATE_PLAYING -> "playing"
          MediaStatus.PLAYER_STATE_PAUSED -> "paused"
          MediaStatus.PLAYER_STATE_BUFFERING, MediaStatus.PLAYER_STATE_LOADING -> "buffering"
          MediaStatus.PLAYER_STATE_IDLE -> "idle"
          else -> "unknown"
        },
        "idleReason" to when (status.idleReason) {
          MediaStatus.IDLE_REASON_FINISHED -> "finished"
          MediaStatus.IDLE_REASON_CANCELED -> "cancelled"
          MediaStatus.IDLE_REASON_INTERRUPTED -> "interrupted"
          MediaStatus.IDLE_REASON_ERROR -> "error"
          else -> null
        },
        "positionMs" to client.approximateStreamPosition,
        "durationMs" to client.streamDuration,
        "customData" to info.customData?.toString()
      )
    )
  }

  private fun withMedia(result: MethodChannel.Result, action: (RemoteMediaClient) -> Unit) {
    val client = mediaClient
    if (client == null) {
      result.error("no_session", "Nothing is casting", null)
      return
    }
    action(client)
    result.success(null)
  }

  /**
   * Load an HLS stream into the receiver. Plex's Cast stream is MPEG-TS segments (H.264 + AAC),
   * which is also the Default Media Receiver's assumption when no segment format is given; it is
   * stated anyway so the receiver never has to guess.
   */
  private fun load(call: MethodCall, result: MethodChannel.Result) {
    val session = castContext?.sessionManager?.currentCastSession
    val client = session?.remoteMediaClient
    if (session == null || !session.isConnected || client == null) {
      result.error("no_session", "No Cast device is connected", null)
      return
    }
    attachMediaClient(session)
    val url = call.argument<String>("url")
    if (url.isNullOrEmpty()) {
      result.error("bad_args", "No stream URL", null)
      return
    }
    val metadata = MediaMetadata(
      if (call.argument<Boolean>("episode") == true) MediaMetadata.MEDIA_TYPE_TV_SHOW else MediaMetadata.MEDIA_TYPE_MOVIE
    ).apply {
      call.argument<String>("title")?.let { putString(MediaMetadata.KEY_TITLE, it) }
      call.argument<String>("subtitle")?.let {
        putString(MediaMetadata.KEY_SUBTITLE, it)
        if (call.argument<Boolean>("episode") == true) putString(MediaMetadata.KEY_SERIES_TITLE, it)
      }
      call.argument<String>("imageUrl")?.takeIf { it.isNotEmpty() }?.let { addImage(WebImage(Uri.parse(it))) }
    }
    val info = MediaInfo.Builder(url)
      .setContentUrl(url)
      .setContentType("application/x-mpegURL")
      .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
      .setHlsSegmentFormat(HlsSegmentFormat.TS)
      .setHlsVideoSegmentFormat(HlsVideoSegmentFormat.MPEG2_TS)
      .setMetadata(metadata)
      .apply {
        call.argument<Number>("durationMs")?.toLong()?.takeIf { it > 0 }?.let { setStreamDuration(it) }
        call.argument<Map<String, Any?>>("customData")?.let { setCustomData(JSONObject(it)) }
      }
      .build()
    val request = MediaLoadRequestData.Builder()
      .setMediaInfo(info)
      .setAutoplay(true)
      .setCurrentTime(call.argument<Number>("startMs")?.toLong() ?: 0L)
      .build()
    client.load(request).setResultCallback { loaded ->
      if (loaded.status.isSuccess) {
        result.success(null)
      } else {
        result.error("load_failed", loaded.status.statusMessage ?: "The Cast device could not play this", loaded.status.statusCode)
      }
    }
  }
}
