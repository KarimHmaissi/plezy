package com.edde746.plezy.exoplayer

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.ByteArrayDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import java.io.InterruptedIOException
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * V2-23. The detector's extractor opens requests with no key (media3-inspector 1.11.0
 * `MediaExtractorCompatInternal.buildDataSpec`: URI, position and flags 6 only). Every one must
 * reach the clip cache under the clip's key, or each detector read would go to the server.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class KeyedDataSourceTest {
  private val key = "plex:server-a:/library/parts/41/1700000000/file.mp4"
  private val uri = Uri.parse("https://server-a.invalid:32400/library/parts/41/1700000000/file.mp4?X-Plex-Token=abc123")
  private val bytes = ByteArray(64 * 1024) { (it % 251).toByte() }

  private lateinit var dir: File
  private lateinit var cache: SimpleCache

  @Before
  fun setUp() {
    dir = Files.createTempDirectory("reel-clips").toFile()
    cache = SimpleCache(dir, LeastRecentlyUsedCacheEvictor(64L * 1024 * 1024), StandaloneDatabaseProvider(RuntimeEnvironment.getApplication()))
  }

  @After
  fun tearDown() {
    cache.release()
    dir.deleteRecursively()
  }

  /** The extractor's own request: position-only, no key, flags 6. */
  private fun extractorSpec(position: Long = 0L) = DataSpec.Builder().setUri(uri).setPosition(position).setFlags(6).build()

  private class Capturing(private val inner: DataSource.Factory) : DataSource.Factory {
    var made: ClipCacheRoutingDataSource? = null

    override fun createDataSource(): DataSource = (inner.createDataSource() as ClipCacheRoutingDataSource).also { made = it }
  }

  private fun read(source: DataSource, spec: DataSpec): Int {
    source.open(spec)
    var total = 0
    val buf = ByteArray(4096)
    while (true) {
      val n = source.read(buf, 0, buf.size)
      if (n == C.RESULT_END_OF_INPUT) break
      total += n
    }
    source.close()
    return total
  }

  @Test
  fun everyKeylessExtractorRequestReachesTheCacheUnderTheClipsKey() {
    val capturing = Capturing(ClipCacheDataSourceFactory(cache, { ByteArrayDataSource(bytes) }))
    val read = AtomicLong()
    val keyed = KeyedDataSourceFactory(capturing, key, bytesRead = read)
    val source = keyed.createDataSource()
    source.open(extractorSpec())
    assertTrue("the request went through the cache", capturing.made!!.isCachedRequest)
    source.close()

    assertEquals(bytes.size, read(keyed.createDataSource(), extractorSpec()))
    assertEquals(bytes.size.toLong(), cache.getCachedBytes(key, 0, C.LENGTH_UNSET.toLong()))
    assertEquals(setOf(key), cache.keys)
    assertEquals(bytes.size.toLong(), read.get())
    assertEquals("the position follows the reads", bytes.size.toLong(), keyed.position.get())
  }

  @Test
  fun aKeyThatIsNotAPlexClipKeyNeverRoutesToTheCache() {
    val capturing = Capturing(ClipCacheDataSourceFactory(cache, { ByteArrayDataSource(bytes) }))
    val source = KeyedDataSourceFactory(capturing, "theme:opening-1").createDataSource()
    source.open(extractorSpec())
    assertFalse(capturing.made!!.isCachedRequest)
    source.close()
    assertTrue(cache.keys.isEmpty())
  }

  @Test
  fun aCancelLandsAtTheNextRead() {
    var cancelled = false
    val source = KeyedDataSourceFactory(ClipCacheDataSourceFactory(cache, { ByteArrayDataSource(bytes) }), key, { cancelled }).createDataSource()
    source.open(extractorSpec())
    val buf = ByteArray(1024)
    assertTrue(source.read(buf, 0, buf.size) > 0)
    cancelled = true
    try {
      source.read(buf, 0, buf.size)
      fail("a cancelled read must throw")
    } catch (_: InterruptedIOException) {
    }
    source.close()
  }
}
