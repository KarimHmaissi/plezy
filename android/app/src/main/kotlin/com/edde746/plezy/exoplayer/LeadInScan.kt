package com.edde746.plezy.exoplayer

import java.io.IOException

/**
 * V2-23: what one detection reads a clip through. The real one is an extractor plus a software
 * decoder ([MediaFrameSource]); the JVM tests feed synthetic samples and frames.
 */
internal interface FrameSource : AutoCloseable {
  /** Opens the clip and picks its tracks; throws [LeadInSkip] for a clip that is never measured. */
  fun open(): TrackInfo

  /** Advances to the next video sample (audio is read on the way); null at the end. */
  fun next(): VideoSample?

  /**
   * Queues the current video sample for decoding. With [endOfRun] the decoder is drained to its
   * end of stream and flushed, so every frame queued since the last run comes out. Returns the
   * frames that came out (any order).
   */
  fun decode(endOfRun: Boolean): List<ScoredFrame>

  /** Ends a decoder run that [decode] left open (the clip ended first); returns its frames. */
  fun drain(): List<ScoredFrame>

  /** Moves to the keyframe at or before [timeUs]; the next [next] returns it. */
  fun seekTo(timeUs: Long)

  /** 100 ms audio levels read so far, or null when the clip's audio can't be measured. */
  fun audio(): AudioLevels?

  /** The decoder's name, for the `detect` line. */
  val codecName: String

  /** Whether the decoder said its output is full range (known after the first frame). */
  val fullRange: Boolean get() = false

  /** Decode time per frame, for the `result` line. */
  val decodeMsAvg: Long get() = 0L
  val decodeMsMax: Long get() = 0L

  /** How far into the file the reads had gone when the first sample at or after [timeUs] came. */
  fun bytePositionAt(timeUs: Long): Long? = null
}

/** What [FrameSource.open] found. */
internal data class TrackInfo(
  val width: Int,
  val height: Int,
  val durationUs: Long,
  val frameDurationUs: Long,
  val fullRange: Boolean,
  val fps: Float,
  val audio: String
)

/** A clip the detector never measures (HDR, 10-bit, DV, encrypted, no software decoder, codec). */
internal class LeadInSkip(val reason: String) : IOException(reason)

/** A detection stopped from outside (a cancel, a budget). Never carries a URI. */
internal class LeadInAbort(val reason: String) : IOException(reason)

/** The caps on one detection (§4.6). */
internal data class LeadInBudget(
  val maxFrames: Int = 120,
  val maxReadUs: Long = 16_000_000L,
  val headUs: Long = 500_000L
)

/** What the scan read and decided. */
internal class ScanResult(
  val info: TrackInfo,
  val decision: LeadInDecision,
  val samples: List<VideoSample>,
  val frames: List<ScoredFrame>,
  val keyframes: List<ScoredFrame>,
  val refineFrom: Long?,
  val refineFrames: List<ScoredFrame>,
  val riseUs: Long?,
  val rise: RiseLocator,
  val decoded: Int
)

/**
 * One detection's read (§3.2): a contiguous decode of the first [LeadInBudget.headUs], every
 * keyframe after that until the picture is clearly content, the compressed sizes to find where it
 * starts to move, and one contiguous decode around that point. [checkpoint] runs between steps and
 * throws [LeadInAbort] to stop.
 */
