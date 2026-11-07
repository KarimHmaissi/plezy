package com.edde746.plezy.exoplayer

import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * V2-23: where a trailer's real picture starts, from frames scored on a small grid. Pure Kotlin
 * (no Android types) so every rule is tested on the JVM. Every threshold is a first guess, named
 * here, and logged on each `[ReelLeadIn]` line so the morning device run can calibrate them
 * (design `2026-11-07-reel-leadin-skip-design.md` §3.3-§3.4).
 */
internal object LeadInPolicy {
  /** Bumped whenever a rule changes: a cached `lv` from another version is measured again. */
  const val VERSION = 1

  // --- scoring (§3.3) -----------------------------------------------------
  const val GRID_W = 64
  const val GRID_H = 36
  const val ROW_FROM = 0.15
  const val ROW_TO = 0.85
  const val COL_FROM = 0.05
  const val COL_TO = 0.95

  const val BLACK_P98_MAX = 40
  const val BLACK_P50_MAX = 24
  const val BLACK_SPREAD = 4
  const val BLACK_SHARE_MIN = 0.90

  const val FLAT_SPREAD = 6
  const val CARD_FLATNESS_MIN = 0.60
  const val CARD_CONTRAST_MIN = 40
  const val CARD_DELTA_MAX = 3.0
  const val TWO_TONE_BG = 8
  const val TWO_TONE_INK = 24
  const val CARD_TWO_TONE_MIN = 0.92
  const val CARD_BG_NOISE_MAX = 2.0
  const val CHROMA_FLAT_SPREAD = 4
  const val COLOURED_CHROMA_MIN = 25.0
  const val COLOURED_CHROMA_FLAT_MIN = 0.60
  const val DARK_P50_MAX = 60

  /** A decoded neighbour for Δ is at least this far away. */
  const val NEIGHBOUR_MIN_US = 500_000L

  /** `quiet`: mean inter-frame size over [t, t + this]. */
  const val QUIET_SPAN_US = 500_000L
  const val QUIET_MIN_BYTES = 1_500
  const val QUIET_KEY_SHARE = 0.03

  // --- deciding (§3.4) ----------------------------------------------------
  const val CONFIRM_US = 400_000L
  const val TRANSITION_MAX_US = 1_000_000L
  const val CARD_MIN_US = 1_000_000L
  const val BLACK_MIN_US = 500_000L
  const val STRICT_CARD_START_US = 500_000L
  const val STRICT_CARD_MIN_US = 3_000_000L
  const val STRICT_CARD_MAX_US = 12_000_000L
  const val COLOURED_CARD_START_US = 1_500_000L
  const val COLOURED_CARD_MIN_US = 1_500_000L
  const val MIN_CUT_MS = 500L
  const val MAX_CUT_MS = 15_000L
  const val MAX_CUT_SHARE = 0.25
  const val END_MARGIN_MS = 5_000L
  const val SNAP_MAX_US = 1_000_000L

  // --- audio (§3.4 rules 5 and 11) ----------------------------------------
  const val AUDIO_WINDOW_US = 100_000L
  const val AUDIBLE_DBFS = -45.0
  const val AUDIBLE_RUN_US = 300_000L
  const val CARD_QUIET_SHARE = 0.80

  // --- sizes (§3.2 step 4) ------------------------------------------------
  const val SIZE_WINDOW_US = 250_000L
  const val SIZE_FLOOR_MIN_BYTES = 4_096L
  const val SIZE_FLOOR_MEAN_SHARE = 0.05
  const val RISE_RUN = 4

  /** Y mapped from full range to limited range (studio swing). */
  fun limitedLuma(full: Int): Int = 16 + (full * 219 + 127) / 255

  /** U or V mapped from full range to limited range, around 128. */
  fun limitedChroma(full: Int): Int = 128 + ((full - 128) * 224) / 255

