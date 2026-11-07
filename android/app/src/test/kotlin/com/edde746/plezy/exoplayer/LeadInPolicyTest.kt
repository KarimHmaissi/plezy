package com.edde746.plezy.exoplayer

import java.nio.ByteBuffer
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * V2-23. Scoring one frame and deciding a clip's cut, on synthetic planes and frame sequences
 * (every picture here is invented: flat colours, blocks and seeded noise).
 */
class LeadInPolicyTest {

  // --- synthetic pictures --------------------------------------------------

  /** A picture as Y/U/V functions over a [w] × [h] frame (chroma at half resolution). */
  private class Pic(val w: Int = 320, val h: Int = 180, val y: (Int, Int) -> Int, val u: (Int, Int) -> Int = { _, _ -> 128 }, val v: (Int, Int) -> Int = { _, _ -> 128 })

  private fun score(p: Pic, fullRange: Boolean = false) = FrameStats.of(p.w, p.h, fullRange, p.y, p.u, p.v)

  /** A block of "text" covering about [share] of the middle of the picture. */
  private fun text(x: Int, y: Int, w: Int, h: Int, share: Double = 0.05, dx: Int = 0): Boolean {
    val rows = (h * 0.70).toInt()
    val top = (h * 0.15).toInt()
    val band = (rows * share * 2).toInt().coerceAtLeast(2)
    val inBand = y in (top + rows / 2 - band / 2) until (top + rows / 2 + band / 2)
    return inBand && ((x + dx) / 6) % 2 == 0 && x > w / 8 && x < w * 7 / 8
  }

  private fun greenCard(dx: Int = 0) = Pic(y = { x, y -> if (text(x, y, 320, 180, dx = dx)) 235 else 95 }, u = { _, _ -> 85 }, v = { _, _ -> 77 })

  private fun redCard() = Pic(y = { x, y -> if (text(x, y, 320, 180)) 235 else 63 }, u = { _, _ -> 102 }, v = { _, _ -> 240 })

  private fun black(seed: Int = 1): Pic {
    val r = Random(seed)
    val noise = IntArray(320 * 180) { 16 + r.nextInt(-3, 4) }
    return Pic(y = { x, y -> noise[y * 320 + x] })
  }

  private fun darkText(dx: Int = 0) = Pic(y = { x, y -> if (text(x, y, 320, 180, dx = dx)) 200 else 16 })

  private fun lightCard() = Pic(y = { x, y -> if (text(x, y, 320, 180)) 30 else 200 })

  private fun content(seed: Int): Pic {
    val r = Random(seed)
    val tex = IntArray(320 * 180) { 30 + r.nextInt(0, 190) }
    return Pic(y = { x, y -> tex[y * 320 + x] }, u = { x, y -> 100 + (x + y) % 40 }, v = { x, y -> 140 - (x * y) % 30 })
  }

  private fun stats(p: Pic) = score(p)

  // --- scoring ------------------------------------------------------------

  @Test
  fun aGreenCardWithTextIsAColouredCard() {
    val s = stats(greenCard())
    assertEquals(LeadInClass.CARD to CardKind.COLOURED, LeadInPolicy.classify(s, 0.0, quiet = true))
  }

  @Test
  fun aRedCardIsAColouredCard() {
    assertEquals(LeadInClass.CARD to CardKind.COLOURED, LeadInPolicy.classify(stats(redCard()), 0.0, quiet = true))
  }

  @Test
  fun codecBlackWithNoiseIsBlack() {
    assertEquals(LeadInClass.BLACK, LeadInPolicy.classify(stats(black()), null, quiet = false).first)
  }

  @Test
  fun aDarkFilmFrameWithHighlightsIsContentNotBlack() {
    val r = Random(7)
    val pic = Pic(y = { x, y -> if (r.nextInt(100) < 4) 200 else 20 + (x * 40) / 320 })
    assertEquals(LeadInClass.CONTENT, LeadInPolicy.classify(stats(pic), 12.0, quiet = false).first)
  }

