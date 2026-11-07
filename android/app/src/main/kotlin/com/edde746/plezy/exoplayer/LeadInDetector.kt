package com.edde746.plezy.exoplayer

import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo.CodecCapabilities
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.inspector.MediaExtractorCompat
import java.io.InterruptedIOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

/**
 * V2-23: one clip to measure. [uri] is never logged ([logId] is the cache key's hash); [source]
 * builds the clip's reader on the detector's thread; [onResult] runs on the main thread.
 */
internal class LeadInJob(
  val uri: String,
  val key: String,
  val rank: ClipPreloadRank,
  val owner: Any,
  val log: (String) -> Unit,
  val source: (LeadInControl) -> FrameSource,
  val onResult: (LeadInOutcome) -> Unit
) {
  val logId: String get() = ClipCachePolicy.logId(key)
  val rankWire: String get() = if (rank == ClipPreloadRank.AHEAD) "ahead" else "next"
}

/**
 * How one detection ended: a [decision] (cached when not [LeadInDecision.unknown]), a
 * [skipReason] (cached as 0 with that reason), or an [abortReason] (nothing cached).
 */
internal class LeadInOutcome(
  val job: LeadInJob,
  val decision: LeadInDecision? = null,
  val skipReason: String? = null,
  val abortReason: String? = null,
  val leadBytes: Long? = null
) {
  /** A definite answer: a decision that is not unknown, or a skip. */
  val definite: Boolean get() = skipReason != null || (decision != null && !decision.unknown)

  /** The start to use, when [definite]. */
  val startMs: Long get() = if (skipReason != null) 0L else decision?.startMs ?: 0L
}

/**
 * A running detection's switches: a cancel (seen at the next checkpoint or the next socket read),
 * a pause (waited out, not counted against the wall budget), and the caps on bytes and wall time.
 */
internal class LeadInControl(
  private val isPaused: () -> Boolean = { false },
  private val wallBudgetMs: Long = WALL_BUDGET_MS,
  private val byteBudget: Long = BYTE_BUDGET,
  private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
  private val sleepMs: (Long) -> Unit = { Thread.sleep(it) }
) {
  @Volatile var cancelReason: String? = null
    private set

  @Volatile private var cancelledAtMs = 0L
  private val startedMs = nowMs()
  private var pausedMs = 0L
  private var lastPaceMs = 0L

  val bytesRead = AtomicLong()
  val bytesFromCache = AtomicLong()

  val cancelled: Boolean get() = cancelReason != null

  fun cancel(reason: String) {
    if (cancelReason != null) return
    cancelledAtMs = nowMs()
    cancelReason = reason
  }

  /** Throws [LeadInAbort] on a cancel or a spent budget; waits while paused. */
  fun check() {
    cancelReason?.let { throw LeadInAbort(it) }
    if (isPaused()) {
      val from = nowMs()
      while (isPaused()) {
        cancelReason?.let { throw LeadInAbort(it) }
        sleepMs(PAUSE_POLL_MS)
      }
      pausedMs += nowMs() - from
    }
    if (bytesRead.get() > byteBudget) throw LeadInAbort("budget")
    if (wallMs > wallBudgetMs) throw LeadInAbort("budget")
  }

  /** At most [MAX_DECODES_PER_SECOND] decodes a second (input pacing, §4.6). */
  fun pace() {
    val gap = 1000L / MAX_DECODES_PER_SECOND
    val wait = lastPaceMs + gap - nowMs()
    if (lastPaceMs > 0 && wait > 0) sleepMs(wait)
    lastPaceMs = nowMs()
  }

  val wallMs: Long get() = nowMs() - startedMs - pausedMs

  /** From the cancel to now: how long an abort took to land (`abortMs`). */
  val abortMs: Long get() = if (cancelledAtMs == 0L) 0L else nowMs() - cancelledAtMs

  companion object {
    const val WALL_BUDGET_MS = 8_000L
    const val BYTE_BUDGET = 24L * 1024 * 1024
    const val MAX_DECODES_PER_SECOND = 30
    const val PAUSE_POLL_MS = 50L
  }
}