  /**
   * Reads one plane of a decoded picture at (x, y) relative to the crop's corner ([left], [top],
   * already in this plane's coordinates), honouring its row and pixel strides (`Image.Plane`).
   */
  fun plane(buffer: java.nio.ByteBuffer, rowStride: Int, pixelStride: Int, left: Int, top: Int): (Int, Int) -> Int =
    { x, y -> buffer.get((top + y) * rowStride + (left + x) * pixelStride).toInt() and 0xFF }

  /** Mean |Y − Y'| over the grid. */
  fun delta(a: FrameStats, b: FrameStats): Double {
    var sum = 0L
    for (i in a.grid.indices) sum += abs(a.grid[i] - b.grid[i])
    return sum.toDouble() / a.grid.size
  }

  /**
   * The class of one frame on its own: BLACK, CARD or CONTENT (TRANSITION depends on the frames
   * around it, so only [decide] gives it). [delta] is against the nearest decoded frame at least
   * [NEIGHBOUR_MIN_US] away, null when there is none; [quiet] says its compressed sizes show no
   * change.
   */
  fun classify(stats: FrameStats, delta: Double?, quiet: Boolean): Pair<LeadInClass, CardKind?> {
    if (isBlack(stats)) return LeadInClass.BLACK to null
    val still = (delta != null && delta <= CARD_DELTA_MAX) || quiet
    val graphic = stats.flatness >= CARD_FLATNESS_MIN &&
      stats.contrast >= CARD_CONTRAST_MIN &&
      stats.twoTone >= CARD_TWO_TONE_MIN &&
      stats.bgNoise <= CARD_BG_NOISE_MAX
    if (!still || !graphic) return LeadInClass.CONTENT to null
    val kind = cardKind(stats)
    if (kind == CardKind.COLOURED && stats.chromaFlat < COLOURED_CHROMA_FLAT_MIN) return LeadInClass.CONTENT to null
    return LeadInClass.CARD to kind
  }

  fun isBlack(s: FrameStats): Boolean = s.p98 <= BLACK_P98_MAX && s.p50 <= BLACK_P50_MAX && s.blackShare >= BLACK_SHARE_MIN

  fun cardKind(s: FrameStats): CardKind = when {
    s.chroma >= COLOURED_CHROMA_MIN -> CardKind.COLOURED
    s.p50 <= DARK_P50_MAX -> CardKind.DARK
    else -> CardKind.LIGHT
  }

  /** Whether [samples]' inter frames over [fromUs, fromUs + QUIET_SPAN_US] show a still picture. */
  fun quiet(samples: List<VideoSample>, fromUs: Long): Boolean {
    val until = fromUs + QUIET_SPAN_US
    var bytes = 0L
    var count = 0
    var nearestKey: VideoSample? = null
    for (s in samples) {
      if (s.key) {
        if (nearestKey == null || abs(s.timeUs - fromUs) < abs(nearestKey.timeUs - fromUs)) nearestKey = s
        continue
      }
      if (s.timeUs in fromUs..until) {
        bytes += s.size
        count++
      }
    }
    if (count == 0) return false
    val limit = max(QUIET_MIN_BYTES.toDouble(), QUIET_KEY_SHARE * (nearestKey?.size ?: 0))
    return bytes.toDouble() / count <= limit
  }

  /** The 250 ms windows' inter-frame bytes and each window's floor ([RiseLocator]). */
  fun windows(samples: List<VideoSample>): RiseLocator = RiseLocator().also { r -> samples.forEach(r::add) }