  @Test
  fun aTexturedNightFrameUnderY40IsNotBlack() {
    val r = Random(3)
    val tex = IntArray(320 * 180) { 18 + r.nextInt(0, 21) }
    val s = stats(Pic(y = { x, y -> tex[y * 320 + x] }))
    assertTrue(s.p98 <= 40)
    assertNotEquals(LeadInClass.BLACK, LeadInPolicy.classify(s, 1.0, quiet = true).first)
  }

  @Test
  fun staticTextOnBlackIsADarkCard() {
    assertEquals(LeadInClass.CARD to CardKind.DARK, LeadInPolicy.classify(stats(darkText()), 0.0, quiet = true))
  }

  @Test
  fun aStaticLogoIsACardAndAMovingOneIsContent() {
    val still = stats(darkText())
    assertEquals(LeadInClass.CARD, LeadInPolicy.classify(still, LeadInPolicy.delta(still, stats(darkText())), quiet = false).first)
    // 6 px a frame for half a second: 72 px away from its neighbour.
    val moving = stats(darkText(dx = 0))
    val later = stats(darkText(dx = 72 + 3))
    assertEquals(LeadInClass.CONTENT, LeadInPolicy.classify(moving, LeadInPolicy.delta(moving, later), quiet = false).first)
  }

  @Test
  fun letterboxedContentIsContent() {
    val r = Random(11)
    val tex = IntArray(320 * 180) { 30 + r.nextInt(0, 190) }
    val pic = Pic(y = { x, y -> if (y < 22 || y >= 158) 16 else tex[y * 320 + x] })
    assertEquals(LeadInClass.CONTENT, LeadInPolicy.classify(stats(pic), 20.0, quiet = false).first)
  }

  @Test
  fun aFullRangeBlackFrameIsMappedToLimitedBlack() {
    val s = score(Pic(y = { _, _ -> 0 }, u = { _, _ -> 128 }, v = { _, _ -> 128 }), fullRange = true)
    assertEquals(16, s.p50)
    assertEquals(LeadInClass.BLACK, LeadInPolicy.classify(s, null, quiet = false).first)
    // Full-range white maps to 235.
    assertEquals(235, LeadInPolicy.limitedLuma(255))
  }

  @Test
  fun planesAreReadWithTheirRowAndPixelStrides() {
    // A 64x36 crop at (8, 4) inside a 96-wide luma plane padded to 128 bytes a row; chroma
    // interleaved (pixel stride 2), as a semi-planar decoder hands it out.
    val w = 64
    val h = 36
    val yRow = 128
    val yBuf = ByteBuffer.allocate(yRow * 48)
    for (y in 0 until 48) for (x in 0 until 96) yBuf.put(y * yRow + x, (if (x in 8 until 8 + w && y in 4 until 4 + h) 95 else 250).toByte())
    val cRow = 128
    val uv = ByteBuffer.allocate(cRow * 24)
    for (y in 0 until 24) for (x in 0 until 48) {
      uv.put(y * cRow + x * 2, 85.toByte())
      uv.put(y * cRow + x * 2 + 1, 77.toByte())
    }
    val vBuf = (uv.duplicate().position(1) as ByteBuffer).slice()
    val s = FrameStats.of(
      w,
      h,
      false,
      LeadInPolicy.plane(yBuf, yRow, 1, 8, 4),
      LeadInPolicy.plane(uv, cRow, 2, 4, 2),
      LeadInPolicy.plane(vBuf, cRow, 2, 4, 2)
    )
    assertEquals("only the crop is read, never the padding", 95, s.p98)
    assertEquals("max(|85 - 128|, |77 - 128|)", 51.0, s.chroma, 0.01)
  }

  // R2: still real shots are never cards.

