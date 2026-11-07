package com.edde746.plezy.exoplayer

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import com.edde746.plezy.TvDetection
import java.io.File

private const val TAG = "ReelCache"

/**
 * The rules of the Reel's clip disk cache (plan V2-10, D1), kept free of Android so they can be
 * tested on the JVM.
 *
 * - Only a request whose key is a Plex clip's key ([PLEX_PREFIX]) is cached. Dart builds it from
 *   the server's id and the clip file's part path, so a new connection address or a new token
 *   still hits, and no token is ever part of it. AnimeThemes clips carry no key and stream as
 *   before (D1: they stay in memory). The main player never reaches this cache.
 * - A key that could carry a secret or a query ([isCacheable] false) is never used, and
 *   [cacheKey] strips `X-Plex-Token` from any URI it falls back to, so a token never lands in a
 *   key (the cache's database) or a file name (SimpleCache names files by a numeric id).
 * - The cap is 192 MB on a TV and 256 MB elsewhere, less when the disk is nearly full
 *   ([capBytes]); below [MIN_CAP_BYTES] there is no cache at all.
 */
internal object ClipCachePolicy {
  const val PLEX_PREFIX = "plex:"

  const val TV_CAP_BYTES: Long = 192L * 1024 * 1024
  const val PHONE_CAP_BYTES: Long = 256L * 1024 * 1024

  /** Disk space the cache always leaves free for everything else. */
  const val FREE_SPACE_RESERVE_BYTES: Long = 1024L * 1024 * 1024

  /** A smaller cap than this is not worth a cache. */
  const val MIN_CAP_BYTES: Long = 32L * 1024 * 1024

  /**
   * A clip counts as on disk (for a neighbouring deck's head, plan D15) once this much of its
   * start is cached, or all of it when it is shorter. At a trailer's usual bitrate this is a
   * few seconds, more than the head's 2 s preload.
   */
  const val ON_DISK_MIN_BYTES: Long = 4L * 1024 * 1024

  private const val MAX_KEY_LENGTH = 512

  /**
   * The cap for a device: [TV_CAP_BYTES] or [PHONE_CAP_BYTES], cut to half of what is free
   * above [FREE_SPACE_RESERVE_BYTES] when the disk is short. 0 means no cache.
   */
  fun capBytes(tv: Boolean, usableBytes: Long): Long {
    val base = if (tv) TV_CAP_BYTES else PHONE_CAP_BYTES
    val spare = (usableBytes - FREE_SPACE_RESERVE_BYTES).coerceAtLeast(0L)
    val cap = if (spare >= base * 2) base else minOf(base, spare / 2)
    return if (cap < MIN_CAP_BYTES) 0L else cap
  }

  /** Whether a request with [key] (a `DataSpec.key`) goes through the cache. */
  fun isCacheable(key: String?): Boolean {
    if (key == null || !key.startsWith(PLEX_PREFIX) || key.length <= PLEX_PREFIX.length) return false
    if (key.length > MAX_KEY_LENGTH) return false
    if ('?' in key || '&' in key || "://" in key) return false
    return !key.contains("token", ignoreCase = true)
  }

  /**
   * The cache key for [spec]: its own key when cacheable, else its URI without a token. Only a
   * cacheable request is routed to the cache ([ClipCacheDataSourceFactory]), so the fallback is
   * a safety net: whatever happens, no token is written into the cache's index.
   */
  fun cacheKey(key: String?, uri: String): String = if (isCacheable(key)) key!! else stripToken(uri)

  /** [uri] without any `X-Plex-Token` query parameter (case-insensitive name). */
  fun stripToken(uri: String): String {
    val q = uri.indexOf('?')
    if (q < 0) return uri
    val fragment = uri.indexOf('#', q).let { if (it < 0) uri.length else it }
    val kept = uri.substring(q + 1, fragment).split('&').filter { part ->
      part.isNotEmpty() && !part.substringBefore('=').equals("X-Plex-Token", ignoreCase = true)
    }
    val base = uri.substring(0, q)
    val tail = uri.substring(fragment)
    return if (kept.isEmpty()) base + tail else base + "?" + kept.joinToString("&") + tail
  }

  /**
   * Whether a clip is on disk: [cachedFromStart] contiguous bytes cached from its first byte,
   * against its [contentLength] when known (-1 / [C.LENGTH_UNSET] otherwise).
   */
  fun isOnDisk(cachedFromStart: Long, contentLength: Long): Boolean {
    if (cachedFromStart <= 0) return false
    if (contentLength > 0 && cachedFromStart >= contentLength) return true
    return cachedFromStart >= ON_DISK_MIN_BYTES
  }