  /**
   * Decides the cut for one clip (§3.4): every guard applies, and the result never passes the
   * first confirmed CONTENT frame. [LeadInDecision.startMs] is 0 for "play from the start".
   */
  fun decide(input: LeadInInput): LeadInDecision {
    val frames = input.frames.sortedBy { it.timeUs }
    val samples = input.samples.sortedBy { it.timeUs }
    if (input.durationMs <= 0L) return LeadInDecision.unknown("noduration")
    if (frames.isEmpty()) return LeadInDecision.unknown("noframe")
    val firstSampleUs = samples.firstOrNull()?.timeUs ?: frames.first().timeUs
    if (frames.first().timeUs > firstSampleUs) return LeadInDecision.unknown("noframe")

    // Raw classes, each against its nearest decoded neighbour.
    val raw = ArrayList<Pair<LeadInClass, CardKind?>>(frames.size)
    for ((i, f) in frames.withIndex()) {
      val n = neighbour(frames, i)
      raw += classify(f.stats, n?.let { delta(f.stats, it.stats) }, quiet(samples, f.timeUs))
    }
    val classes = raw.map { it.first }.toMutableList()
    val logClasses = { classes.indices.map { frames[it].timeUs / 1000 to describe(classes[it], raw[it].second) } }

    // Rule 1: starts at zero.
    if (raw[0].first == LeadInClass.CONTENT) return LeadInDecision.none("content", logClasses())

    // Rules 3 and 4: the first CONTENT frame confirmed by another 0.4 s later; unconfirmed ones
    // are a TRANSITION, at most 1 s of them.
    var leadEndUs: Long? = null
    var firstConfirmedUs: Long? = null
    var transitionUs = 0L
    var runStart = -1
    for (i in frames.indices) {
      if (raw[i].first != LeadInClass.CONTENT) {
        runStart = -1
        continue
      }
      val later = frames.indices.firstOrNull { it > i && frames[it].timeUs >= frames[i].timeUs + CONFIRM_US }
      val confirmed = later == null || raw[later].first == LeadInClass.CONTENT
      if (confirmed) {
        firstConfirmedUs = frames[i].timeUs
        if (leadEndUs == null) leadEndUs = frames[i].timeUs
        break
      }
      if (runStart < 0) runStart = i
      transitionUs += (frames.getOrNull(i + 1)?.timeUs ?: frames[i].timeUs) - frames[i].timeUs
      if (transitionUs > TRANSITION_MAX_US) {
        // Fades over 1 s count as content: the cut stops where this fade began.
        leadEndUs = frames[runStart].timeUs
        break
      }
      classes[i] = LeadInClass.TRANSITION
    }
    val frameUs = input.frameDurationUs.coerceAtLeast(1_000L)
    var partial = false
    if (input.refinePartial) {
      // Refine ran out: the last scored lead-in frame + one frame, never past content.
      val lastLead = frames.indices.lastOrNull { frames[it].timeUs < (leadEndUs ?: Long.MAX_VALUE) && classes[it] != LeadInClass.CONTENT }
      if (lastLead != null) {
        val partialEnd = frames[lastLead].timeUs + frameUs
        if (leadEndUs == null || partialEnd < leadEndUs) {
          leadEndUs = partialEnd
          partial = true
        }
      }
    }
    if (leadEndUs == null) return LeadInDecision.none("cap", logClasses())

    // Spans of the lead-in run from 0.
    val run = frames.indices.filter { frames[it].timeUs < leadEndUs }
    fun span(i: Int): Long = min(frames.getOrNull(i + 1)?.timeUs ?: leadEndUs, leadEndUs) - frames[i].timeUs
    val blackUs = run.filter { classes[it] == LeadInClass.BLACK }.sumOf(::span)
    val cardIdx = run.filter { classes[it] == LeadInClass.CARD }
    val cardUs = cardIdx.sumOf(::span)

    // Rule 2: a confirmed card or black from 0.
    if (cardUs < CARD_MIN_US && blackUs < BLACK_MIN_US) return LeadInDecision.none("nolead", logClasses())

    val kinds = cardIdx.mapNotNull { raw[it].second }.toSet()
    val cardStartUs = cardIdx.firstOrNull()?.let { frames[it].timeUs }
    val cardEndUs = cardIdx.lastOrNull()?.let { frames[it].timeUs + span(it) }
    val kind = when {
      CardKind.COLOURED in kinds -> CardKind.COLOURED.wire
      CardKind.DARK in kinds -> CardKind.DARK.wire
      CardKind.LIGHT in kinds -> CardKind.LIGHT.wire
      else -> "black"
    }
    val lead = when {
      cardIdx.isEmpty() -> "black"
      blackUs > 0 -> "card+black"
      else -> "card"
    }
    var cardQuietPct: Int? = null

    // A run with a coloured card and dark or light card frames too (an opening title on black
    // after the rating card, or the card dimming): where those frames begin when they are loud or
    // unmeasured (R4), and where the card before them ends.
    var strictFromUs: Long? = null
    var strictAfterCardUs: Long? = null

    // Rule 5: card rules by kind.
    if (cardStartUs != null && cardEndUs != null) {
      val cardLen = cardEndUs - cardStartUs
      if (CardKind.COLOURED in kinds) {
        if (cardStartUs > COLOURED_CARD_START_US || cardLen < COLOURED_CARD_MIN_US) {
          return LeadInDecision.none("card-rule", logClasses(), kind = kind)
        }
        // R4 holds for them as for a dark card on its own: cut only when quiet, else the cut
        // stops where they begin (a text opening plays over music or a voice).
        val strict = cardIdx.filter { raw[it].second != CardKind.COLOURED }
        if (strict.isNotEmpty()) {
          val quietShare = input.audio?.quietShare(strict.map { frames[it].timeUs to frames[it].timeUs + span(it) })
          cardQuietPct = quietShare?.let { (it * 100).toInt() }
          if (quietShare == null || quietShare < CARD_QUIET_SHARE) {
            val from = frames[strict.first()].timeUs
            strictFromUs = from
            strictAfterCardUs = cardIdx.filter { frames[it].timeUs < from }.maxOfOrNull { min(frames[it].timeUs + span(it), from) }
          }
        }
      } else {
        if (cardStartUs > STRICT_CARD_START_US || cardLen < STRICT_CARD_MIN_US || cardLen > STRICT_CARD_MAX_US) {
          return LeadInDecision.none("card-rule", logClasses(), kind = kind)
        }
        val audio = input.audio
        if (audio == null) {
          // A dark or light card can't be told from a silent-looking text opening without its
          // sound: logged, never cut.
          return LeadInDecision.none("audio-none", logClasses(), kind = kind, wouldCutMs = leadEndUs / 1000)
        }
        val quietShare = audio.quietShare(cardStartUs, cardEndUs)
        cardQuietPct = (quietShare * 100).toInt()
        if (quietShare < CARD_QUIET_SHARE) {
          return LeadInDecision.none("audio-loud", logClasses(), kind = kind, wouldCutMs = leadEndUs / 1000, cardQuietPct = cardQuietPct)
        }
      }
    }

    var cutUs: Long = leadEndUs
    var reason = if (partial) "partial" else "ok"
    strictFromUs?.let {
      if (it < cutUs) {
        cutUs = it
        reason = if (input.audio == null) "audio-none" else "audio-loud"
      }
    }

    // Rule 3b: never past a window that changed and wasn't scored.
    val rise = windows(samples)
    val scoredLead = HashMap<Long, LeadInClass>()
    for (i in frames.indices) scoredLead[frames[i].timeUs] = classes[i]
    for (w in 0 until rise.windowCount) {
      val ws = w * SIZE_WINDOW_US
      if (ws >= cutUs) break
      val we = min(ws + SIZE_WINDOW_US, cutUs)
      val inWindow = samples.filter { it.timeUs in ws until we }
      val bytes = inWindow.filter { !it.key }.sumOf { it.size.toLong() }
      val still = bytes <= rise.floor(w)
      val covered = inWindow.all { s -> scoredLead[s.timeUs].let { it != null && it != LeadInClass.CONTENT } }
      if (!still && !covered) {
        cutUs = ws
        reason = "unscored"
        break
      }
    }

    // Rule 11: the audio guard, from the end of the card the cut follows: the last card, or, when
    // the cut stopped at a loud or unmeasured title, the coloured card before it (none: from 0).
    val cardBeforeCutUs = if (strictFromUs != null) strictAfterCardUs else cardEndUs
    val endCardUs = cardBeforeCutUs ?: 0L
    val audio = input.audio
    var audioOnsetMs: Long? = null
    if (audio != null) {
      val onset = audio.onsetAtOrAfter(endCardUs)
      if (onset != null) {
        audioOnsetMs = onset / 1000
        if (onset < cutUs) {
          cutUs = onset
          reason = "audio"
        }
      }
    } else if (cardBeforeCutUs != null) {
      if (cardBeforeCutUs < cutUs) {
        cutUs = cardBeforeCutUs
        reason = "audio-none"
      }
    } else {
      return LeadInDecision.none("audio-none", logClasses(), kind = kind, wouldCutMs = cutUs / 1000)
    }

    // Rule 10: keyframe snap.
    var prerollMs = 0L
    val kc = samples.lastOrNull { it.key && it.timeUs <= cutUs }?.timeUs
    if (kc != null && kc < cutUs) {
      val between = frames.indices.filter { frames[it].timeUs in kc until cutUs }
      val dark = between.isNotEmpty() && between.all { classes[it] == LeadInClass.BLACK || classes[it] == LeadInClass.TRANSITION }
      if (dark && cutUs - kc <= SNAP_MAX_US) cutUs = kc else prerollMs = (cutUs - kc) / 1000
    }

    // Rule 3: never past the first confirmed CONTENT frame, whatever came before.
    if (firstConfirmedUs != null) cutUs = min(cutUs, firstConfirmedUs)

    val cutMs = toStartMs(cutUs, samples)

    // Rule 6: caps.
    val dur = input.durationMs
    if (cutMs < MIN_CUT_MS) return LeadInDecision.none("short", logClasses(), kind = kind)
    if (cutMs > MAX_CUT_MS || cutMs > dur * MAX_CUT_SHARE || cutMs > dur - END_MARGIN_MS) {
      return LeadInDecision.none("cap", logClasses(), kind = kind, wouldCutMs = cutMs)
    }
    return LeadInDecision(
      startMs = cutMs,
      kind = kind,
      lead = lead,
      reason = reason,
      prerollMs = prerollMs,
      firstContentMs = firstConfirmedUs?.let { it / 1000 },
      audioOnsetMs = audioOnsetMs,
      cardQuietPct = cardQuietPct,
      classes = logClasses()
    )
  }