  @Test
  fun aClearSkyOverGradedHillsIsContentNotACard() {
    // A flat sky over hills whose tones run 30–100: flat, contrasted and still, but not two-tone.
    val pic = Pic(y = { x, y -> if (y < 110) 150 else 30 + ((x * 7 + y * 3) % 71) })
    val s = stats(pic)
    assertTrue(s.flatness >= LeadInPolicy.CARD_FLATNESS_MIN)
    assertTrue(s.contrast >= LeadInPolicy.CARD_CONTRAST_MIN)
    assertTrue(s.bgNoise <= LeadInPolicy.CARD_BG_NOISE_MAX)
    assertTrue("two-tone is what fails: ${s.twoTone}", s.twoTone < LeadInPolicy.CARD_TWO_TONE_MIN)
    assertEquals(LeadInClass.CONTENT, LeadInPolicy.classify(s, 0.0, quiet = true).first)
  }

  @Test
  fun aStillSnowyFieldWithGrainIsContent() {
    val r = Random(5)
    val grain = IntArray(320 * 180) { 200 + r.nextInt(-5, 6) }
    val pic = Pic(y = { x, y -> if (y > 150 && x % 40 < 6) 60 else grain[y * 320 + x] })
    val s = stats(pic)
    assertTrue("grain is what fails: ${s.bgNoise}", s.bgNoise > LeadInPolicy.CARD_BG_NOISE_MAX)
    assertEquals(LeadInClass.CONTENT, LeadInPolicy.classify(s, 0.0, quiet = true).first)
  }

  @Test
  fun aStillSaturatedBlueSkyIsContent() {
    // One luma with a white cloud band, but its colour grades down the frame.
    val pic = Pic(y = { x, y -> if (text(x, y, 320, 180, share = 0.08)) 220 else 100 }, u = { _, y -> 150 + y / 2 }, v = { _, _ -> 110 })
    val s = stats(pic)
    assertTrue(s.chroma >= LeadInPolicy.COLOURED_CHROMA_MIN)
    assertTrue("chroma flatness is what fails: ${s.chromaFlat}", s.chromaFlat < LeadInPolicy.COLOURED_CHROMA_FLAT_MIN)
    assertEquals(LeadInClass.CONTENT, LeadInPolicy.classify(s, 0.0, quiet = true).first)
  }

  // --- sizes --------------------------------------------------------------

  @Test
  fun theRiseIsWhereTinyFramesTurnIntoASustainedRun() {
    val r = RiseLocator()
    var t = 0L
    while (t < 8_000_000L) {
      r.add(VideoSample(t, if (t >= 6_000_000L) 20_000 else 300, key = t % 2_000_000L == 0L))
      t += 41_708L
    }
    assertEquals(6_000_000L, r.rise())
  }

  @Test
  fun aShortBumpUnderOneSecondIsNoRise() {
    val r = RiseLocator()
    var t = 0L
    while (t < 6_000_000L) {
      val bump = t in 2_000_000L until 2_600_000L
      r.add(VideoSample(t, if (bump) 20_000 else 300, key = false))
      t += 41_708L
    }
    assertNull(r.rise())
  }

  @Test
  fun keyframesNeverCountTowardsTheRise() {
    val r = RiseLocator()
    var t = 0L
    while (t < 6_000_000L) {
      r.add(VideoSample(t, if (t % 250_000L < 41_708L) 400_000 else 200, key = t % 250_000L < 41_708L))
      t += 41_708L
    }
    assertNull(r.rise())
  }

  // --- deciding -----------------------------------------------------------

  private enum class Seg { GREEN, BLACK, CONTENT, DARK, LIGHT, FADE }

  private val frameUs = 41_708L