/**
 * V2-23: the live non-clip player cores (ExoPlayer main player, MPV). The detector never starts
 * while one exists and stops the moment one appears (`abort reason=mainPlayer`).
 */
internal object MainPlaybackGate {
  private val count = AtomicInteger()
  private val listeners = CopyOnWriteArrayList<(Int) -> Unit>()

  val value: Int get() = count.get()

  fun up() {
    val n = count.incrementAndGet()
    listeners.forEach { it(n) }
  }

  fun down() {
    val n = count.updateAndGet { (it - 1).coerceAtLeast(0) }
    listeners.forEach { it(n) }
  }

  fun addListener(listener: (Int) -> Unit) {
    listeners += listener
  }

  fun removeListener(listener: (Int) -> Unit) {
    listeners -= listener
  }

  @VisibleForTesting
  fun resetForTest() {
    count.set(0)
  }
}

/**
 * V2-23: the detector's queue: at most one job running and one waiting, the card two ahead before
 * the next card (R1), one answer per clip per process, and an unknown answer retried once.
 * [execute] runs a job off the main thread; [deliver] brings its outcome back to the main thread.
 */
internal class LeadInQueue(
  private val execute: (Runnable) -> Unit,
  private val deliver: (Runnable) -> Unit,
  private val gate: () -> Int,
  private val runner: (LeadInJob, LeadInControl) -> LeadInOutcome = LeadInRunner::run
) {
  private val lock = Any()
  private var running: Pair<LeadInJob, LeadInControl>? = null
  private var waiting: LeadInJob? = null
  private val pauses = HashSet<String>()
  @Volatile private var paused = false

  /** Keys with a definite answer this process. */
  private val answered = HashSet<String>()

  /** Unknown answers per key; a clip is measured at most [MAX_ATTEMPTS] times a process. */
  private val attempts = HashMap<String, Int>()

  val isPaused: Boolean get() = paused

  /** Asks for a detection; false when it isn't queued (logged). */
  fun request(job: LeadInJob): Boolean {
    val g = gate()
    synchronized(lock) {
      if (g > 0) {
        job.log("skip id=${job.logId} reason=gate gate=$g")
        return false
      }
      if (job.key in answered || (attempts[job.key] ?: 0) >= MAX_ATTEMPTS) return false
      if (running?.first?.key == job.key || waiting?.key == job.key) return false
      val lockRisk = if (job.rank == ClipPreloadRank.NEXT) " lockRisk=1" else ""
      if (running == null) {
        job.log("request id=${job.logId} rank=${job.rankWire} queued=0 gate=$g$lockRisk")
        start(job)
        return true
      }
      val held = waiting
      if (held != null) {
        // The card two ahead goes first (R1); between equals, the newer ask wins.
        if (held.rank == ClipPreloadRank.AHEAD && job.rank == ClipPreloadRank.NEXT) return false
        held.log("abort id=${held.logId} reason=superseded")
      }
      waiting = job
      job.log("request id=${job.logId} rank=${job.rankWire} queued=1 gate=$g$lockRisk")
      return true
    }
  }

  private fun start(job: LeadInJob) {
    val control = LeadInControl(isPaused = { paused })
    running = job to control
    execute(
      Runnable {
        val outcome = try {
          runner(job, control)
        } catch (e: Exception) {
          LeadInOutcome(job, abortReason = "error:${e.javaClass.simpleName}")
        }
        if (outcome.abortReason != null) {
          job.log("abort id=${job.logId} reason=${outcome.abortReason} abortMs=${control.abortMs}")
        }
        finish(job, outcome)
      }
    )
  }

  private fun finish(job: LeadInJob, outcome: LeadInOutcome) {
    synchronized(lock) {
      if (outcome.definite) {
        answered += job.key
      } else if (countsAsTry(outcome.abortReason) || outcome.decision?.unknown == true) {
        attempts[job.key] = (attempts[job.key] ?: 0) + 1
      }
      running = null
      val next = waiting
      waiting = null
      if (next != null) start(next)
    }
    deliver(Runnable { job.onResult(outcome) })
  }

  /** Stops [uri]'s detection, running or waiting. */
  fun cancel(uri: String, reason: String) {
    synchronized(lock) {
      running?.let { (job, control) -> if (job.uri == uri) control.cancel(reason) }
      waiting?.let {
        if (it.uri == uri) {
          waiting = null
          it.log("abort id=${it.logId} reason=$reason")
        }
      }
    }
  }

  /** Stops every detection (of [owner] only, when given). */
  fun cancelAll(reason: String, owner: Any? = null) {
    synchronized(lock) {
      running?.let { (job, control) -> if (owner == null || job.owner === owner) control.cancel(reason) }
      waiting?.let {
        if (owner == null || it.owner === owner) {
          waiting = null
          it.log("abort id=${it.logId} reason=$reason")
        }
      }
    }
  }

  /** Stops [owner]'s detections of any clip not in [keep] (it left the window, D15). */
  fun cancelExcept(owner: Any, keep: Set<String>, reason: String) {
    synchronized(lock) {
      running?.let { (job, control) -> if (job.owner === owner && job.uri !in keep) control.cancel(reason) }
      waiting?.let {
        if (it.owner === owner && it.uri !in keep) {
          waiting = null
          it.log("abort id=${it.logId} reason=$reason")
        }
      }
    }
  }

  /** Whether [uri] is being measured or waits to be. */
  fun busyWith(uri: String): Boolean = synchronized(lock) { running?.first?.uri == uri || waiting?.uri == uri }

  /** Whether [key] has a definite answer this process. */
  fun answered(key: String): Boolean = synchronized(lock) { key in answered }

  fun pause(reason: String) {
    synchronized(lock) {
      pauses += reason
      paused = true
    }
  }

  fun resume(reason: String) {
    synchronized(lock) {
      pauses -= reason
      paused = pauses.isNotEmpty()
    }
  }

  /** Clears every pause (the clip core went away). */
  fun resumeAll() {
    synchronized(lock) {
      pauses.clear()
      paused = false
    }
  }

  @VisibleForTesting
  fun pauseReasons(): Set<String> = synchronized(lock) { pauses.toSet() }

  companion object {
    const val MAX_ATTEMPTS = 2

    /** Aborts that count as a try (the clip itself was the problem), unlike a cancel. */
    private val COUNTED_ABORTS = setOf("budget", "decoder", "format")

    /**
     * Whether an abort counts against [MAX_ATTEMPTS]: the clip's own failures, a read error
     * (`error:<class>`) or a timed-out read (`io`) included, so a clip that can't be read isn't
     * read again on every preload (design §3.4 rule 7). A cancel ([cancel], [cancelAll]) never
     * counts: the runner reports it by its cancel reason.
     */
    @VisibleForTesting
    internal fun countsAsTry(reason: String?): Boolean =
      reason != null && (reason in COUNTED_ABORTS || reason == "io" || reason.startsWith("error:"))
  }
}