  /**
   * The cut in whole ms, as `ClippingConfiguration` and the `src:` row keep it. Rounded down, so
   * the cut frame is still shown; but a keyframe inside that last millisecond would then fall
   * after the clip's start, and media3 would start decoding from the keyframe before it, a whole
   * GOP of hidden frames (R9). Then it rounds up past that keyframe instead: it is decoded and not
   * shown (one frame, black after a snap; at most one frame of a cut that opens on a keyframe).
   */
  fun toStartMs(cutUs: Long, samples: List<VideoSample>): Long {
    val down = cutUs / 1000
    val key = samples.firstOrNull { it.key && it.timeUs > down * 1000 && it.timeUs <= cutUs } ?: return down
    return (key.timeUs + 999) / 1000
  }

  /** The nearest decoded frame to frames[i] at least [NEIGHBOUR_MIN_US] away. */
  private fun neighbour(frames: List<ScoredFrame>, i: Int): ScoredFrame? {
    val t = frames[i].timeUs
    var best: ScoredFrame? = null
    for (f in frames) {
      val d = abs(f.timeUs - t)
      if (d < NEIGHBOUR_MIN_US) continue
      if (best == null || d < abs(best.timeUs - t)) best = f
    }
    return best
  }

  private fun describe(c: LeadInClass, kind: CardKind?): String = if (c == LeadInClass.CARD && kind != null) "CARD/${kind.short}" else c.name