internal class LeadInScan(
  private val source: FrameSource,
  private val budget: LeadInBudget = LeadInBudget(),
  private val checkpoint: () -> Unit = {}
) {
  private var decoded = 0

  /** A decoder run is open: frames were queued with no end of stream yet. */
  private var openRun = false

  private fun decode(endOfRun: Boolean): List<ScoredFrame> {
    if (decoded >= budget.maxFrames) throw LeadInAbort("budget")
    decoded++
    checkpoint()
    openRun = !endOfRun
    return source.decode(endOfRun)
  }

  private fun closeRun(): List<ScoredFrame> {
    if (!openRun) return emptyList()
    openRun = false
    return source.drain()
  }

  fun run(): ScanResult {
    val info = source.open()
    val samples = ArrayList<VideoSample>()
    val frames = ArrayList<ScoredFrame>()
    val keyframes = ArrayList<ScoredFrame>()
    val rise = RiseLocator()

    // 1. The head: contiguous from t = 0 for 0.5 s, one decoder run.
    val head = source.next() ?: return finish(info, samples, frames, keyframes, null, emptyList(), rise, partial = false)
    val firstUs = head.timeUs
    var sample: VideoSample? = head
    while (sample != null) {
      checkpoint()
      samples += sample
      rise.add(sample)
      val last = sample.timeUs >= firstUs + budget.headUs
      frames += decode(endOfRun = last).map { ScoredFrame(it.timeUs, it.stats, key = it.timeUs == firstUs) }
      if (last) break
      sample = source.next()
    }
    frames += closeRun()
    keyframes += frames.filter { it.timeUs == firstUs }

    // Early exit: the first frame and one 0.4 s later are both content.
    val early = provisional(frames, samples)
    val later = frames.filter { it.timeUs >= firstUs + LeadInPolicy.CONFIRM_US }.minByOrNull { it.timeUs }
    if (early[firstUs] == LeadInClass.CONTENT && later != null && early[later.timeUs] == LeadInClass.CONTENT) {
      return finish(info, samples, frames, keyframes, null, emptyList(), rise, partial = false)
    }

    // 2–4. Every keyframe until content, sizes all the way, stop at rise + 1 s.
    var contentKeyUs: Long? = null
    var stopAtUs: Long? = null
    sample = source.next()
    while (sample != null) {
      checkpoint()
      val cur: VideoSample = sample
      samples += cur
      rise.add(cur)
      if (cur.timeUs > budget.maxReadUs) break
      if (cur.key) {
        val out = decode(endOfRun = true)
        val scored = out.map { ScoredFrame(it.timeUs, it.stats, key = true) }
        frames += scored
        keyframes += scored
      }
      // Classify the keyframes once their 0.5 s of sizes is read.
      if (contentKeyUs == null) {
        val classes = provisional(frames, samples)
        contentKeyUs = keyframes.firstOrNull { k ->
          k.timeUs > firstUs && cur.timeUs >= k.timeUs + LeadInPolicy.QUIET_SPAN_US && classes[k.timeUs] == LeadInClass.CONTENT
        }?.timeUs
      }
      if (stopAtUs == null) {
        val r = rise.rise(completeBeforeUs = cur.timeUs)
        if (r != null) stopAtUs = r + 1_000_000L
      }
      val stop = minOf(stopAtUs ?: Long.MAX_VALUE, contentKeyUs?.plus(1_000_000L) ?: Long.MAX_VALUE)
      if (cur.timeUs >= stop) break
      sample = source.next()
    }
    val riseUs = rise.rise()

    // 5. Refine: decode contiguously from the last lead-in keyframe to the first content (or the
    // rise) + 0.5 s, and further back over any window that changed between keyframes (rule 3b).
    val classes = provisional(frames, samples)
    val leadKeys = keyframes.filter { classes[it.timeUs] != LeadInClass.CONTENT && it.timeUs < (contentKeyUs ?: Long.MAX_VALUE) }
    val kj = leadKeys.lastOrNull()?.timeUs ?: return finish(info, samples, frames, keyframes, riseUs, emptyList(), rise, partial = false)
    val target = minOf(contentKeyUs ?: Long.MAX_VALUE, riseUs ?: Long.MAX_VALUE).let { if (it == Long.MAX_VALUE) samples.last().timeUs else it } + 500_000L
    var from = kj
    val frameUs = info.frameDurationUs.coerceAtLeast(1_000L)
    val firstChanged = (0 until rise.windowCount).firstOrNull { w ->
      val ws = w * LeadInPolicy.SIZE_WINDOW_US
      ws < kj && rise.bytes(w) > rise.floor(w)
    }
    if (firstChanged != null) {
      val back = samples.lastOrNull { it.key && it.timeUs <= firstChanged * LeadInPolicy.SIZE_WINDOW_US }?.timeUs
      if (back != null && (target - back) / frameUs <= budget.maxFrames - decoded) from = back
    }
    val refined = ArrayList<ScoredFrame>()
    var partial = false
    source.seekTo(from)
    var s = source.next()
    try {
      while (s != null && s.timeUs <= target) {
        checkpoint()
        // Samples come in decode order; the run ends on the first one past the target (or the
        // frame budget), drained so every frame queued comes out.
        val budgetLast = decoded + 1 >= budget.maxFrames
        val targetLast = s.timeUs + frameUs > target
        refined += decode(endOfRun = budgetLast || targetLast)
        if (targetLast) break
        if (budgetLast) {
          partial = true
          break
        }
        s = source.next()
      }
    } catch (e: LeadInAbort) {
      if (e.reason != "budget") throw e
      partial = true
    }
    refined += closeRun()
    val byTime = HashMap<Long, ScoredFrame>()
    for (f in frames) byTime[f.timeUs] = f
    for (f in refined) byTime[f.timeUs] = f
    return finish(info, samples, byTime.values.sortedBy { it.timeUs }, keyframes, riseUs, refined, rise, partial, from)
  }

  private fun finish(
    info: TrackInfo,
    samples: List<VideoSample>,
    frames: List<ScoredFrame>,
    keyframes: List<ScoredFrame>,
    riseUs: Long?,
    refined: List<ScoredFrame>,
    rise: RiseLocator,
    partial: Boolean,
    refineFrom: Long? = null
  ): ScanResult {
    val input = LeadInInput(
      samples = samples,
      frames = frames,
      durationMs = if (info.durationUs > 0) info.durationUs / 1000 else -1L,
      frameDurationUs = info.frameDurationUs,
      audio = source.audio(),
      refinePartial = partial
    )
    return ScanResult(
      info = info,
      decision = LeadInPolicy.decide(input),
      samples = samples,
      frames = frames,
      keyframes = keyframes,
      refineFrom = refineFrom,
      refineFrames = refined,
      riseUs = riseUs,
      rise = rise,
      decoded = decoded
    )
  }

  /** Each scored frame's own class (no TRANSITION), by time. */
  private fun provisional(frames: List<ScoredFrame>, samples: List<VideoSample>): Map<Long, LeadInClass> {
    val out = HashMap<Long, LeadInClass>()
    for (f in frames) {
      var best: ScoredFrame? = null
      for (o in frames) {
        val d = kotlin.math.abs(o.timeUs - f.timeUs)
        if (d < LeadInPolicy.NEIGHBOUR_MIN_US) continue
        if (best == null || d < kotlin.math.abs(best.timeUs - f.timeUs)) best = o
      }
      out[f.timeUs] = LeadInPolicy.classify(f.stats, best?.let { LeadInPolicy.delta(f.stats, it.stats) }, LeadInPolicy.quiet(samples, f.timeUs)).first
    }
    return out
  }
}
