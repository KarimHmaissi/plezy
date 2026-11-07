package com.edde746.plezy.exoplayer

import java.io.IOException
import kotlin.random.Random
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * V2-23. The detector's scan over a fake reader, its queue (one job at a time, the card two ahead
 * first, one answer per clip), its switches (cancel, pause, the main-playback gate, budgets) and
 * its log lines (never a URI, a token or an exception's message).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class LeadInDetectorTest {

  @After
  fun tearDown() = MainPlaybackGate.resetForTest()

  private val frameUs = 41_708L

  // --- a fake reader ------------------------------------------------------

  private fun flat(y: Int, text: Int? = null, u: Int = 128, v: Int = 128): FrameStats {
    val n = LeadInPolicy.GRID_W * LeadInPolicy.GRID_H
    val ys = IntArray(n) { i -> if (text != null && i % 20 == 0) text else y }
    return FrameStats.fromSamples(ys, IntArray(n) { u }, IntArray(n) { v })
  }

  private fun noise(seed: Int): FrameStats {
    val r = Random(seed)
    val n = LeadInPolicy.GRID_W * LeadInPolicy.GRID_H
    return FrameStats.fromSamples(IntArray(n) { 30 + r.nextInt(190) }, IntArray(n) { 100 + r.nextInt(40) }, IntArray(n) { 110 + r.nextInt(40) })
  }

  private val card = flat(95, text = 235, u = 85, v = 77)
  private val blackFrame = flat(16)

  /** A green card to [cardUs], black to [blackUs], then content; keyframes every [gopUs]. */
  private inner class FakeSource(
    private val cardUs: Long = 6_000_000L,
    private val blackUs: Long = 6_500_000L,
    private val endUs: Long = 30_000_000L,
    private val gopUs: Long = 2_000_000L,
    private val skip: String? = null,
    private val failAt: Long? = null,
    private val audio: AudioLevels? = AudioLevels(DoubleArray(300) { w -> if (w * 100_000L >= blackUs) -18.0 else -80.0 })
  ) : FrameSource {
    val samples = generateSequence(0L) { it + frameUs }.takeWhile { it < endUs }.map { t ->
      val key = t % gopUs < frameUs
      VideoSample(t, if (t >= blackUs) (if (key) 120_000 else 25_000) else (if (key) 30_000 else 250), key)
    }.toList()
    private var at = -1
    private val queued = ArrayList<Long>()
    var decodes = 0
    var closed = false
    override val codecName = "c2.fake.avc.decoder"

    fun stats(t: Long): FrameStats = when {
      t < cardUs -> card
      t < blackUs -> blackFrame
      else -> noise((t / frameUs).toInt())
    }

    override fun open(): TrackInfo {
      skip?.let { throw LeadInSkip(it) }
      return TrackInfo(1920, 1080, endUs * 4, frameUs, false, 23.976f, if (audio != null) "aac" else "none")
    }

    override fun next(): VideoSample? {
      at++
      val s = samples.getOrNull(at) ?: return null
      if (failAt != null && s.timeUs >= failAt) throw IOException("read failed for https://server-a.invalid/library/parts/41/file.mp4?X-Plex-Token=abc123")
      return s
    }

    override fun decode(endOfRun: Boolean): List<ScoredFrame> {
      decodes++
      queued += samples[at].timeUs
      return if (endOfRun) drain() else emptyList()
    }

    override fun drain(): List<ScoredFrame> = queued.map { ScoredFrame(it, stats(it)) }.also { queued.clear() }

    override fun seekTo(timeUs: Long) {
      at = samples.indexOfLast { it.key && it.timeUs <= timeUs } - 1
    }

    override fun audio(): AudioLevels? = audio

    override fun close() {
      closed = true
    }
  }

  // --- the scan -----------------------------------------------------------

  @Test
  fun theScanFindsTheCutWithoutDecodingEveryFrame() {
    val source = FakeSource()
    val scan = LeadInScan(source).run()
    assertEquals(6_006L, scan.decision.startMs)
    assertTrue("decoded ${scan.decoded} of ${source.samples.size}", scan.decoded < 120)
    assertNotNull(scan.riseUs)
  }

  @Test
  fun aClipThatOpensOnContentStopsAfterItsHead() {
    val source = FakeSource(cardUs = 0L, blackUs = 0L)
    val scan = LeadInScan(source).run()
    assertEquals(0L, scan.decision.startMs)
    assertEquals("content", scan.decision.reason)
    assertTrue("only the first 0.5 s was decoded (${scan.decoded})", scan.decoded <= 14)
  }

  @Test
  fun aSpentFrameBudgetStillNeverCutsContent() {
    val scan = LeadInScan(FakeSource(gopUs = 10_000_000L), LeadInBudget(maxFrames = 20)).run()
    assertTrue(scan.decision.startMs <= 6_500L)
  }

  // --- the queue ----------------------------------------------------------

  private class Manual {
    val tasks = ArrayList<Runnable>()

    fun runNext() = tasks.removeAt(0).run()
  }

  private fun job(uri: String, rank: ClipPreloadRank, log: MutableList<String> = mutableListOf(), outcomes: MutableList<LeadInOutcome> = mutableListOf(), owner: Any = this, source: (LeadInControl) -> FrameSource = { FakeSource() }) = LeadInJob(
    uri = uri,
    key = "plex:server-a:/library/parts/${uri.hashCode()}/file.mp4",
    rank = rank,
    owner = owner,
    log = { log += it },
    source = source,
    onResult = { outcomes += it }
  )

  @Test
  fun theCardTwoAheadRunsBeforeTheNextCard() {
    val exec = Manual()
    val ran = ArrayList<String>()
    val q = LeadInQueue({ exec.tasks += it }, { it.run() }, { 0 }) { j, _ -> ran += j.uri; LeadInOutcome(j, decision = LeadInDecision.none("content", emptyList())) }
    assertTrue(q.request(job("file:///a", ClipPreloadRank.NEXT)))
    assertTrue(q.request(job("file:///b", ClipPreloadRank.NEXT)))
    assertTrue(q.request(job("file:///c", ClipPreloadRank.AHEAD)))
    assertFalse("a next card never displaces the card two ahead", q.request(job("file:///d", ClipPreloadRank.NEXT)))
    exec.runNext()
    exec.runNext()
    assertEquals(listOf("file:///a", "file:///c"), ran)
    assertTrue(exec.tasks.isEmpty())
  }

  @Test
  fun aClipMeasuredAtAheadIsNeverQueuedAgainAsNext() {
    val q = LeadInQueue({ it.run() }, { it.run() }, { 0 })
    val outcomes = ArrayList<LeadInOutcome>()
    assertTrue(q.request(job("file:///a", ClipPreloadRank.AHEAD, outcomes = outcomes)))
    assertEquals(6_006L, outcomes.single().startMs)
    assertTrue(q.answered(job("file:///a", ClipPreloadRank.NEXT).key))
    assertFalse(q.request(job("file:///a", ClipPreloadRank.NEXT)))
  }

  @Test
  fun aCancelStopsTheRunningJob() {
    val exec = Manual()
    val outcomes = ArrayList<LeadInOutcome>()
    val q = LeadInQueue({ exec.tasks += it }, { it.run() }, { 0 })
    q.request(job("file:///a", ClipPreloadRank.NEXT, outcomes = outcomes))
    q.cancel("file:///a", "opened")
    exec.runNext()
    assertEquals("opened", outcomes.single().abortReason)
    assertFalse("a cancel is not an answer", outcomes.single().definite)
  }

  @Test
  fun leavingTheWindowCancelsOnlyClipsOutsideIt() {
    val exec = Manual()
    val outcomes = ArrayList<LeadInOutcome>()
    val q = LeadInQueue({ exec.tasks += it }, { it.run() }, { 0 })
    q.request(job("file:///a", ClipPreloadRank.AHEAD, outcomes = outcomes))
    q.cancelExcept(this, setOf("file:///a"), "leftWindow")
    exec.runNext()
    assertTrue(outcomes.single().definite)
    q.request(job("file:///b", ClipPreloadRank.AHEAD, outcomes = outcomes))
    q.cancelExcept(this, setOf("file:///a"), "leftWindow")
    exec.runNext()
    assertEquals("leftWindow", outcomes.last().abortReason)
  }

  @Test
  fun aMainPlayerStopsTheDetectorAndKeepsItStopped() {
    val exec = Manual()
    val outcomes = ArrayList<LeadInOutcome>()
    val q = LeadInQueue({ exec.tasks += it }, { it.run() }, { MainPlaybackGate.value })
    val listener: (Int) -> Unit = { n -> if (n > 0) q.cancelAll("mainPlayer") }
    MainPlaybackGate.addListener(listener)
    try {
      q.request(job("file:///a", ClipPreloadRank.AHEAD, outcomes = outcomes))
      MainPlaybackGate.up()
      exec.runNext()
      assertEquals("mainPlayer", outcomes.single().abortReason)
      val log = ArrayList<String>()
      assertFalse(q.request(job("file:///b", ClipPreloadRank.AHEAD, log = log)))
      assertTrue(log.single().contains("reason=gate gate=1"))
      MainPlaybackGate.down()
      assertTrue(q.request(job("file:///b", ClipPreloadRank.AHEAD)))
    } finally {
      MainPlaybackGate.removeListener(listener)
    }
  }

  @Test
  fun aPauseIsWaitedOutAndNotCountedAgainstTheWallBudget() {
    var now = 0L
    var paused = true
    var polls = 0
    val control = LeadInControl(isPaused = { paused }, wallBudgetMs = 1_000L, nowMs = { now }, sleepMs = { ms ->
      now += ms
      if (++polls == 100) paused = false
    })
    control.check()
    assertEquals(100, polls)
    assertEquals(0L, control.wallMs)
    now += 1_500L
    try {
      control.check()
      throw AssertionError("over the wall budget")
    } catch (e: LeadInAbort) {
      assertEquals("budget", e.reason)
    }
  }

  @Test
  fun pausesStackByReason() {
    val q = LeadInQueue({ it.run() }, { it.run() }, { 0 })
    q.pause("open")
    q.pause("buffering")
    q.resume("open")
    assertTrue(q.isPaused)
    q.resume("buffering")
    assertFalse(q.isPaused)
    q.pause("open")
    q.resumeAll()
    assertFalse(q.isPaused)
  }

  @Test
  fun aBudgetAbortCachesNothingAndIsTriedOnceMore() {
    val q = LeadInQueue({ it.run() }, { it.run() }, { 0 }) { j, _ -> LeadInOutcome(j, abortReason = "budget") }
    val a = job("file:///a", ClipPreloadRank.AHEAD)
    assertTrue(q.request(a))
    assertFalse(q.answered(a.key))
    assertTrue("measured again on a later preload", q.request(job("file:///a", ClipPreloadRank.AHEAD)))
    assertFalse("at most twice a session", q.request(job("file:///a", ClipPreloadRank.AHEAD)))
  }

  @Test
  fun skipReasonsAreAnswers() {
    for (reason in listOf("hdr", "10bit", "dv", "encrypted", "nosw", "codec")) {
      val outcomes = ArrayList<LeadInOutcome>()
      val q = LeadInQueue({ it.run() }, { it.run() }, { 0 })
      q.request(job("file:///$reason", ClipPreloadRank.AHEAD, outcomes = outcomes, source = { FakeSource(skip = reason) }))
      val o = outcomes.single()
      assertEquals(reason, o.skipReason)
      assertTrue(o.definite)
      assertEquals(0L, o.startMs)
    }
  }

  @Test
  fun theReaderIsAlwaysClosed() {
    val source = FakeSource(failAt = 1_000_000L)
    val o = LeadInRunner.run(job("file:///a", ClipPreloadRank.AHEAD, source = { source }), LeadInControl())
    assertTrue(source.closed)
    assertEquals("error:IOException", o.abortReason)
    assertNull(o.decision)
  }

  @Test
  fun noLogLineCarriesAUriATokenOrAnExceptionMessage() {
    val log = ArrayList<String>()
    val q = LeadInQueue({ it.run() }, { it.run() }, { 0 })
    q.request(job("https://server-a.invalid/library/parts/1/file.mp4?X-Plex-Token=abc123", ClipPreloadRank.AHEAD, log = log))
    q.request(job("https://server-a.invalid/library/parts/2/file.mp4?X-Plex-Token=abc123", ClipPreloadRank.NEXT, log = log, source = { FakeSource(failAt = 2_000_000L) }))
    q.request(job("https://server-a.invalid/library/parts/3/file.mp4?X-Plex-Token=abc123", ClipPreloadRank.NEXT, log = log, source = { FakeSource(skip = "hdr") }))
    assertTrue(log.any { it.startsWith("result ") })
    assertTrue(log.any { it.startsWith("abort ") && it.contains("reason=error:IOException") })
    assertTrue(log.any { it.startsWith("skip ") })
    for (line in log) {
      assertFalse(line, line.contains("://"))
      assertFalse(line, line.contains("token", ignoreCase = true))
      assertFalse(line, line.contains("?"))
      assertFalse(line, line.contains("server-a"))
    }
  }
}