  /** RMS of 16-bit samples as dBFS (−120 for silence). */
  fun dbfs(sumSquares: Double, count: Long): Double {
    if (count <= 0) return -120.0
    val rms = sqrt(sumSquares / count)
    if (rms <= 0.0) return -120.0
    return (20 * log10(rms / 32768.0)).coerceAtLeast(-120.0)
  }
}

internal enum class LeadInClass { BLACK, CARD, TRANSITION, CONTENT }

internal enum class CardKind(val short: String) {
  COLOURED("col"),
  DARK("dark"),
  LIGHT("light");

  val wire: String get() = name.lowercase()
}

/** One video sample's place and compressed size (no decode). */
internal data class VideoSample(val timeUs: Long, val size: Int, val key: Boolean)

/** A decoded, scored frame. */
internal class ScoredFrame(val timeUs: Long, val stats: FrameStats, val key: Boolean = false)

/**
 * The scores of one frame over a [LeadInPolicy.GRID_W] × [LeadInPolicy.GRID_H] grid of the
 * picture's centre, in limited range (§3.3).
 */
internal class FrameStats(
  val mean: Double,
  val p2: Int,
  val p50: Int,
  val p98: Int,
  val flatness: Double,
  val contrast: Int,
  val chroma: Double,
  val twoTone: Double,
  val bgNoise: Double,
  val chromaFlat: Double,
  val blackShare: Double,
  val grid: IntArray
) {
  /** `y95 F.91 c62 T.97 n1.2 cf.88` for the `kf` / `refine` lines. */
  fun short(): String = "y${p50} F.${pct(flatness)} c$contrast T.${pct(twoTone)} n${"%.1f".format(bgNoise)} cf.${pct(chromaFlat)} p98 $p98 ch${chroma.toInt()}"

  private fun pct(v: Double): String = "%02d".format((v * 100).toInt().coerceIn(0, 99))

  companion object {
    /**
     * Scores a picture [width] × [height] (the crop, never the coded size). [y] reads luma at
     * (x, y); [u] and [v] read chroma at (x/2, y/2), already in chroma-plane coordinates.
     * [fullRange] maps the values to limited range first.
     */
    fun of(width: Int, height: Int, fullRange: Boolean, y: (Int, Int) -> Int, u: (Int, Int) -> Int, v: (Int, Int) -> Int): FrameStats {
      val n = LeadInPolicy.GRID_W * LeadInPolicy.GRID_H
      val ys = IntArray(n)
      val us = IntArray(n)
      val vs = IntArray(n)
      val x0 = width * LeadInPolicy.COL_FROM
      val xs = width * (LeadInPolicy.COL_TO - LeadInPolicy.COL_FROM) / LeadInPolicy.GRID_W
      val y0 = height * LeadInPolicy.ROW_FROM
      val yst = height * (LeadInPolicy.ROW_TO - LeadInPolicy.ROW_FROM) / LeadInPolicy.GRID_H
      var k = 0
      for (gy in 0 until LeadInPolicy.GRID_H) {
        val py = (y0 + (gy + 0.5) * yst).toInt().coerceIn(0, height - 1)
        for (gx in 0 until LeadInPolicy.GRID_W) {
          val px = (x0 + (gx + 0.5) * xs).toInt().coerceIn(0, width - 1)
          var yy = y(px, py)
          var uu = u(px / 2, py / 2)
          var vv = v(px / 2, py / 2)
          if (fullRange) {
            yy = LeadInPolicy.limitedLuma(yy)
            uu = LeadInPolicy.limitedChroma(uu)
            vv = LeadInPolicy.limitedChroma(vv)
          }
          ys[k] = yy
          us[k] = uu
          vs[k] = vv
          k++
        }
      }
      return fromSamples(ys, us, vs)
    }

    /** Scores a grid of samples already read (limited range). */
    fun fromSamples(ys: IntArray, us: IntArray, vs: IntArray): FrameStats {
      val n = ys.size
      val sorted = ys.sortedArray()
      fun pct(p: Double) = sorted[((n - 1) * p).toInt()]
      val p2 = pct(0.02)
      val p50 = pct(0.50)
      val p98 = pct(0.98)
      var sum = 0L
      var flat = 0
      var black = 0
      var bgCount = 0
      var bgSum = 0.0
      var bgSq = 0.0
      val inkVals = ArrayList<Int>()
      for (yy in ys) {
        sum += yy
        val d = abs(yy - p50)
        if (d <= LeadInPolicy.FLAT_SPREAD) flat++
        if (d <= LeadInPolicy.BLACK_SPREAD) black++
        if (d <= LeadInPolicy.TWO_TONE_BG) {
          bgCount++
          bgSum += yy
          bgSq += yy.toDouble() * yy
        } else {
          inkVals += yy
        }
      }
      val ink = if (inkVals.isEmpty()) null else inkVals.sorted()[inkVals.size / 2]
      var twoTone = 0
      for (yy in ys) {
        if (abs(yy - p50) <= LeadInPolicy.TWO_TONE_BG || (ink != null && abs(yy - ink) <= LeadInPolicy.TWO_TONE_INK)) twoTone++
      }
      val bgMean = if (bgCount > 0) bgSum / bgCount else 0.0
      val bgNoise = if (bgCount > 1) sqrt((bgSq / bgCount - bgMean * bgMean).coerceAtLeast(0.0)) else 0.0
      val meanU = us.average()
      val meanV = vs.average()
      val medU = us.sortedArray()[n / 2]
      val medV = vs.sortedArray()[n / 2]
      var chromaFlat = 0
      for (i in 0 until n) {
        if (abs(us[i] - medU) <= LeadInPolicy.CHROMA_FLAT_SPREAD && abs(vs[i] - medV) <= LeadInPolicy.CHROMA_FLAT_SPREAD) chromaFlat++
      }
      return FrameStats(
        mean = sum.toDouble() / n,
        p2 = p2,
        p50 = p50,
        p98 = p98,
        flatness = flat.toDouble() / n,
        contrast = max(p98 - p50, p50 - p2),
        chroma = max(abs(meanU - 128), abs(meanV - 128)),
        twoTone = twoTone.toDouble() / n,
        bgNoise = bgNoise,
        chromaFlat = chromaFlat.toDouble() / n,
        blackShare = black.toDouble() / n,
        grid = ys
      )
    }
  }
}

