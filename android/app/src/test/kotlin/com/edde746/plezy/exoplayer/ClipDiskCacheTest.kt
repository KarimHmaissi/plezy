package com.edde746.plezy.exoplayer

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.source.preload.DefaultPreloadManager
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * V2-10. The clip core's disk cache: only Plex clips with a key reach it, the token never lands
 * in a key, the cap follows the device and the free space, and the preload ranks pick disk or
 * memory as the plan says.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ClipDiskCacheTest {
  private val mib = 1024L * 1024
  private val key = "plex:server-a:/library/parts/41/1700000000/file.mp4"
  private val plexUri = "https://server-a.invalid:32400/library/parts/41/1700000000/file.mp4?X-Plex-Token=abc123"
  private val themeUri = "https://themes.invalid/video/opening-1.webm"

  private lateinit var dir: File
  private lateinit var cache: SimpleCache

  @Before
  fun setUp() {
    dir = Files.createTempDirectory("reel-clips").toFile()
    val context = RuntimeEnvironment.getApplication()
    cache = SimpleCache(dir, LeastRecentlyUsedCacheEvictor(64 * mib), StandaloneDatabaseProvider(context))
  }

  @After
  fun tearDown() {
    cache.release()
    dir.deleteRecursively()
    ClipDiskCache.resetForTest()
  }

  // --- policy -------------------------------------------------------------

  @Test
  fun theCapIsSmallerOnTheTvAndShrinksWhenTheDiskIsShort() {
    val plenty = 64L * 1024 * mib
    assertEquals(192 * mib, ClipCachePolicy.capBytes(tv = true, usableBytes = plenty))
    assertEquals(256 * mib, ClipCachePolicy.capBytes(tv = false, usableBytes = plenty))
    // 1 GiB reserve, then half of what is left.
    assertEquals(100 * mib, ClipCachePolicy.capBytes(tv = false, usableBytes = 1024 * mib + 200 * mib))
    assertEquals(0L, ClipCachePolicy.capBytes(tv = true, usableBytes = 1024 * mib + 40 * mib))
    assertEquals(0L, ClipCachePolicy.capBytes(tv = true, usableBytes = 0L))
  }

  @Test
  fun onlyAPlexClipKeyWithoutASecretIsCacheable() {
    assertTrue(ClipCachePolicy.isCacheable(key))
    // Dart keeps an IVA part's own query as `;` pairs (ReelClipCache.keyFor).
    assertTrue(ClipCachePolicy.isCacheable("plex:server-a:/services/iva/assets/87/video.mp4;bitrate=5000;fmt=4"))
    assertFalse(ClipCachePolicy.isCacheable(null))
    assertFalse(ClipCachePolicy.isCacheable("plex:"))
    assertFalse(ClipCachePolicy.isCacheable("at:opening-1"))
    assertFalse(ClipCachePolicy.isCacheable(themeUri))
    assertFalse(ClipCachePolicy.isCacheable("plex:$plexUri"))
    assertFalse(ClipCachePolicy.isCacheable("plex:server-a:/x?X-Plex-Token=abc123"))
    assertFalse(ClipCachePolicy.isCacheable("plex:server-a:/x&token=abc123"))
    assertFalse(ClipCachePolicy.isCacheable("plex:server-a:/x/TOKEN/abc123"))
    assertFalse(ClipCachePolicy.isCacheable("plex:" + "x".repeat(600)))
  }

  @Test
  fun aUriFallbackNeverKeepsTheToken() {
    assertEquals(
      "https://server-a.invalid:32400/library/parts/41/1700000000/file.mp4",
      ClipCachePolicy.stripToken(plexUri)
    )
    assertEquals(
      "https://server-a.invalid/p.mp4?a=1&b=2#t",
      ClipCachePolicy.stripToken("https://server-a.invalid/p.mp4?a=1&x-plex-token=abc123&b=2#t")
    )
    assertEquals(themeUri, ClipCachePolicy.stripToken(themeUri))
    assertEquals(key, ClipCachePolicy.cacheKey(key, plexUri))
    assertFalse(ClipCachePolicy.cacheKey(null, plexUri).contains("abc123"))
    assertFalse(ClipCachePolicy.cacheKey("plex:bad?X-Plex-Token=abc123", plexUri).contains("abc123"))
  }

  @Test
  fun aClipIsOnDiskOnceItsStartOrAllOfItIsCached() {
    assertFalse(ClipCachePolicy.isOnDisk(0, C.LENGTH_UNSET.toLong()))
    assertFalse(ClipCachePolicy.isOnDisk(1 * mib, C.LENGTH_UNSET.toLong()))
    assertTrue(ClipCachePolicy.isOnDisk(4 * mib, C.LENGTH_UNSET.toLong()))
    assertTrue("a short clip cached whole", ClipCachePolicy.isOnDisk(2 * mib, 2 * mib))
    assertFalse(ClipCachePolicy.isOnDisk(2 * mib, 3 * mib))
  }

  @Test
  fun aFailedOrTimedOutConnectionKeepsTheBytesOnDisk() {
    // V2-15: offline, a clip on disk whose remainder was never cached fails this way.
    assertFalse(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED))
    assertFalse(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT))
    // An error that may have come from the bytes themselves drops them (V2-10).
    assertTrue(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_IO_UNSPECIFIED))
    assertTrue(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS))
    assertTrue(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE))
    assertTrue(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED))
    // Decoding and anything else never touch the cache.
    assertFalse(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED))
    assertFalse(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_DECODING_FAILED))
    assertFalse(ClipCachePolicy.evictsAfter(PlaybackException.ERROR_CODE_UNSPECIFIED))
  }

  @Test
  fun logIdsNeverCarryTheKey() {
    assertFalse(ClipCachePolicy.logId(key).contains("server-a"))
    assertEquals("none", ClipCachePolicy.logId(null))
  }

  // --- routing ------------------------------------------------------------

  private val bytes = ByteArray(64 * 1024) { (it % 251).toByte() }

  private fun readAll(source: DataSource, spec: DataSpec): ByteArray {
    source.open(spec)
    val out = java.io.ByteArrayOutputStream()
    val buf = ByteArray(8 * 1024)
    while (true) {
      val n = source.read(buf, 0, buf.size)
      if (n == C.RESULT_END_OF_INPUT) break
      out.write(buf, 0, n)
    }
    source.close()
    return out.toByteArray()
  }

  /** An upstream that counts the requests it opens (the network). */
  private inner class Counting : DataSource.Factory {
    var opens = 0

    override fun createDataSource(): DataSource {
      val inner = ByteArrayDataSource(bytes)
      return object : DataSource by inner {
        override fun open(dataSpec: DataSpec): Long {
          opens++
          return inner.open(dataSpec)
        }
      }
    }
  }

  @Test
  fun aPlexClipIsWrittenUnderItsKeyAndReadBackWithoutTheNetwork() {
    val upstream = Counting()
    val factory = ClipCacheDataSourceFactory(cache, upstream)
    val spec = DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).build()

    val first = factory.createDataSource() as ClipCacheRoutingDataSource
    assertArrayEquals(bytes, readAll(first, spec))
    assertEquals(1, upstream.opens)
    assertEquals(setOf(key), cache.keys)
    assertEquals(bytes.size.toLong(), cache.getCachedBytes(key, 0, C.LENGTH_UNSET.toLong()))

    // Another connection address and token: the same key, so the same bytes, from disk.
    val moved = DataSpec.Builder().setUri(Uri.parse("https://server-a-relay.invalid/library/parts/41/1700000000/file.mp4?X-Plex-Token=zzz")).setKey(key).build()
    assertArrayEquals(bytes, readAll(factory.createDataSource(), moved))
    assertEquals("the network was not asked again", 1, upstream.opens)
  }

  /** The network while offline: every open fails as a connection that couldn't be made. */
  private inner class Offline : DataSource.Factory {
    var opens = 0

    override fun createDataSource(): DataSource {
      val inner = ByteArrayDataSource(bytes)
      return object : DataSource by inner {
        override fun open(dataSpec: DataSpec): Long {
          opens++
          throw HttpDataSource.HttpDataSourceException.createForIOException(
            java.net.UnknownHostException(dataSpec.uri.host),
            dataSpec,
            HttpDataSource.HttpDataSourceException.TYPE_OPEN
          )
        }
      }
    }
  }

  @Test
  fun offlineAClipOnDiskPlaysFromItsKeyAtAnAddressThatNeverResolves() {
    // Cached online, under its key.
    readAll(ClipCacheDataSourceFactory(cache, Counting()).createDataSource(), DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).build())

    // V2-15: offline Dart opens it at ClipResolver.offlineUri; the bytes come from disk alone.
    val offline = Offline()
    val factory = ClipCacheDataSourceFactory(cache, offline)
    val spec = DataSpec.Builder().setUri(Uri.parse("https://reel-offline.invalid/library/parts/41/1700000000/file.mp4")).setKey(key).build()
    assertArrayEquals(bytes, readAll(factory.createDataSource(), spec))
    assertEquals("the network was never asked", 0, offline.opens)
  }

  @Test
  fun offlineTheUncachedRestFailsAsAConnectionErrorThatKeepsTheBytes() {
    // Only the start was cached online (a clip left early, or the card two ahead).
    val head = 16 * 1024L
    val online = CacheDataSource.Factory().setCache(cache).setUpstreamDataSourceFactory(Counting()).setCacheKeyFactory(ClipCacheDataSourceFactory.KEY_FACTORY)
    CacheWriter(online.createDataSource(), DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).setLength(head).build(), null, null).cache()
    assertEquals(head, cache.getCachedBytes(key, 0, C.LENGTH_UNSET.toLong()))

    val offline = Offline()
    val source = ClipCacheDataSourceFactory(cache, offline).createDataSource()
    val spec = DataSpec.Builder().setUri(Uri.parse("https://reel-offline.invalid/library/parts/41/1700000000/file.mp4")).setKey(key).build()
    try {
      readAll(source, spec)
      fail("the uncached rest can't be read offline")
    } catch (e: HttpDataSource.HttpDataSourceException) {
      assertEquals(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED, e.reason)
      assertFalse("so the bytes on disk stay", ClipCachePolicy.evictsAfter(e.reason))
    } finally {
      source.close()
    }
    assertEquals(head, cache.getCachedBytes(key, 0, C.LENGTH_UNSET.toLong()))
  }

  @Test
  fun aClipWithoutAKeyStreamsAndIsNeverCached() {
    val factory = ClipCacheDataSourceFactory(cache, { ByteArrayDataSource(bytes) })
    val source = factory.createDataSource() as ClipCacheRoutingDataSource
    val spec = DataSpec.Builder().setUri(Uri.parse(themeUri)).build()
    source.open(spec)
    assertFalse(source.isCachedRequest)
    source.close()
    val plexWithoutKey = DataSpec.Builder().setUri(Uri.parse(plexUri)).build()
    assertArrayEquals(bytes, readAll(factory.createDataSource(), plexWithoutKey))
    assertTrue("nothing reaches the cache, so no URI and no token is ever a key", cache.keys.isEmpty())
  }

  @Test
  fun noKeyEverHoldsTheToken() {
    val factory = ClipCacheDataSourceFactory(cache, { ByteArrayDataSource(bytes) })
    readAll(factory.createDataSource(), DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).build())
    readAll(factory.createDataSource(), DataSpec.Builder().setUri(Uri.parse(plexUri)).build())
    for (k in cache.keys) assertFalse(k, k.contains("abc123") || k.contains("Token", ignoreCase = true))
    // File names are numeric ids, never the key or the URI.
    dir.walkTopDown().filter { it.isFile }.forEach { assertFalse(it.name, it.name.contains("abc123") || it.name.contains("server-a")) }
  }

  /** An upstream whose server redirected the request: it reports another address, with the token. */
  private inner class Redirecting : DataSource.Factory {
    val target: Uri = Uri.parse("https://server-a-edge.invalid/library/parts/41/1700000000/file.mp4?X-Plex-Token=abc123")

    override fun createDataSource(): DataSource {
      val inner = ByteArrayDataSource(bytes)
      return object : DataSource by inner {
        override fun getUri(): Uri? = inner.uri?.let { target }
      }
    }
  }

  @Test
  fun aRedirectTargetNeverLandsInTheCacheIndex() {
    val factory = ClipCacheDataSourceFactory(cache, Redirecting())
    val spec = DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).build()
    assertArrayEquals(bytes, readAll(factory.createDataSource(), spec))
    assertEquals(bytes.size.toLong(), cache.getCachedBytes(key, 0, C.LENGTH_UNSET.toLong()))
    assertNull("no redirect target, so no token or address, in the index", ContentMetadata.getRedirectedUri(cache.getContentMetadata(key)))
  }

  @Test
  fun thePreCacheStageKeepsNoRedirectTargetEither() {
    val factory = ClipCacheDataSourceFactory(cache, Redirecting())
    // What the preload manager's pre-cache stage builds from Builder.setCache and
    // setDataSourceFactory (media3 1.11.0, PreCacheHelper.Factory): a plain CacheDataSource
    // over the upstream it was given, written by a CacheWriter.
    val preCache = CacheDataSource.Factory().setCache(factory.cache).setUpstreamDataSourceFactory(factory.cacheUpstream)
    val spec = DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).build()
    CacheWriter(preCache.createDataSource(), spec, null, null).cache()
    assertEquals(bytes.size.toLong(), cache.getCachedBytes(key, 0, C.LENGTH_UNSET.toLong()))
    assertNull(ContentMetadata.getRedirectedUri(cache.getContentMetadata(key)))
  }

  // --- ranks --------------------------------------------------------------

  @Test
  fun theCardTwoAheadAndAPlexHeadGoToDiskTheNearCardsStayInMemory() {
    assertTrue(ClipPreloadRank.AHEAD.usesDisk(cacheable = true))
    assertTrue(ClipPreloadRank.DECK_NEXT.usesDisk(cacheable = true))
    assertTrue(ClipPreloadRank.DECK_PREVIOUS.usesDisk(cacheable = true))
    assertFalse(ClipPreloadRank.NEXT.usesDisk(cacheable = true))
    assertFalse(ClipPreloadRank.PREVIOUS.usesDisk(cacheable = true))
    for (rank in ClipPreloadRank.entries) assertFalse("$rank without a key", rank.usesDisk(cacheable = false))
    assertTrue(ClipPreloadRank.AHEAD.cachedOnly)

    val ahead = ClipPreloadRank.status(ClipPreloadRank.AHEAD.rankingData(onDisk = true))
    assertEquals(DefaultPreloadManager.PreloadStatus.STAGE_SPECIFIED_RANGE_CACHED, ahead.stage)
    assertEquals(5_000L, ahead.durationMs)
    val head = ClipPreloadRank.status(ClipPreloadRank.DECK_NEXT.rankingData(onDisk = true))
    assertEquals(DefaultPreloadManager.PreloadStatus.STAGE_SPECIFIED_RANGE_CACHED, head.stage)
    assertEquals(2_000L, head.durationMs)
    val themeHead = ClipPreloadRank.status(ClipPreloadRank.DECK_NEXT.rankingData(onDisk = false))
    assertEquals(DefaultPreloadManager.PreloadStatus.STAGE_SPECIFIED_RANGE_LOADED, themeHead.stage)
  }

  @Test
  fun everyDiskPreloadSortsAfterEveryMemoryOne() {
    val comparator = DefaultPreloadManager.SimpleRankingDataComparator()
    comparator.setCurrentPlayingIndex(ClipPreloadRank.PLAYING_INDEX)
    val data = listOf(
      ClipPreloadRank.AHEAD.rankingData(onDisk = true),
      ClipPreloadRank.DECK_NEXT.rankingData(onDisk = true),
      ClipPreloadRank.DECK_PREVIOUS.rankingData(onDisk = false),
      ClipPreloadRank.NEXT.rankingData(onDisk = false)
    ).shuffled().sortedWith { x, y -> comparator.compare(x, y) }
    assertEquals(listOf(false, false, true, true), data.map(ClipPreloadRank::isCachedRankingData))
    assertEquals(ClipPreloadRank.NEXT, ClipPreloadRank.ofRankingData(data.first()))
  }

  // --- the process-wide cache ---------------------------------------------

  @Test
  fun clearEmptiesTheCacheWhetherOrNotACoreHasItOpen() {
    val context = RuntimeEnvironment.getApplication()
    val open = ClipDiskCache.obtain(context)!!
    readAll(ClipCacheDataSourceFactory(open, { ByteArrayDataSource(bytes) }).createDataSource(), DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).build())
    assertEquals(bytes.size.toLong(), ClipDiskCache.usage(context)["bytes"])
    assertTrue(ClipDiskCache.usage(context)["capBytes"]!! > 0)
    assertEquals(bytes.size.toLong(), ClipDiskCache.clear(context))
    assertEquals(0L, ClipDiskCache.usage(context)["bytes"])
    assertTrue(open.keys.isEmpty())

    // Not open in this process: SimpleCache.delete removes the folder.
    ClipDiskCache.resetForTest()
    File(ClipDiskCache.dir(context), "stray.v3.exo").apply { parentFile?.mkdirs() }.writeBytes(ByteArray(10))
    assertEquals(10L, ClipDiskCache.clear(context))
    assertFalse(ClipDiskCache.dir(context).exists())
  }

  @Test
  fun aClipCountsAsOnDiskOnlyOnceItIsCachedAndAnEvictionDropsIt() {
    val context = RuntimeEnvironment.getApplication()
    assertTrue("nothing before a core opened the cache", ClipDiskCache.onDisk(listOf(key)).isEmpty())
    val open = ClipDiskCache.obtain(context)!!
    assertTrue(ClipDiskCache.onDisk(listOf(key)).isEmpty())
    readAll(ClipCacheDataSourceFactory(open, { ByteArrayDataSource(bytes) }).createDataSource(), DataSpec.Builder().setUri(Uri.parse(plexUri)).setKey(key).build())
    // 64 KiB cached whole (its length is known): on disk.
    assertEquals(listOf(key), ClipDiskCache.onDisk(listOf(key, "plex:server-a:/other", themeUri)))
    ClipDiskCache.evict(key)
    assertTrue(ClipDiskCache.onDisk(listOf(key)).isEmpty())
  }
}