/**
 * V2-23: the process-wide detector (§4.1, §4.6). One background thread, started once and never
 * quit: on the Shield each MediaCodec leaves a display listener on its creating thread's looper
 * ([PlayerCoreCounts]), so codecs made here never land on a dead thread. Its decoders are reused
 * per MIME and released when a clip core is released.
 */
internal object LeadInDetector {
  private val thread: HandlerThread by lazy {
    HandlerThread("ReelLeadIn", Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
  }
  private val handler: Handler by lazy { Handler(thread.looper) }
  private val main: Handler by lazy { Handler(Looper.getMainLooper()) }

  /** The decoders, touched on the detector's thread only. */
  val codecs = DetectorCodecs()

  val queue: LeadInQueue by lazy {
    LeadInQueue(execute = { handler.post(it) }, deliver = { main.post(it) }, gate = { MainPlaybackGate.value }).also { q ->
      MainPlaybackGate.addListener { n -> if (n > 0) q.cancelAll("mainPlayer") }
    }
  }

  /** The clip core is going: every job stops and the decoders are released. */
  fun release(owner: Any) {
    queue.cancelAll("released", owner)
    queue.resumeAll()
    handler.post { codecs.releaseAll() }
  }
}

/** V2-23: runs one job: the scan, the decision and its `[ReelLeadIn]` lines. */
internal object LeadInRunner {
  fun run(job: LeadInJob, control: LeadInControl): LeadInOutcome {
    val id = job.logId
    val source = try {
      job.source(control)
    } catch (e: Exception) {
      return LeadInOutcome(job, abortReason = "error:${e.javaClass.simpleName}")
    }
    try {
      val scan = LeadInScan(source, checkpoint = control::check).run()
      val info = scan.info
      val d = scan.decision
      job.log(
        "detect id=$id sdk=${android.os.Build.VERSION.SDK_INT} codec=${source.codecName} sw=true ${info.width}x${info.height} " +
          "range=${if (source.fullRange) "full" else "limited"} fps=${"%.3f".format(info.fps)} dur=${info.durationUs / 1000} audio=${info.audio}"
      )
      val classOf = d.classes.toMap()
      job.log("kf id=$id [${scan.keyframes.joinToString(" | ") { "${it.timeUs / 1000}:${classOf[it.timeUs / 1000] ?: "-"} ${it.stats.short()}" }}]")
      job.log("sizes id=$id floor=${"%.1f".format(scan.rise.floor(scan.rise.windowCount - 1) / 1024.0)}KB rise=${scan.riseUs?.div(1000) ?: "none"} win=[${scan.rise.describe()}]")
      if (scan.refineFrom != null) {
        job.log(
          "refine id=$id from=${scan.refineFrom / 1000} frames=${scan.refineFrames.size} " +
            "[${scan.refineFrames.sortedBy { it.timeUs }.joinToString(" ") { "${it.timeUs / 1000}:${classOf[it.timeUs / 1000] ?: "-"} T.${(it.stats.twoTone * 100).toInt()} n${"%.1f".format(it.stats.bgNoise)} cf.${(it.stats.chromaFlat * 100).toInt()}" }}]"
        )
      }
      val leadBytes = if (d.startMs > 0) source.bytePositionAt(d.startMs * 1000) else null
      val read = control.bytesRead.get()
      val cached = control.bytesFromCache.get()
      job.log(
        "result id=$id startMs=${d.startMs} kind=${d.kind} lead=${d.lead} reason=${d.reason} ver=${LeadInPolicy.VERSION} " +
          "rank=${job.rankWire} decodeMs=avg${source.decodeMsAvg}/max${source.decodeMsMax} frames=${scan.decoded} " +
          "bytesRead=${mb(read)} fromCache=${mb(cached)} netKB=${max(0L, read - cached) / 1024} leadBytes=${leadBytes ?: 0} " +
          "preroll=${d.prerollMs}ms audio=${info.audio} audioOnsetMs=${d.audioOnsetMs ?: "none"} " +
          "cardQuietPct=${d.cardQuietPct ?: "none"} firstContentMs=${d.firstContentMs ?: "none"} wallMs=${control.wallMs}" +
          if (d.unknown) " unknown=1" else ""
      )
      if (d.wouldCutMs != null) job.log("would-cut id=$id startMs=${d.wouldCutMs} kind=${d.kind} reason=${d.reason}")
      return LeadInOutcome(job, decision = d, leadBytes = leadBytes)
    } catch (e: LeadInSkip) {
      job.log("skip id=$id reason=${e.reason}")
      return LeadInOutcome(job, skipReason = e.reason)
    } catch (e: LeadInAbort) {
      return LeadInOutcome(job, abortReason = e.reason)
    } catch (e: InterruptedIOException) {
      return LeadInOutcome(job, abortReason = control.cancelReason ?: "io")
    } catch (e: Exception) {
      // Never the message: a data source's exception can carry the request URI (R11).
      return LeadInOutcome(job, abortReason = control.cancelReason ?: "error:${e.javaClass.simpleName}")
    } finally {
      try {
        source.close()
      } catch (_: Exception) {
      }
    }
  }