/**
 * The 250 ms windows of inter-frame bytes (keyframes ignored), and the rise: the first window
 * that starts a run of [LeadInPolicy.RISE_RUN] above the floor. A still card or black encodes as
 * tiny P-frames, so the rise is where the picture starts to move (§3.2 step 4).
 */
internal class RiseLocator {
  private val bytes = ArrayList<Long>()

  val windowCount: Int get() = bytes.size

  fun add(sample: VideoSample) {
    val w = (sample.timeUs / LeadInPolicy.SIZE_WINDOW_US).toInt().coerceAtLeast(0)
    while (bytes.size <= w) bytes += 0L
    if (!sample.key) bytes[w] = bytes[w] + sample.size
  }

  fun bytes(w: Int): Long = bytes.getOrElse(w) { 0L }

  /** max(4 KB, 5 % of the mean window bytes up to and including [w]). */
  fun floor(w: Int): Long {
    if (bytes.isEmpty()) return LeadInPolicy.SIZE_FLOOR_MIN_BYTES
    val upto = min(w, bytes.size - 1)
    var sum = 0L
    for (i in 0..upto) sum += bytes[i]
    val mean = sum.toDouble() / (upto + 1)
    return max(LeadInPolicy.SIZE_FLOOR_MIN_BYTES, (mean * LeadInPolicy.SIZE_FLOOR_MEAN_SHARE).toLong())
  }