  /**
   * A clip from segments, every frame decoded (refine-complete), keyframes every [gopUs],
   * with sizes to match: still frames tiny, content large.
   */
  private fun clip(
    vararg segs: Pair<Seg, Long>,
    gopUs: Long = 2_000_000L,
    audio: AudioLevels? = quietThenLoud(Long.MAX_VALUE),
    durationMs: Long = 120_000L,
    decodedEvery: Int = 1,
    refinePartial: Boolean = false,
    sizes: ((Long, Seg) -> Int)? = null
  ): LeadInInput {
    val samples = ArrayList<VideoSample>()
    val frames = ArrayList<ScoredFrame>()
    var t = 0L
    var segStart = 0L
    var i = 0
    val cache = HashMap<String, FrameStats>()
    for ((seg, len) in segs) {
      while (t < segStart + len) {
        val key = t % gopUs < frameUs
        val size = sizes?.invoke(t, seg) ?: when (seg) {
          Seg.CONTENT -> if (key) 120_000 else 25_000
          Seg.FADE -> if (key) 40_000 else 9_000
          else -> if (key) 30_000 else 250
        }
        samples += VideoSample(t, size, key)
        if (key || i % decodedEvery == 0) {
          val s = when (seg) {
            Seg.GREEN -> cache.getOrPut("g") { stats(greenCard()) }
            Seg.BLACK -> cache.getOrPut("b") { stats(black()) }
            Seg.DARK -> cache.getOrPut("d") { stats(darkText()) }
            Seg.LIGHT -> cache.getOrPut("l") { stats(lightCard()) }
            Seg.CONTENT -> stats(content(i))
            Seg.FADE -> stats(Pic(y = { x, y -> if (text(x, y, 320, 180, dx = i * 9)) 120 + i % 7 else 50 + (i * 13) % 20 }))
          }
          frames += ScoredFrame(t, s, key)
        }
        t += frameUs
        i++
      }
      segStart += len
    }
    return LeadInInput(samples, frames, durationMs, frameUs, audio, refinePartial)
  }

  private fun quietThenLoud(loudFromUs: Long, quietDb: Double = -80.0, loudDb: Double = -18.0): AudioLevels = AudioLevels(DoubleArray(400) { w -> if (w * 100_000L >= loudFromUs) loudDb else quietDb })

  private fun firstFrameAtOrAfter(us: Long): Long = ((us + frameUs - 1) / frameUs) * frameUs

  /** A keyframe's start in ms: rounded up past the frame ([LeadInPolicy.toStartMs]). */
  private fun keyMs(us: Long): Long = (us + 999) / 1000