  private fun mb(bytes: Long): String = "%.1fMB".format(bytes / (1024.0 * 1024.0))
}

/**
 * V2-23: the detector's software decoders, one per MIME, reused across clips (`stop()` then
 * `configure()`). Touched on the detector's thread only.
 */
@OptIn(UnstableApi::class)
internal class DetectorCodecs {
  private val byMime = HashMap<String, MediaCodec>()

  /** The first software-only decoder for [mime] (media3's `softwareOnly`), or null. */
  fun softwareName(mime: String): String? = try {
    MediaCodecUtil.getDecoderInfos(mime, false, false).firstOrNull { it.softwareOnly }?.name
  } catch (_: Exception) {
    null
  }

  fun obtain(mime: String, name: String): MediaCodec = byMime[mime]?.takeIf { it.name == name } ?: run {
    byMime.remove(mime)?.release()
    MediaCodec.createByCodecName(name).also {
      byMime[mime] = it
      PlayerCoreCounts.onDetectorCodecCreated()
    }
  }

  /** Back to Uninitialized for the next clip; a codec that won't stop is let go. */
  fun park(mime: String) {
    val codec = byMime[mime] ?: return
    try {
      codec.stop()
    } catch (_: Exception) {
      broken(mime)
    }
  }

  fun broken(mime: String) {
    byMime.remove(mime)?.let {
      try {
        it.release()
      } catch (_: Exception) {
      }
    }
  }