  /**
   * The rise's start in µs, once the windows up to [completeBeforeUs] are complete; null when no
   * run of [LeadInPolicy.RISE_RUN] above-floor windows has finished yet.
   */
  fun rise(completeBeforeUs: Long = Long.MAX_VALUE): Long? {
    val complete = min(bytes.size.toLong(), completeBeforeUs / LeadInPolicy.SIZE_WINDOW_US).toInt()
    for (w in 0..complete - LeadInPolicy.RISE_RUN) {
      if ((w until w + LeadInPolicy.RISE_RUN).all { bytes[it] > floor(it) }) return w * LeadInPolicy.SIZE_WINDOW_US
    }
    return null
  }

  /** The first 32 windows in KB, for the `sizes` line. */
  fun describe(): String = bytes.take(32).joinToString(",") { "%.1f".format(it / 1024.0) }
}

/** 100 ms RMS levels from t = 0, in dBFS. */
internal class AudioLevels(val dbfs: DoubleArray) {
  private fun window(us: Long): Int = (us / LeadInPolicy.AUDIO_WINDOW_US).toInt()

  /** The share of [fromUs, toUs) whose windows are below [LeadInPolicy.AUDIBLE_DBFS]. */
  fun quietShare(fromUs: Long, toUs: Long): Double {
    val a = window(fromUs)
    val b = window(toUs - 1).coerceAtLeast(a)
    var quiet = 0
    var total = 0
    for (w in a..b) {
      total++
      if ((dbfs.getOrNull(w) ?: -120.0) <= LeadInPolicy.AUDIBLE_DBFS) quiet++
    }
    return if (total == 0) 1.0 else quiet.toDouble() / total
  }

