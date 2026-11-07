package com.edde746.plezy.exoplayer

import android.app.Activity
import android.os.Looper
import android.widget.FrameLayout
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.source.preload.DefaultPreloadManager
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * V2-09. The clip core holds up to four preloads, one per [ClipPreloadRank], each with its own
 * range, and every preload together stays inside [LoadControlPolicy.CLIP_PRELOAD_TARGET_BYTES].
 * The cores here are real; the clips are file URIs that don't exist, so nothing is fetched.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ClipPreloadTest {

  @After
  fun releaseDiskCache() = ClipDiskCache.resetForTest()

  private fun <T> withClipCore(body: (ExoPlayerCore) -> T): T {
    val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    activity.setContentView(FrameLayout(activity))
    val core = ExoPlayerCore(activity)
    try {
      assertTrue(core.initialize(clipMode = true))
      return body(core)
    } finally {
      core.dispose()
      shadowOf(Looper.getMainLooper()).idle()
    }
  }

  private fun Any.field(owner: Class<*>, name: String): Any? = owner.getDeclaredField(name).apply { isAccessible = true }.get(this)

  @Suppress("UNCHECKED_CAST")
  private val ExoPlayerCore.slots: Map<ClipPreloadRank, String> get() = field(ExoPlayerCore::class.java, "preloadSlots") as Map<ClipPreloadRank, String>

  @Suppress("UNCHECKED_CAST")
  private val ExoPlayerCore.items: Map<String, MediaItem> get() = field(ExoPlayerCore::class.java, "preloadItems") as Map<String, MediaItem>

  private val ExoPlayerCore.manager: DefaultPreloadManager get() = field(ExoPlayerCore::class.java, "preloadManager") as DefaultPreloadManager

  @Suppress("UNCHECKED_CAST")
  private val ExoPlayerCore.rankingData: Map<String, Int> get() = field(ExoPlayerCore::class.java, "preloadRankingData") as Map<String, Int>

  private val a = "file:///reel/a.mp4"
  private val b = "file:///reel/b.mp4"
  private val c = "file:///reel/c.mp4"
  private val d = "file:///reel/d.mp4"
  private val e = "file:///reel/e.mp4"

  @Test
  fun eachRankHoldsOneClipAndANewAskReplacesIt() {
    withClipCore { core ->
      core.preloadClip(a, ClipPreloadRank.NEXT)
      core.preloadClip(b, ClipPreloadRank.PREVIOUS)
      core.preloadClip(c, ClipPreloadRank.DECK_NEXT)
      core.preloadClip(d, ClipPreloadRank.DECK_PREVIOUS)
      assertEquals(mapOf(ClipPreloadRank.NEXT to a, ClipPreloadRank.PREVIOUS to b, ClipPreloadRank.DECK_NEXT to c, ClipPreloadRank.DECK_PREVIOUS to d), core.slots)
      assertEquals(4, core.manager.sourceCount)

      core.preloadClip(e, ClipPreloadRank.NEXT)
      assertEquals(e, core.slots[ClipPreloadRank.NEXT])
      assertEquals(setOf(b, c, d, e), core.items.keys)
      assertEquals(4, core.manager.sourceCount)
    }
  }

  @Test
  fun aClipAskedForAtAnotherRankMovesThereWithItsBuffer() {
    withClipCore { core ->
      core.preloadClip(a, ClipPreloadRank.DECK_NEXT)
      val item = core.items[a]
      core.preloadClip(a, ClipPreloadRank.NEXT)
      assertEquals(mapOf(ClipPreloadRank.NEXT to a), core.slots)
      assertTrue("the same source, not a second one", item === core.items[a])
      assertEquals(1, core.manager.sourceCount)
    }
  }

  @Test
  fun clearingOneRankLeavesTheOthers() {
    withClipCore { core ->
      core.preloadClip(a, ClipPreloadRank.NEXT)
      core.preloadClip(b, ClipPreloadRank.PREVIOUS)
      core.clearPreloads(ClipPreloadRank.PREVIOUS)
      assertEquals(mapOf(ClipPreloadRank.NEXT to a), core.slots)
      assertEquals(setOf(a), core.items.keys)
      core.clearPreloads()
      assertTrue(core.slots.isEmpty())
      assertEquals(0, core.manager.sourceCount)
    }
  }

  @Test
  fun everyPreloadTogetherHasItsOwnByteTarget() {
    withClipCore { core ->
      val observing = core.field(ExoPlayerCore::class.java, "observingLoadControl") as ObservingLoadControl
      val delegate = observing.field(ObservingLoadControl::class.java, "delegate") as LoadControl
      val control = delegate as DefaultLoadControl
      @Suppress("UNCHECKED_CAST")
      val perPlayer = control.field(DefaultLoadControl::class.java, "playerTargetBufferBytesOverwrites") as Map<String, Int>
      // Without it media3's own preload entry (DEFAULT_TARGET_BUFFER_BYTES_FOR_PRELOAD) applies.
      assertEquals(LoadControlPolicy.CLIP_PRELOAD_TARGET_BYTES, perPlayer[PlayerId.PRELOAD.name])
      assertEquals(24 * 1024 * 1024, LoadControlPolicy.CLIP_PRELOAD_TARGET_BYTES)
    }
  }

  @Test
  fun eachRankAsksForItsOwnRangeInMemory() {
    for ((rank, ms) in listOf(
      ClipPreloadRank.NEXT to 3_000L,
      ClipPreloadRank.PREVIOUS to 1_000L,
      ClipPreloadRank.DECK_NEXT to 2_000L,
      ClipPreloadRank.DECK_PREVIOUS to 2_000L
    )) {
      val status = ClipPreloadRank.status(rank.rankingData)
      assertEquals(DefaultPreloadManager.PreloadStatus.STAGE_SPECIFIED_RANGE_LOADED, status.stage)
      assertEquals(ms, status.durationMs)
    }
  }

  @Test
  fun theNextCardLoadsFirstThenTheCardBehindThenTheHeads() {
    val comparator = DefaultPreloadManager.SimpleRankingDataComparator()
    comparator.setCurrentPlayingIndex(ClipPreloadRank.PLAYING_INDEX)
    val sorted = ClipPreloadRank.entries.shuffled().sortedWith { x, y -> comparator.compare(x.rankingData, y.rankingData) }
    assertEquals(listOf(ClipPreloadRank.NEXT, ClipPreloadRank.PREVIOUS), sorted.take(2))
  }

  @Test
  fun theWireNamesMatchTheDartRanks() {
    assertEquals(ClipPreloadRank.NEXT, ClipPreloadRank.fromWire(null))
    assertEquals(ClipPreloadRank.PREVIOUS, ClipPreloadRank.fromWire("previous"))
    assertEquals(ClipPreloadRank.DECK_NEXT, ClipPreloadRank.fromWire("deckNext"))
    assertEquals(ClipPreloadRank.DECK_PREVIOUS, ClipPreloadRank.fromWire("deckPrevious"))
    assertNull(ClipPreloadRank.fromWire("deck"))
  }

  // --- V2-10: the disk cache ----------------------------------------------

  private val plexKey = "plex:server-a:/library/parts/41/1700000000/file.mp4"
  private val plexKey2 = "plex:server-a:/library/parts/42/1700000000/file.mp4"

  @Test
  fun theCardTwoAheadIsADiskPreloadOfAPlexClipOnly() {
    withClipCore { core ->
      core.preloadClip(a, ClipPreloadRank.AHEAD, "animeTheme")
      assertTrue("an AnimeThemes clip never goes to disk (D1)", core.slots.isEmpty())
      assertEquals(0, core.manager.sourceCount)

      core.preloadClip(b, ClipPreloadRank.AHEAD, "plexExtra", plexKey)
      assertEquals(mapOf(ClipPreloadRank.AHEAD to b), core.slots)
      assertEquals(plexKey, core.items[b]!!.localConfiguration!!.customCacheKey)
      assertTrue(ClipPreloadRank.isCachedRankingData(core.rankingData[b]!!))
    }
  }

  @Test
  fun aDiskPreloadMovingToTheNextCardIsAskedForAgainInMemory() {
    withClipCore { core ->
      core.preloadClip(b, ClipPreloadRank.AHEAD, "plexExtra", plexKey)
      val onDisk = core.items[b]
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey)
      assertEquals(mapOf(ClipPreloadRank.NEXT to b), core.slots)
      assertNotSame("a fresh source for the memory stage", onDisk, core.items[b])
      assertFalse(ClipPreloadRank.isCachedRankingData(core.rankingData[b]!!))
      assertEquals(plexKey, core.items[b]!!.localConfiguration!!.customCacheKey)
      assertEquals(1, core.manager.sourceCount)
    }
  }

  @Test
  fun aPlexHeadIsHeldOnlyWhileItIsOnDiskAnAnimeThemesHeadInMemory() {
    withClipCore { core ->
      core.preloadClip(c, ClipPreloadRank.DECK_NEXT, "plexExtra", plexKey2)
      assertTrue("not on disk: no Plex read for a head (D15)", core.slots.isEmpty())

      core.preloadClip(d, ClipPreloadRank.DECK_PREVIOUS, "animeTheme")
      assertEquals(mapOf(ClipPreloadRank.DECK_PREVIOUS to d), core.slots)
      assertFalse(ClipPreloadRank.isCachedRankingData(core.rankingData[d]!!))
      assertEquals(null, core.items[d]!!.localConfiguration!!.customCacheKey)
    }
  }

  @Test
  fun aKeyThatCouldCarryTheTokenIsRefused() {
    withClipCore { core ->
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", "plex:server-a:/x?X-Plex-Token=abc123")
      assertEquals(null, core.items[b]!!.localConfiguration!!.customCacheKey)
    }
  }

  @Test
  fun theMainPlayerNeverReachesTheDiskCache() {
    val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    activity.setContentView(FrameLayout(activity))
    val core = ExoPlayerCore(activity)
    try {
      assertTrue(core.initialize())
      assertEquals(null, core.field(ExoPlayerCore::class.java, "clipCache"))
    } finally {
      core.dispose()
      shadowOf(Looper.getMainLooper()).idle()
    }
    withClipCore { clip -> assertTrue(clip.field(ExoPlayerCore::class.java, "clipCache") != null) }
  }
  // --- V2-23: lead-in skip -------------------------------------------------

  private fun MediaItem.start(): Long = clippingConfiguration.startPositionMs

  private val ExoPlayerCore.player: ExoPlayer get() = field(ExoPlayerCore::class.java, "exoPlayer") as ExoPlayer

  private fun outcome(core: ExoPlayerCore, uri: String, key: String, startMs: Long) = LeadInOutcome(
    LeadInJob(uri, key, ClipPreloadRank.AHEAD, core, {}, { error("not run") }, {}),
    decision = LeadInDecision(startMs = startMs, kind = "coloured", lead = "card+black", reason = "ok")
  )

  @Test
  fun aPreloadIsClippedOnlyWithAStartThePolicyOnAndMeasureOnlyOff() {
    withClipCore { core ->
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey, startMs = 6_006L, measure = true)
      assertEquals("the policy is off until Dart sends it", 0L, core.items[b]!!.start())

      core.setLeadInPolicy(enabled = true, measureOnly = false)
      assertEquals("the held preload follows the policy at once", 6_006L, core.items[b]!!.start())

      core.setLeadInPolicy(enabled = true, measureOnly = true)
      assertEquals("measure-only never clips", 0L, core.items[b]!!.start())
    }
  }

  @Test
  fun anAnimeThemesClipOrAClipWithoutAKeyIsNeverClipped() {
    withClipCore { core ->
      core.setLeadInPolicy(enabled = true, measureOnly = false)
      core.preloadClip(a, ClipPreloadRank.NEXT, "animeTheme", startMs = 6_006L)
      assertEquals(0L, core.items[a]!!.start())
      core.preloadClip(c, ClipPreloadRank.PREVIOUS, "plexExtra", startMs = 6_006L)
      assertEquals(0L, core.items[c]!!.start())
    }
  }

  @Test
  fun aNewStartRestagesTheHeldPreloadAndAnEqualOneNeverDoes() {
    withClipCore { core ->
      core.setLeadInPolicy(enabled = true, measureOnly = false)
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey)
      val unclipped = core.items[b]
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey, startMs = 6_006L)
      assertNotSame(unclipped, core.items[b])
      assertEquals(6_006L, core.items[b]!!.start())
      val clipped = core.items[b]
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey, startMs = 6_006L)
      assertSame(clipped, core.items[b])
      assertEquals(1, core.manager.sourceCount)
    }
  }

  @Test
  fun aDartResendWithNoStartAfterADetectorAnswerNeverRestages() {
    withClipCore { core ->
      core.setLeadInPolicy(enabled = true, measureOnly = false)
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey, measure = true)
      core.onLeadInOutcome(outcome(core, b, plexKey, 6_006L))
      val restaged = core.items[b]
      assertEquals(6_006L, restaged!!.start())
      // Dart hadn't seen the event yet: null is "unknown", never "play from 0" (R7).
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey, startMs = null, measure = true)
      assertSame(restaged, core.items[b])
      assertEquals(6_006L, core.items[b]!!.start())
    }
  }

  @Test
  fun anOpenRefusesAPreloadBuiltWithAnotherStart() {
    withClipCore { core ->
      core.setLeadInPolicy(enabled = true, measureOnly = false)
      core.preloadClip(b, ClipPreloadRank.NEXT, "plexExtra", plexKey)
      assertEquals(0L, core.items[b]!!.start())
      core.rememberClipLeadIn(b, 6_006L, true, "plexExtra")
      core.open(uri = b, headers = null, startPositionMs = 0L, autoPlay = false, mediaGeneration = 1)
      assertEquals("a fresh source with the open's start", 6_006L, core.player.currentMediaItem!!.start())
    }
  }

  @Test
  fun aReloadOfAnOpenKeepsTheStartItWasOpenedWith() {
    withClipCore { core ->
      core.setLeadInPolicy(enabled = true, measureOnly = false)
      core.rememberClipCacheKey(c, plexKey2)
      core.rememberClipLeadIn(c, null, true, "plexExtra")
      core.open(uri = c, headers = null, startPositionMs = 0L, autoPlay = false, mediaGeneration = 1)
      assertEquals(0L, core.player.currentMediaItem!!.start())
      // A start learned while it plays only applies to its next open.
      core.onLeadInOutcome(outcome(core, c, plexKey2, 6_006L))
      val reload = ExoPlayerCore::class.java.getDeclaredMethod("setCurrentMediaSource", ExoPlayer::class.java, String::class.java, Long::class.javaPrimitiveType)
      reload.isAccessible = true
      reload.invoke(core, core.player, c, 1_234L)
      assertEquals("a recovery reload keeps the unclipped timeline (R6)", 0L, core.player.currentMediaItem!!.start())
      assertEquals(1_234L, core.player.currentPosition)
    }
  }

  @Test
  fun aClipOpenPausesTheDetectorUntilAfterItsFirstFrame() {
    withClipCore { core ->
      core.open(uri = a, headers = null, startPositionMs = 0L, autoPlay = false, mediaGeneration = 1)
      assertTrue(LeadInDetector.queue.pauseReasons().contains("open"))
    }
    assertTrue("a released core lets the detector go", LeadInDetector.queue.pauseReasons().isEmpty())
  }

  @Test
  fun aLeadInsBytesRaiseTheOnDiskBarAndOnlyContiguousBytesCount() {
    val mib = 1024L * 1024
    assertTrue(ClipCachePolicy.isOnDisk(4 * mib, -1L))
    assertFalse("4 MiB past a 1 MiB lead-in is needed", ClipCachePolicy.isOnDisk(4 * mib, -1L, leadBytes = 1 * mib))
    assertTrue(ClipCachePolicy.isOnDisk(5 * mib, -1L, leadBytes = 1 * mib))
    assertTrue("a short clip cached whole", ClipCachePolicy.isOnDisk(3 * mib, 3 * mib, leadBytes = 1 * mib))
  }
}