  /**
   * Whether a clip's bytes on disk are dropped after a playback error with [errorCode] (a
   * `PlaybackException` code). An IO or parsing error may have come from the cached bytes (a file
   * replaced on the server, a short write), so they go. A connection that failed or timed out
   * says nothing about them: offline (plan V2-15) a clip on disk whose remainder was never cached
   * fails that way when it reaches the gap, and its bytes must stay for the next offline visit.
   * DefaultHttpDataSource and CronetDataSource both report a failed open as
   * [PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED] and a timed-out one as
   * [PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT] (media3 1.11.0, javap).
   */
  fun evictsAfter(errorCode: Int): Boolean {
    if (!isIoOrParsing(errorCode)) return false
    return errorCode != PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED &&
      errorCode != PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT
  }

  /** Whether [errorCode] is an IO (2xxx) or parsing (3xxx) `PlaybackException` code. */
  fun isIoOrParsing(errorCode: Int): Boolean = errorCode in PlaybackException.ERROR_CODE_IO_UNSPECIFIED until PlaybackException.ERROR_CODE_DECODER_INIT_FAILED

  /** A short tag for a key in log lines: the logs never carry a server id. */
  fun logId(key: String?): String = if (key == null) "none" else "%08x".format(key.hashCode())
}

/**
 * The process-wide SimpleCache under `cacheDir/reel-clips/` (plan V2-10). SimpleCache allows
 * one instance per folder, so every clip core shares this one, and it stays open for the
 * process once made (its index load is not free). LRU eviction at [ClipCachePolicy.capBytes].
 */
@OptIn(UnstableApi::class)
internal object ClipDiskCache {
  const val DIR_NAME = "reel-clips"

  private var cache: SimpleCache? = null
  private var databaseProvider: StandaloneDatabaseProvider? = null
  private var capBytes: Long = 0L

  /** Set once creating the cache failed, so a broken disk is tried once per process. */
  private var failed = false

  fun dir(context: Context): File = File(context.cacheDir, DIR_NAME)

  private fun database(context: Context): StandaloneDatabaseProvider = databaseProvider ?: StandaloneDatabaseProvider(context.applicationContext).also { databaseProvider = it }

  /** The cache, made on first use; null when the disk is too full or the cache can't open. */
  @Synchronized
  fun obtain(context: Context): Cache? {
    cache?.let { return it }
    if (failed) return null
    val dir = dir(context)
    val cap = ClipCachePolicy.capBytes(TvDetection.isTv(context), context.cacheDir.usableSpace)
    if (cap <= 0L) {
      Log.i(TAG, "[ReelCache] off: not enough free space")
      return null
    }
    return try {
      // Called on the main thread as a clip core is built. SimpleCache loads its index and scans
      // the folder on its own thread while holding the cache's lock (media3 1.11.0), so nothing
      // here reads from the cache: `cacheSpace` would wait for that whole load.
      SimpleCache(dir, LeastRecentlyUsedCacheEvictor(cap), database(context)).also {
        cache = it
        capBytes = cap
        Log.i(TAG, "[ReelCache] open cap=${cap / (1024 * 1024)}MB")
      }
    } catch (e: Exception) {
      // A second instance on the folder (it can't happen in one process) or a disk error.
      failed = true
      Log.w(TAG, "[ReelCache] off: ${e.javaClass.simpleName}")
      null
    }
  }

  /** `{bytes, capBytes}` for the settings row. Reads the folder when no core opened the cache. */
  @Synchronized
  fun usage(context: Context): Map<String, Long> {
    val open = cache
    val bytes = open?.cacheSpace ?: folderBytes(dir(context))
    val cap = if (open != null) capBytes else ClipCachePolicy.capBytes(TvDetection.isTv(context), context.cacheDir.usableSpace)
    return mapOf("bytes" to bytes, "capBytes" to cap)
  }

  /**
   * Empties the cache and returns the bytes it held. With no instance open, `SimpleCache.delete`
   * removes the folder and its index rows; with one open (a clip core is using it) every key is
   * removed through it instead, since a second SimpleCache on the folder is not allowed.
   */
  @Synchronized
  fun clear(context: Context): Long {
    val open = cache
    if (open != null) {
      val before = open.cacheSpace
      for (key in open.keys.toList()) open.removeResource(key)
      Log.i(TAG, "[ReelCache] clear keys removed, freed=${before / 1024}KB")
      return before
    }
    val dir = dir(context)
    val before = folderBytes(dir)
    if (dir.exists()) SimpleCache.delete(dir, database(context))
    Log.i(TAG, "[ReelCache] clear folder deleted, freed=${before / 1024}KB")
    return before
  }

  /** Which of [keys] are on disk ([ClipCachePolicy.isOnDisk]); none before a core opened the cache. */
  @Synchronized
  fun onDisk(keys: List<String>): List<String> {
    val open = cache ?: return emptyList()
    return keys.filter { key ->
      ClipCachePolicy.isCacheable(key) &&
        ClipCachePolicy.isOnDisk(
          open.getCachedLength(key, 0, C.LENGTH_UNSET.toLong()),
          ContentMetadata.getContentLength(open.getContentMetadata(key))
        )
    }
  }

  /** Drops [key]'s bytes (a clip that failed to play from them). */
  @Synchronized
  fun evict(key: String) {
    val open = cache ?: return
    if (!ClipCachePolicy.isCacheable(key)) return
    open.removeResource(key)
  }