  /**
   * The share of the windows [spans] (each from, to in µs) cover that are below
   * [LeadInPolicy.AUDIBLE_DBFS]; windows past what was read count as quiet, as in [quietShare].
   */
  fun quietShare(spans: List<Pair<Long, Long>>): Double {
    val windows = HashSet<Int>()
    for ((from, to) in spans) {
      if (to <= from) continue
      for (w in window(from)..window(to - 1)) windows += w
    }
    if (windows.isEmpty()) return 1.0
    return windows.count { (dbfs.getOrNull(it) ?: -120.0) <= LeadInPolicy.AUDIBLE_DBFS }.toDouble() / windows.size
  }

  /**
   * The start of the first audible stretch (above [LeadInPolicy.AUDIBLE_DBFS] for at least
   * [LeadInPolicy.AUDIBLE_RUN_US]) starting at or after [fromUs], in µs; null when none.
   */
  fun onsetAtOrAfter(fromUs: Long): Long? {
    val need = (LeadInPolicy.AUDIBLE_RUN_US / LeadInPolicy.AUDIO_WINDOW_US).toInt()
    var w = ((fromUs + LeadInPolicy.AUDIO_WINDOW_US - 1) / LeadInPolicy.AUDIO_WINDOW_US).toInt()
    while (w + need <= dbfs.size) {
      if ((w until w + need).all { dbfs[it] > LeadInPolicy.AUDIBLE_DBFS }) return w * LeadInPolicy.AUDIO_WINDOW_US
      w++
    }
    return null
  }
}

/** What [LeadInPolicy.decide] needs about one clip. */
internal class LeadInInput(
  val samples: List<VideoSample>,
  val frames: List<ScoredFrame>,
  val durationMs: Long,
  val frameDurationUs: Long,
  val audio: AudioLevels?,
  val refinePartial: Boolean = false
)

/**
 * One clip's answer. [startMs] 0 is "play from the start" ([reason] says why); [unknown] means
 * nothing is cached and the clip may be measured again.
 */
internal data class LeadInDecision(
  val startMs: Long,
  val kind: String,
  val lead: String,
  val reason: String,
  val prerollMs: Long = 0L,
  val firstContentMs: Long? = null,
  val wouldCutMs: Long? = null,
  val audioOnsetMs: Long? = null,
  val cardQuietPct: Int? = null,
  val unknown: Boolean = false,
  val classes: List<Pair<Long, String>> = emptyList()
) {
  companion object {
    fun none(reason: String, classes: List<Pair<Long, String>>, kind: String = "none", wouldCutMs: Long? = null, cardQuietPct: Int? = null) = LeadInDecision(
      startMs = 0L,
      kind = kind,
      lead = "none",
      reason = reason,
      wouldCutMs = wouldCutMs,
      cardQuietPct = cardQuietPct,
      classes = classes
    )

    fun unknown(reason: String) = LeadInDecision(startMs = 0L, kind = "none", lead = "none", reason = reason, unknown = true)
  }
}