  @Test
  fun aCardThenBlackThenContentCutsOnTheFirstContentFrame() {
    // The keyframe at 6.006 s is black, so the cut snaps back to it (rule 10, no hidden frames).
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 6_000_000L, Seg.BLACK to 500_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(6_600_000L)))
    assertEquals("ok", d.reason)
    assertEquals(keyMs(144 * frameUs), d.startMs)
    assertEquals("coloured", d.kind)
    assertEquals("card+black", d.lead)
    assertEquals(firstFrameAtOrAfter(6_500_000L) / 1000, d.firstContentMs)
  }

  @Test
  fun aCutPastACardKeyframeStaysExactAndLogsItsPreroll() {
    // Keyframes every 5 s: the one before the cut is inside the card, so no snap.
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 6_200_000L, Seg.BLACK to 500_000L, Seg.CONTENT to 20_000_000L, gopUs = 5_000_000L, audio = quietThenLoud(6_800_000L)))
    assertEquals(firstFrameAtOrAfter(6_700_000L) / 1000, d.startMs)
    assertEquals((firstFrameAtOrAfter(6_700_000L) - 120 * frameUs) / 1000, d.prerollMs)
  }

  @Test
  fun noLeadInIsZero() {
    val d = LeadInPolicy.decide(clip(Seg.CONTENT to 30_000_000L, audio = quietThenLoud(0)))
    assertEquals(0L, d.startMs)
    assertEquals("content", d.reason)
  }

  @Test
  fun aOneFrameFlashInsideBlackIsNotTakenAsTheStart() {
    // A flash at 4.3 s, more than 1 s before the content, so no keyframe snap shows it either.
    val d = LeadInPolicy.decide(
      clip(
        Seg.GREEN to 3_000_000L,
        Seg.BLACK to 1_300_000L,
        Seg.CONTENT to frameUs,
        Seg.BLACK to 1_500_000L,
        Seg.CONTENT to 20_000_000L,
        // The flash's window stays under the size floor.
        sizes = { t, seg -> if (seg == Seg.CONTENT && t > 5_000_000L) 25_000 else 250 },
        audio = quietThenLoud(6_000_000L)
      )
    )
    assertTrue("cut ${d.startMs} goes past the flash", d.startMs >= 5_800L)
  }

  @Test
  fun aDarkTextOpeningOfTwentySecondsIsKept() {
    val d = LeadInPolicy.decide(clip(Seg.DARK to 20_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(Long.MAX_VALUE)))
    assertEquals(0L, d.startMs)
  }

  @Test
  fun aDarkCardOfTwoSecondsIsKept() {
    val d = LeadInPolicy.decide(clip(Seg.DARK to 2_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(2_000_000L)))
    assertEquals(0L, d.startMs)
    assertEquals("card-rule", d.reason)
  }

  @Test
  fun aQuietDarkCardOfFiveSecondsIsCut() {
    val d = LeadInPolicy.decide(clip(Seg.DARK to 5_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(5_000_000L)))
    assertEquals(firstFrameAtOrAfter(5_000_000L) / 1000, d.startMs)
    assertEquals("dark", d.kind)
  }

  @Test
  fun aLoudDarkCardIsLoggedAsAWouldCutAndKept() {
    val d = LeadInPolicy.decide(clip(Seg.DARK to 5_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(0)))
    assertEquals(0L, d.startMs)
    assertEquals("audio-loud", d.reason)
    assertNotNull(d.wouldCutMs)
  }

  @Test
  fun contentFirstThenACardIsZero() {
    val d = LeadInPolicy.decide(clip(Seg.CONTENT to 1_000_000L, Seg.GREEN to 4_000_000L, Seg.CONTENT to 20_000_000L))
    assertEquals(0L, d.startMs)
  }

  @Test
  fun aLeadInOverFifteenSecondsIsCapped() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 16_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(16_000_000L)))
    assertEquals(0L, d.startMs)
    assertEquals("cap", d.reason)
  }

  @Test
  fun aLeadInOverAQuarterOfAShortClipIsCapped() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 6_000_000L, Seg.CONTENT to 14_000_000L, durationMs = 20_000L, audio = quietThenLoud(6_000_000L)))
    assertEquals(0L, d.startMs)
    assertEquals("cap", d.reason)
  }

  @Test
  fun fadesOverOneSecondCountAsContent() {
    // Card, then 1.5 s of a fade that never confirms as content, then black, then content.
    val d = LeadInPolicy.decide(
      clip(Seg.GREEN to 4_000_000L, Seg.FADE to 1_500_000L, Seg.BLACK to 1_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(Long.MAX_VALUE))
    )
    assertTrue("cut ${d.startMs} stops where the fade began", d.startMs <= keyMs(96 * frameUs))
  }

  @Test
  fun aMidFadeFrameBetweenTheCardAndBlackIsATransition() {
    val d = LeadInPolicy.decide(
      clip(Seg.GREEN to 4_000_000L, Seg.FADE to 300_000L, Seg.BLACK to 1_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(5_300_000L))
    )
    val atFade = d.classes.first { it.first >= 4_000L }.second
    assertEquals("TRANSITION", atFade)
    assertTrue(d.startMs > 4_300L)
  }

  @Test
  fun refineOutOfBudgetCutsAfterTheLastLeadInFrame() {
    // Only keyframes and the head were scored past 1 s, and refine ran out: the cut is the last
    // scored lead-in frame + one frame.
    val input = clip(Seg.GREEN to 6_000_000L, Seg.BLACK to 500_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(6_500_000L))
    val kept = input.frames.filter { it.timeUs <= 6_200_000L || it.timeUs >= 8_000_000L }
    val d = LeadInPolicy.decide(LeadInInput(input.samples, kept, input.durationMs, frameUs, input.audio, refinePartial = true))
    val lastLead = kept.filter { it.timeUs <= 6_200_000L }.maxOf { it.timeUs }
    assertTrue(d.startMs <= (lastLead + frameUs) / 1000)
    assertTrue(d.startMs >= 500L)
  }

  // R2/R4/R5/R9 additions.

  @Test
  fun aLightCardStartingAtOneSecondIsKept() {
    val d = LeadInPolicy.decide(clip(Seg.CONTENT to 1_000_000L, Seg.LIGHT to 4_000_000L, Seg.CONTENT to 20_000_000L))
    assertEquals(0L, d.startMs)
    val late = LeadInPolicy.decide(clip(Seg.BLACK to 1_000_000L, Seg.LIGHT to 4_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(5_000_000L)))
    assertEquals("a light card must start within 0.5 s", 0L, late.startMs)
    assertEquals("card-rule", late.reason)
  }

  @Test
  fun voiceOverOnTheBlackAfterTheCardStopsTheCut() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 4_000_000L, Seg.BLACK to 3_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(5_200_000L)))
    assertTrue("cut ${d.startMs} keeps the voice from 5.2 s", d.startMs <= 5_200L)
    assertEquals(5_200L, d.audioOnsetMs)
  }

  // R4 in a run that holds a coloured card and a dark one: an opening title on black after the
  // rating card is a dark card, and it must be quiet to be cut, as on its own.

  @Test
  fun aTitleOnBlackWithAVoiceAfterAColouredCardIsKept() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 4_000_000L, Seg.DARK to 4_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(4_500_000L)))
    assertTrue("cut ${d.startMs} keeps the title and its voice from 4.5 s", d.startMs <= 4_500L)
    assertTrue("cut ${d.startMs} still skips the rating card", d.startMs >= 3_900L)
    assertEquals("audio-loud", d.reason)
    assertTrue("quiet ${d.cardQuietPct}% under the bar", (d.cardQuietPct ?: 100) < 80)
  }

  @Test
  fun aVoiceInTheBlackBeforeALoudTitleIsKept() {
    // Rating card 0-4 s, black 4-5 s with a voice from 4.5 s, then the title on black.
    val d = LeadInPolicy.decide(
      clip(Seg.GREEN to 4_000_000L, Seg.BLACK to 1_000_000L, Seg.DARK to 3_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(4_500_000L))
    )
    assertTrue("cut ${d.startMs} keeps the voice from 4.5 s", d.startMs <= 4_500L)
  }

  @Test
  fun withNoAudioADarkCardAfterAColouredCardIsKept() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 4_000_000L, Seg.DARK to 4_000_000L, Seg.CONTENT to 20_000_000L, audio = null))
    assertTrue("cut ${d.startMs} at the coloured card's end", d.startMs in 3_900L..4_100L)
  }

  @Test
  fun aQuietDarkCardAfterAColouredCardIsCutWithIt() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 4_000_000L, Seg.DARK to 4_000_000L, Seg.CONTENT to 20_000_000L, audio = quietThenLoud(8_000_000L)))
    assertEquals("the first content frame, a keyframe at 8.008 s", keyMs(192 * frameUs), d.startMs)
    assertEquals("ok", d.reason)
    assertTrue("the dark card's quiet share ${d.cardQuietPct}% is logged", (d.cardQuietPct ?: 0) >= 80)
  }

  @Test
  fun withNoAudioACardKeepsItsBlackGap() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 4_000_000L, Seg.BLACK to 2_000_000L, Seg.CONTENT to 20_000_000L, audio = null))
    assertTrue("cut ${d.startMs} at the card's end", d.startMs in 3_900L..4_100L)
  }

  @Test
  fun withNoAudioBlackAloneIsZero() {
    val d = LeadInPolicy.decide(clip(Seg.BLACK to 2_000_000L, Seg.CONTENT to 20_000_000L, audio = null))
    assertEquals(0L, d.startMs)
    assertEquals("audio-none", d.reason)
  }

  @Test
  fun aChangedWindowBetweenLeadInKeyframesThatWasNeverScoredStopsTheCut() {
    // Only keyframes are scored (every 2 s, all black); a 0.4 s above-floor stretch at 1 s.
    val input = clip(
      Seg.BLACK to 6_000_000L,
      Seg.CONTENT to 20_000_000L,
      decodedEvery = 10_000,
      sizes = { t, seg -> if (seg == Seg.CONTENT || t in 1_000_000L until 1_400_000L) 25_000 else 250 },
      audio = quietThenLoud(6_000_000L)
    )
    val d = LeadInPolicy.decide(input)
    assertTrue("cut ${d.startMs} stops at the unscored change", d.startMs <= 1_000L)
  }

  @Test
  fun blackFromTheKeyframeToTheCutSnapsBack() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 3_900_000L, Seg.BLACK to 700_000L, Seg.CONTENT to 20_000_000L, gopUs = 4_000_000L, audio = quietThenLoud(4_700_000L)))
    assertEquals("keyframe at 4.004 s", keyMs(96 * frameUs), d.startMs)
    assertEquals(0L, d.prerollMs)
  }

  @Test
  fun aMissingDurationIsUnknown() {
    val d = LeadInPolicy.decide(clip(Seg.GREEN to 4_000_000L, Seg.CONTENT to 20_000_000L, durationMs = -1L))
    assertTrue(d.unknown)
  }

  // --- the property -------------------------------------------------------

  @Test
  fun theCutNeverPassesTheFirstConfirmedContentFrameNorFifteenSeconds() {
    val kinds = listOf(Seg.GREEN, Seg.BLACK, Seg.CONTENT, Seg.DARK, Seg.FADE, Seg.LIGHT)
    val r = Random(2026)
    repeat(60) { run ->
      val segs = (0 until r.nextInt(2, 6)).map { kinds[r.nextInt(kinds.size)] to r.nextLong(200_000L, 6_000_000L) } + (Seg.CONTENT to 12_000_000L)
      val partial = r.nextBoolean()
      val base = clip(*segs.toTypedArray(), audio = if (r.nextBoolean()) null else quietThenLoud(r.nextLong(0, 20_000_000L)))
      // A frame duration longer than the real spacing (VFR) must still never let the cut pass.
      val input = LeadInInput(base.samples, base.frames, base.durationMs, if (partial) frameUs * 30 else frameUs, base.audio, partial)
      val d = LeadInPolicy.decide(input)
      val raw = input.frames.map { f ->
        val n = input.frames.filter { kotlin.math.abs(it.timeUs - f.timeUs) >= LeadInPolicy.NEIGHBOUR_MIN_US }.minByOrNull { kotlin.math.abs(it.timeUs - f.timeUs) }
        f.timeUs to LeadInPolicy.classify(f.stats, n?.let { LeadInPolicy.delta(f.stats, it.stats) }, LeadInPolicy.quiet(input.samples, f.timeUs)).first
      }
      val firstConfirmed = raw.indices.firstOrNull { i ->
        raw[i].second == LeadInClass.CONTENT && raw.firstOrNull { it.first >= raw[i].first + LeadInPolicy.CONFIRM_US }.let { it == null || it.second == LeadInClass.CONTENT }
      }?.let { raw[it].first / 1000 }
      assertTrue("run $run: ${d.startMs} > 15 s", d.startMs <= LeadInPolicy.MAX_CUT_MS)
      // At most the rounding up past a keyframe that is itself the first content frame.
      if (firstConfirmed != null) assertTrue("run $run: cut ${d.startMs} past content at $firstConfirmed", d.startMs <= firstConfirmed + 1)
    }
  }
}