  @VisibleForTesting
  @Synchronized
  fun resetForTest() {
    cache?.release()
    cache = null
    databaseProvider = null
    capBytes = 0L
    failed = false
  }

  private fun folderBytes(dir: File): Long = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
}

/**
 * The clip core's data source (plan V2-10): a request with a Plex clip key reads and writes the
 * disk cache, any other request (AnimeThemes, the main player never comes here) goes straight
 * to [upstream]. A cache read error falls back to the network.
 *
 * Wired by hand because `DefaultPreloadManager.Builder.setCache` does not reach a caller's own
 * media source factory (media3 1.11.0, javap: the supplier `setMediaSourceFactory` installs has
 * a no-op `setCache`); the Builder's cache is used only for the pre-cache stage.
 */
@OptIn(UnstableApi::class)
internal class ClipCacheDataSourceFactory(
  val cache: Cache,
  private val upstream: DataSource.Factory,
  eventListener: CacheDataSource.EventListener? = null
) : DataSource.Factory {
  /**
   * [upstream] for every request that writes [cache], here and in the preload manager's
   * pre-cache stage: it reports each request's own URI, never a redirect's target
   * ([RequestUriDataSource]).
   */
  val cacheUpstream: DataSource.Factory = RequestUriDataSource.Factory(upstream)

  private val cached = CacheDataSource.Factory()
    .setCache(cache)
    .setUpstreamDataSourceFactory(cacheUpstream)
    .setCacheKeyFactory(KEY_FACTORY)
    .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    .setEventListener(eventListener)

  override fun createDataSource(): DataSource = ClipCacheRoutingDataSource(cached::createDataSource, upstream::createDataSource)

  companion object {
    val KEY_FACTORY = CacheKeyFactory { spec -> ClipCachePolicy.cacheKey(spec.key, spec.uri.toString()) }
  }
}

/**
 * Opens each request on a source from [cached] or [direct], by its key
 * ([ClipCachePolicy.isCacheable]). Each source is made on its first open, so a request never
 * builds the path it doesn't take.
 */
@OptIn(UnstableApi::class)
internal class ClipCacheRoutingDataSource(private val cached: () -> DataSource, private val direct: () -> DataSource) : DataSource {
  private val listeners = mutableListOf<TransferListener>()
  private var cachedSource: DataSource? = null
  private var directSource: DataSource? = null
  private var active: DataSource? = null

  /** Whether the open request went through the cache (for tests). */
  val isCachedRequest: Boolean get() = active != null && active === cachedSource

  override fun addTransferListener(transferListener: TransferListener) {
    listeners += transferListener
    cachedSource?.addTransferListener(transferListener)
    directSource?.addTransferListener(transferListener)
  }

  private fun make(factory: () -> DataSource): DataSource = factory().also { source -> listeners.forEach(source::addTransferListener) }

  override fun open(dataSpec: DataSpec): Long {
    val target = if (ClipCachePolicy.isCacheable(dataSpec.key)) {
      cachedSource ?: make(cached).also { cachedSource = it }
    } else {
      directSource ?: make(direct).also { directSource = it }
    }
    active = target
    return target.open(dataSpec)
  }

  override fun read(buffer: ByteArray, offset: Int, length: Int): Int = checkNotNull(active).read(buffer, offset, length)

  override fun getUri(): Uri? = active?.uri

  override fun getResponseHeaders(): Map<String, List<String>> = active?.responseHeaders ?: emptyMap()

  override fun close() {
    val source = active ?: return
    try {
      source.close()
    } finally {
      active = null
    }
  }
}

/**
 * [upstream], reporting each request's own URI as its URI and never where a redirect took it
 * (plan V2-10). CacheDataSource keeps an upstream's redirect target in the cache's index (the
 * `exo_redir` metadata, media3 1.11.0) whenever it differs from the request's URI, so a server
 * or proxy redirect that kept the query would write the token and an address there. Nothing
 * else changes: CacheDataSource asks its upstream for the request's own URI on every open (the
 * target is only ever reported), and the bytes are the same.
 */
@OptIn(UnstableApi::class)
internal class RequestUriDataSource(private val upstream: DataSource) : DataSource {
  private var requestUri: Uri? = null

  override fun addTransferListener(transferListener: TransferListener) {
    upstream.addTransferListener(transferListener)
  }

  override fun open(dataSpec: DataSpec): Long {
    requestUri = dataSpec.uri
    return upstream.open(dataSpec)
  }

  override fun read(buffer: ByteArray, offset: Int, length: Int): Int = upstream.read(buffer, offset, length)

  override fun getUri(): Uri? = requestUri

  override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

  override fun close() {
    requestUri = null
    upstream.close()
  }

  class Factory(private val upstream: DataSource.Factory) : DataSource.Factory {
    override fun createDataSource(): DataSource = RequestUriDataSource(upstream.createDataSource())
  }
}