  fun releaseAll() {
    for (mime in byMime.keys.toList()) broken(mime)
  }
}

/**
 * V2-23: reads one clip through [MediaExtractorCompat] (media3-inspector 1.11.0) and decodes video
 * on a software MediaCodec in buffer mode (§3.2), audio (AAC) on another into 100 ms RMS levels.
 * [dataSourceFactory] is the clip core's cache path with the clip's key ([KeyedDataSourceFactory]).
 */
@OptIn(UnstableApi::class)
internal class MediaFrameSource(
  private val uri: Uri,
  dataSourceFactory: DataSource.Factory,
  private val codecs: DetectorCodecs,
  private val control: LeadInControl,
  private val position: () -> Long
) : FrameSource {
  private val extractor = MediaExtractorCompat(DefaultExtractorsFactory(), dataSourceFactory)
  private var videoTrack = -1
  private var audioTrack = -1
  private var videoMime: String? = null
  private var audioMime: String? = null
  private var video: MediaCodec? = null
  private var audio: MediaCodec? = null
  private lateinit var videoFormat: MediaFormat
  private var started = false
  private var currentUs = 0L
  private var sawOutputFormat = false
  private var needCsd = false
  override var fullRange = false
    private set
  private val bufferInfo = MediaCodec.BufferInfo()
  private val positions = ArrayList<Pair<Long, Long>>()

  // Audio levels.
  private var audioFedUntilUs = Long.MIN_VALUE
  private var audioDropped = 0
  private var audioChannels = 2
  private var audioRate = 48_000
  private var audioFloat = false
  private val sumSquares = HashMap<Int, Double>()
  private val counts = HashMap<Int, Long>()

  // Decode timing.
  private var decodeTotalMs = 0L
  private var decodeFrames = 0
  private var decodeMax = 0L

  override var codecName: String = "none"
    private set

  override val decodeMsAvg: Long get() = if (decodeFrames == 0) 0 else decodeTotalMs / decodeFrames
  override val decodeMsMax: Long get() = decodeMax

  override fun bytePositionAt(timeUs: Long): Long? = positions.firstOrNull { it.first >= timeUs }?.second

  override fun open(): TrackInfo {
    extractor.setDataSource(uri, 0)
    if (extractor.drmInitData != null) throw LeadInSkip("encrypted")
    var vf: MediaFormat? = null
    var af: MediaFormat? = null
    for (i in 0 until extractor.trackCount) {
      val f = extractor.getTrackFormat(i)
      val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
      if (videoTrack < 0 && mime.startsWith("video/")) {
        videoTrack = i
        vf = f
      } else if (audioTrack < 0 && mime == MimeTypes.AUDIO_AAC) {
        audioTrack = i
        af = f
      }
    }
    val format = vf ?: throw LeadInSkip("codec")
    val mime = format.getString(MediaFormat.KEY_MIME)!!
    if (mime == MimeTypes.VIDEO_DOLBY_VISION) throw LeadInSkip("dv")
    if (mime != MimeTypes.VIDEO_H264 && mime != MimeTypes.VIDEO_H265) throw LeadInSkip("codec")
    if (format.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
      val transfer = format.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
      if (transfer == MediaFormat.COLOR_TRANSFER_ST2084 || transfer == MediaFormat.COLOR_TRANSFER_HLG) throw LeadInSkip("hdr")
    }
    if (format.containsKey(MediaFormat.KEY_PROFILE) && isTenBit(mime, format.getInteger(MediaFormat.KEY_PROFILE))) throw LeadInSkip("10bit")
    val name = codecs.softwareName(mime) ?: throw LeadInSkip("nosw")
    codecName = name
    videoMime = mime
    videoFormat = format
    extractor.selectTrack(videoTrack)
    format.setInteger(MediaFormat.KEY_COLOR_FORMAT, CodecCapabilities.COLOR_FormatYUV420Flexible)
    format.setInteger(MediaFormat.KEY_PRIORITY, 1)
    val codec = codecs.obtain(mime, name)
    try {
      codec.configure(format, null, null, 0)
      codec.start()
    } catch (e: Exception) {
      codecs.broken(mime)
      throw LeadInAbort("decoder")
    }
    video = codec
    var audioLabel = "none"
    if (af != null) {
      val aname = codecs.softwareName(MimeTypes.AUDIO_AAC)
      if (aname != null) {
        extractor.selectTrack(audioTrack)
        val ac = codecs.obtain(MimeTypes.AUDIO_AAC, aname)
        try {
          ac.configure(af, null, null, 0)
          ac.start()
          audio = ac
          audioMime = MimeTypes.AUDIO_AAC
          audioChannels = af.getIntOr(MediaFormat.KEY_CHANNEL_COUNT, 2)
          audioRate = af.getIntOr(MediaFormat.KEY_SAMPLE_RATE, 48_000)
          audioLabel = "aac"
        } catch (_: Exception) {
          codecs.broken(MimeTypes.AUDIO_AAC)
          extractor.unselectTrack(audioTrack)
          audioTrack = -1
        }
      } else {
        audioTrack = -1
      }
    }
    val width = format.getIntOr(MediaFormat.KEY_WIDTH, 0)
    val height = format.getIntOr(MediaFormat.KEY_HEIGHT, 0)
    val fps = frameRate(format)
    val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else -1L
    return TrackInfo(
      width = width,
      height = height,
      durationUs = durationUs,
      frameDurationUs = if (fps > 0f) (1_000_000 / fps).toLong() else 41_708L,
      fullRange = false,
      fps = fps,
      audio = audioLabel
    )
  }

  override fun next(): VideoSample? {
    while (true) {
      control.check()
      if (started) {
        if (!extractor.advance()) return null
      } else {
        started = true
      }
      val track = extractor.sampleTrackIndex
      if (track < 0) return null
      val t = extractor.sampleTime
      if (track == audioTrack) {
        feedAudio(t)
        continue
      }
      if (track != videoTrack) continue
      val size = extractor.sampleSize.toInt()
      val key = (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0
      currentUs = t
      positions += t to position()
      return VideoSample(t, size, key)
    }
  }

  override fun decode(endOfRun: Boolean): List<ScoredFrame> {
    val codec = video ?: throw LeadInAbort("decoder")
    control.pace()
    val from = System.nanoTime()
    val out = ArrayList<ScoredFrame>()
    try {
      if (needCsd) queueCsd(codec, out)
      val idx = dequeueInput(codec, out)
      val buf = codec.getInputBuffer(idx) ?: throw LeadInAbort("decoder")
      buf.clear()
      val n = extractor.readSampleData(buf, 0).coerceAtLeast(0)
      codec.queueInputBuffer(idx, 0, n, currentUs, 0)
      drainVideo(codec, out, untilEos = false)
      if (endOfRun) endRun(codec, out)
    } catch (e: LeadInAbort) {
      throw e
    } catch (e: IllegalStateException) {
      videoMime?.let(codecs::broken)
      video = null
      throw LeadInAbort("decoder")
    }
    val ms = (System.nanoTime() - from) / 1_000_000
    if (out.isNotEmpty()) {
      decodeTotalMs += ms
      decodeFrames += out.size
      decodeMax = max(decodeMax, ms / out.size)
    }
    return out
  }

  override fun drain(): List<ScoredFrame> {
    val codec = video ?: return emptyList()
    val out = ArrayList<ScoredFrame>()
    endRun(codec, out)
    return out
  }

  private fun endRun(codec: MediaCodec, out: MutableList<ScoredFrame>) {
    val idx = dequeueInput(codec, out)
    codec.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
    drainVideo(codec, out, untilEos = true)
    // EOS out, then flush (MediaCodec docs: wait for EOS before flush). Before the first output
    // format the codec-specific data may be lost on a flush: re-queue it next time.
    codec.flush()
    if (!sawOutputFormat) needCsd = true
  }

  override fun seekTo(timeUs: Long) {
    extractor.seekTo(timeUs, MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
    started = false
  }

  override fun audio(): AudioLevels? {
    val codec = audio ?: return null
    try {
      drainAudio(codec)
    } catch (_: Exception) {
      return null
    }
    // A dropped sample would read as silence: unmeasured rather than wrong.
    if (audioDropped > 0 || counts.isEmpty()) return null
    val last = counts.keys.max()
    return AudioLevels(DoubleArray(last + 1) { w -> LeadInPolicy.dbfs(sumSquares[w] ?: 0.0, counts[w] ?: 0L) })
  }

  override fun close() {
    try {
      extractor.release()
    } catch (_: Exception) {
    }
    videoMime?.let { if (video != null) codecs.park(it) }
    audioMime?.let { if (audio != null) codecs.park(it) }
    video = null
    audio = null
  }

  private fun dequeueInput(codec: MediaCodec, out: MutableList<ScoredFrame>): Int {
    repeat(DEQUEUE_TRIES) {
      val idx = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
      if (idx >= 0) return idx
      drainVideo(codec, out, untilEos = false)
      control.check()
    }
    throw LeadInAbort("decoder")
  }

  private fun queueCsd(codec: MediaCodec, out: MutableList<ScoredFrame>) {
    for (name in listOf("csd-0", "csd-1", "csd-2")) {
      if (!videoFormat.containsKey(name)) continue
      val csd = videoFormat.getByteBuffer(name)?.duplicate() ?: continue
      csd.rewind()
      val idx = dequeueInput(codec, out)
      val buf = codec.getInputBuffer(idx) ?: throw LeadInAbort("decoder")
      buf.clear()
      val size = csd.remaining()
      buf.put(csd)
      codec.queueInputBuffer(idx, 0, size, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
    }
    needCsd = false
  }

  private fun drainVideo(codec: MediaCodec, out: MutableList<ScoredFrame>, untilEos: Boolean) {
    var tries = 0
    while (true) {
      val idx = codec.dequeueOutputBuffer(bufferInfo, if (untilEos) DEQUEUE_TIMEOUT_US else 0L)
      when {
        idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
          sawOutputFormat = true
          val f = codec.outputFormat
          fullRange = f.containsKey(MediaFormat.KEY_COLOR_RANGE) && f.getInteger(MediaFormat.KEY_COLOR_RANGE) == MediaFormat.COLOR_RANGE_FULL
        }
        idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
          if (!untilEos) return
          control.check()
          if (++tries > DEQUEUE_TRIES) throw LeadInAbort("decoder")
        }
        idx >= 0 -> {
          sawOutputFormat = true
          val eos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
          if (bufferInfo.size > 0) {
            val image = codec.getOutputImage(idx)
            if (image != null) {
              try {
                out += ScoredFrame(bufferInfo.presentationTimeUs, score(image))
              } finally {
                image.close()
              }
            }
          }
          codec.releaseOutputBuffer(idx, false)
          if (eos) return
        }
      }
    }
  }

  private fun score(image: Image): FrameStats {
    if (image.format != ImageFormat.YUV_420_888) throw LeadInAbort("format")
    val crop = image.cropRect
    val planes = image.planes
    val yp = planes[0]
    val up = planes[1]
    val vp = planes[2]
    val cx = crop.left / 2
    val cy = crop.top / 2
    return FrameStats.of(
      width = crop.width(),
      height = crop.height(),
      fullRange = fullRange,
      y = LeadInPolicy.plane(yp.buffer, yp.rowStride, yp.pixelStride, crop.left, crop.top),
      u = LeadInPolicy.plane(up.buffer, up.rowStride, up.pixelStride, cx, cy),
      v = LeadInPolicy.plane(vp.buffer, vp.rowStride, vp.pixelStride, cx, cy)
    )
  }

  private fun feedAudio(timeUs: Long) {
    val codec = audio ?: return
    if (timeUs <= audioFedUntilUs || timeUs > LeadInBudget().maxReadUs) return
    try {
      var idx = codec.dequeueInputBuffer(0)
      if (idx < 0) {
        drainAudio(codec)
        idx = codec.dequeueInputBuffer(AUDIO_TIMEOUT_US)
      }
      if (idx < 0) {
        audioDropped++
        return
      }
      val buf = codec.getInputBuffer(idx) ?: return
      buf.clear()
      val n = extractor.readSampleData(buf, 0).coerceAtLeast(0)
      codec.queueInputBuffer(idx, 0, n, timeUs, 0)
      audioFedUntilUs = timeUs
      drainAudio(codec)
    } catch (_: IllegalStateException) {
      audioDropped++
    }
  }

  private fun drainAudio(codec: MediaCodec) {
    while (true) {
      val idx = codec.dequeueOutputBuffer(bufferInfo, 0)
      when {
        idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
          val f = codec.outputFormat
          audioChannels = f.getIntOr(MediaFormat.KEY_CHANNEL_COUNT, audioChannels).coerceAtLeast(1)
          audioRate = f.getIntOr(MediaFormat.KEY_SAMPLE_RATE, audioRate).coerceAtLeast(1)
          audioFloat = f.getIntOr(MediaFormat.KEY_PCM_ENCODING, android.media.AudioFormat.ENCODING_PCM_16BIT) == android.media.AudioFormat.ENCODING_PCM_FLOAT
        }
        idx >= 0 -> {
          val buf = codec.getOutputBuffer(idx)
          if (buf != null && bufferInfo.size > 0) {
            buf.position(bufferInfo.offset)
            buf.limit(bufferInfo.offset + bufferInfo.size)
            val ordered = buf.slice().order(java.nio.ByteOrder.nativeOrder())
            val bytesPer = if (audioFloat) 4 else 2
            val frames = bufferInfo.size / (bytesPer * audioChannels)
            for (f in 0 until frames) {
              val tUs = bufferInfo.presentationTimeUs + f * 1_000_000L / audioRate
              val w = (tUs / LeadInPolicy.AUDIO_WINDOW_US).toInt()
              if (w < 0) continue
              var sq = 0.0
              for (c in 0 until audioChannels) {
                val at = (f * audioChannels + c) * bytesPer
                val s = if (audioFloat) ordered.getFloat(at) * 32768.0 else ordered.getShort(at).toDouble()
                sq += s * s
              }
              sumSquares[w] = (sumSquares[w] ?: 0.0) + sq
              counts[w] = (counts[w] ?: 0L) + audioChannels
            }
          }
          codec.releaseOutputBuffer(idx, false)
        }
        else -> return
      }
    }
  }

  private fun isTenBit(mime: String, profile: Int): Boolean = when (mime) {
    MimeTypes.VIDEO_H265 -> profile == CodecProfileLevel.HEVCProfileMain10 ||
      profile == CodecProfileLevel.HEVCProfileMain10HDR10 ||
      profile == CodecProfileLevel.HEVCProfileMain10HDR10Plus
    MimeTypes.VIDEO_H264 -> profile == CodecProfileLevel.AVCProfileHigh10 ||
      profile == CodecProfileLevel.AVCProfileHigh422 ||
      profile == CodecProfileLevel.AVCProfileHigh444
    else -> false
  }

  private fun frameRate(f: MediaFormat): Float {
    if (!f.containsKey(MediaFormat.KEY_FRAME_RATE)) return 0f
    return try {
      f.getFloat(MediaFormat.KEY_FRAME_RATE)
    } catch (_: ClassCastException) {
      f.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
    }
  }

  private fun MediaFormat.getIntOr(key: String, fallback: Int): Int = if (containsKey(key)) getInteger(key) else fallback

  companion object {
    const val DEQUEUE_TIMEOUT_US = 10_000L
    const val DEQUEUE_TRIES = 200
    const val AUDIO_TIMEOUT_US = 5_000L
  }
}
