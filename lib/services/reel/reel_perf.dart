import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessInfo;
import 'dart:math' as math;
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter/scheduler.dart';

import '../../utils/app_logger.dart';
import 'feed_players.dart';

/// What started a card change, for the `[ReelPerf]` line's first field.
enum ReelPerfTrigger {
  /// TV: D-pad up / down (KeyDownEvent in the screen's key handler).
  key,

  /// TV: D-pad left / right; phone: the first card of a newly picked deck.
  deck,

  /// Phone: a page change in the feed.
  swipe,

  /// TV: a step sent from the Fold's On TV mode.
  remote,

  /// The Reel opened or came back (no input to measure from).
  open,

  /// Phone: the window changed size under the card on screen (the Fold
  /// moved between its screens, or turned), timed to the picture moving
  /// again (V2-65).
  fold,
}

/// One card change, from its trigger to the first frame on screen. The
/// splits are consecutive: [resolveMs] runs from the trigger until the clip
/// is asked to open (card metadata and the clip ladder), [openMs] until the
/// open call returns, [decoderMs] until the native decoder reported ready
/// (TV, only when the player's debug log is forwarded), and [renderMs] the
/// rest, to the first frame. Counts and timings only: no titles, no URLs.
///
/// A change that ended without a first frame carries its [end]: the clip
/// failed (`failed:open`, `failed:start`, `failed:play`), the viewer moved
/// on first (`left`), or the card had no clip to play (`noclip`). Its
/// [totalMs] then runs to that end, and it is left out of the medians.
@immutable
class ReelPerfSample {
  const ReelPerfSample({
    required this.trigger,
    required this.totalMs,
    this.origin,
    this.resolveMs,
    this.openMs,
    this.decoderMs,
    this.renderMs,
    this.preloaded,
    this.frames = 0,
    this.framesOver = 0,
    this.worstFrameMs = 0,
    this.rssMb,
    this.imageMb,
    this.decoders,
    this.end,
    required this.at,
  });

  final ReelPerfTrigger trigger;
  final int totalMs;
  final String? origin;
  final int? resolveMs;
  final int? openMs;
  final int? decoderMs;
  final int? renderMs;

  /// The clip opened from a preload (TV) or a parked player (phone).
  final bool? preloaded;

  /// Frames drawn during the change, how many went over the frame budget,
  /// and the worst build + raster time among them.
  final int frames;
  final int framesOver;
  final double worstFrameMs;

  final int? rssMb;
  final double? imageMb;
  final int? decoders;

  /// How a change with no first frame ended; null for one that showed it.
  final String? end;
  final DateTime at;

  /// The logcat line: `[ReelPerf] key=182ms resolve=12 open=40 …`.
  String logLine() {
    final b = StringBuffer('[ReelPerf] ${trigger.name}=${totalMs}ms');
    void add(String k, Object? v) {
      if (v != null) b.write(' $k=$v');
    }

    add('resolve', resolveMs);
    add('open', openMs);
    add('decoder', decoderMs);
    add('render', renderMs);
    add('preload', preloaded == null ? null : (preloaded! ? 'hit' : 'miss'));
    add('origin', origin);
    add('end', end);
    b.write(' frames=$frames over=$framesOver worst=${worstFrameMs.toStringAsFixed(1)}ms');
    add('decoders', decoders);
    add('rss', rssMb == null ? null : '${rssMb}MB');
    add('img', imageMb == null ? null : '${imageMb!.toStringAsFixed(1)}MB');
    return b.toString();
  }

  Map<String, Object?> toJson() => {
    'at': at.millisecondsSinceEpoch,
    't': trigger.name,
    'ms': totalMs,
    'resolve': ?resolveMs,
    'open': ?openMs,
    'decoder': ?decoderMs,
    'render': ?renderMs,
    'preload': ?preloaded,
    'origin': ?origin,
    'end': ?end,
    'frames': frames,
    'over': framesOver,
    'worst': double.parse(worstFrameMs.toStringAsFixed(1)),
    'decoders': ?decoders,
    'rss': ?rssMb,
    'img': ?(imageMb == null ? null : double.parse(imageMb!.toStringAsFixed(1))),
  };
}

/// Where the ring lives: the Reel's own cache table on this device
/// (`ReelStore.cached` / `ReelStore.cache`), handed in by the screen so this
/// file stays on the clip playback path's short import list.
typedef ReelPerfRingStore = ({
  Future<String?> Function(String key) read,
  Future<void> Function(String key, String value) write,
});

/// A card change still waiting for its first frame.
class _Pending {
  _Pending(this.trigger, this.t0);

  final ReelPerfTrigger trigger;
  final Duration t0;
  Duration? resolved;
  Duration? opened;
  Duration? decoder;
  bool? preloaded;
  String? origin;
  int frames = 0;
  int over = 0;
  double worst = 0;
}

/// The Reel's measuring tape (plan V2-07): times every card change from the
/// key press or swipe to its first frame, counts frames over budget, and
/// writes one `[ReelPerf]` logcat line per card plus a [ringSize]-entry ring
/// in the Reel's cache table (`perf:000` … `perf:199`, with `perf:seq` the
/// next sequence number), so an evening's numbers survive the logcat buffer.
///
/// Off unless [recording] is set: the screen sets it under `kDebugMode` or
/// the hidden developer setting, so the default release state measures and
/// writes nothing.
class ReelPerf extends ChangeNotifier {
  ReelPerf({Duration Function()? now, DateTime Function()? clock})
    : _now = now ?? _monotonic,
      _clock = clock ?? DateTime.now;

  static final ReelPerf instance = ReelPerf();

  static final Stopwatch _since = Stopwatch()..start();
  static Duration _monotonic() => _since.elapsed;

  static const int ringSize = 200;
  static const String ringPrefix = 'perf:';
  static const String ringSeqKey = 'perf:seq';

  /// A pending change older than this is from another visit, not a press.
  static const Duration stale = Duration(seconds: 30);

  /// How many samples and frame costs the overlay's medians look back over.
  static const int keep = 200;
  static const int keepFrames = 600;

  final Duration Function() _now;
  final DateTime Function() _clock;

  bool _recording = false;

  /// Measuring at all (logcat line, ring, frame counts).
  bool get recording => _recording;
  set recording(bool on) {
    if (on == _recording) return;
    _recording = on;
    if (!on) {
      _pending = null;
      _setFrames(false);
    } else if (_framesWanted) {
      _setFrames(true);
    }
    notifyListeners();
  }

  /// The overlay is showing (the hidden developer setting).
  final ValueNotifier<bool> overlay = ValueNotifier(false);

  /// The ring's store; null keeps samples in memory only.
  ReelPerfRingStore? ring;

  /// Decoders held now (TV: the clip core; phone: players with a picture).
  int Function()? liveDecoders;

  _Pending? _pending;

  /// Counts [begin]s, so a caller can end only the change it began.
  int _changes = 0;
  final List<ReelPerfSample> _samples = [];

  List<ReelPerfSample> get samples => List.unmodifiable(_samples);
  ReelPerfSample? get last => _samples.isEmpty ? null : _samples.last;

  // ---- card changes ----

  /// A key press, swipe or deck change: the clock starts. An unfinished
  /// change is dropped (the viewer moved on before its first frame) unless
  /// its caller ends it first ([markEnded]). Returns the change's number,
  /// or null when not recording.
  int? begin(ReelPerfTrigger trigger) {
    if (!_recording) return null;
    _pending = _Pending(trigger, _now());
    return ++_changes;
  }

  /// The change numbered [change] ([begin]) ended with no first frame: it
  /// is recorded with how it ended ([ReelPerfSample.end]). Nothing happens
  /// if another change has begun since, or this one already ended.
  void markEnded(String end, {required int? change}) {
    final p = _pending;
    if (!_recording || p == null || change == null || change != _changes) return;
    _pending = null;
    _record(p, _now() - p.t0, end: end);
  }

  _Pending? _live({bool start = false}) {
    if (!_recording) return null;
    final p = _pending;
    if (p != null && _now() - p.t0 <= stale) return p;
    if (!start) {
      _pending = null;
      return null;
    }
    return _pending = _Pending(ReelPerfTrigger.open, _now());
  }

  /// The clip is about to open: the card's metadata and clip are known.
  /// With no press pending this is an open of the Reel itself.
  void markResolved({bool? preloaded, String? origin}) {
    final p = _live(start: true);
    if (p == null) return;
    p.resolved ??= _now() - p.t0;
    if (preloaded != null) p.preloaded ??= preloaded;
    if (origin != null) p.origin = origin;
  }

  /// The open call returned (TV) or the player has a picture (phone).
  void markOpened() {
    final p = _live();
    if (p == null) return;
    p.opened ??= _now() - p.t0;
  }

  /// TV: `onVideoDecoderInitialized`, through the player's forwarded log.
  void markDecoder() {
    final p = _live();
    if (p == null) return;
    p.decoder ??= _now() - p.t0;
  }

  /// The native player's own word on the preload (`Open clip: preloaded=`)
  /// outranks the Dart-side guess.
  void markPreloaded(bool preloaded) {
    final p = _live();
    if (p != null) p.preloaded = preloaded;
  }

  /// The tab went away, the core was released or the card has no clip.
  void cancel() => _pending = null;

  /// The first frame is on screen: the change is recorded.
  void markFirstFrame() {
    final p = _live();
    if (p == null) return;
    _pending = null;
    _record(p, _now() - p.t0);
  }

  /// Records [p], which ran for [elapsed]: to its first frame, or to how it
  /// [end]ed without one (no render split then).
  void _record(_Pending p, Duration elapsed, {String? end}) {
    int? ms(Duration? d) => d?.inMilliseconds;
    int? span(Duration? to, Duration? from) => to == null ? null : (to - (from ?? Duration.zero)).inMilliseconds;
    final opened = p.opened, decoder = p.decoder;
    final sample = ReelPerfSample(
      trigger: p.trigger,
      totalMs: elapsed.inMilliseconds,
      origin: p.origin,
      resolveMs: ms(p.resolved),
      openMs: span(opened, p.resolved),
      decoderMs: decoder == null ? null : span(decoder, opened ?? p.resolved),
      renderMs: end != null ? null : span(elapsed, decoder ?? opened ?? p.resolved),
      preloaded: p.preloaded,
      frames: p.frames,
      framesOver: p.over,
      worstFrameMs: p.worst,
      rssMb: rssMb(),
      imageMb: imageMb(),
      decoders: liveDecoders?.call(),
      end: end,
      at: _clock(),
    );
    _samples.add(sample);
    if (_samples.length > keep) _samples.removeAt(0);
    appLogger.i(sample.logLine());
    _toRing(sample);
    notifyListeners();
  }

  // ---- medians ----

  /// The median of [pick] over the samples of [trigger] (all but opens when
  /// null), or null with none. Changes that ended with no first frame are
  /// left out.
  int? p50(int? Function(ReelPerfSample s) pick, {ReelPerfTrigger? trigger}) {
    final xs = <int>[
      for (final s in _samples)
        if (s.end == null && (trigger == null ? s.trigger != ReelPerfTrigger.open : s.trigger == trigger)) ?pick(s),
    ]..sort();
    if (xs.isEmpty) return null;
    return xs[(xs.length - 1) ~/ 2];
  }

  /// Share of changes that opened preloaded (opens of the Reel left out).
  ({int hits, int of})? get preloadHits {
    var hits = 0, of = 0;
    for (final s in _samples) {
      if (s.trigger == ReelPerfTrigger.open || s.preloaded == null || s.end != null) continue;
      of++;
      if (s.preloaded!) hits++;
    }
    return of == 0 ? null : (hits: hits, of: of);
  }

  // ---- frames ----

  bool _framesWanted = false;
  bool _framesOn = false;
  Duration _budget = const Duration(microseconds: 16667);
  int frames = 0;
  int framesOver = 0;
  int framesDropped = 0;
  final List<double> _frameMs = [];

  /// The frame budget: one refresh of the display the Reel is on.
  Duration get frameBudget => _budget;

  /// The Reel is showing: count frames (when recording).
  void attachFrames() {
    _framesWanted = true;
    if (_recording) _setFrames(true);
  }

  void detachFrames() {
    _framesWanted = false;
    _setFrames(false);
  }

  void _setFrames(bool on) {
    if (on == _framesOn) return;
    _framesOn = on;
    if (on) {
      _budget = budgetFor(_refreshRate());
      SchedulerBinding.instance.addTimingsCallback(onFrames);
    } else {
      SchedulerBinding.instance.removeTimingsCallback(onFrames);
    }
  }

  static double _refreshRate() {
    try {
      final views = PlatformDispatcher.instance.views;
      return views.isEmpty ? 60 : views.first.display.refreshRate;
    } catch (_) {
      return 60;
    }
  }

  /// One vsync at [refreshRate] Hz (60 when the display reports none).
  static Duration budgetFor(double refreshRate) {
    final hz = refreshRate.isFinite && refreshRate >= 20 ? refreshRate : 60;
    return Duration(microseconds: (1e6 / hz).round());
  }

  /// Frames over budget: build + raster past one vsync (the §6 figure).
  /// Dropped: vsyncs missed, estimated from the slower of the UI and raster
  /// threads. They run pipelined, so a long total span is latency, not a
  /// missed vsync (see [SchedulerBinding.addTimingsCallback]).
  ///
  /// The overlay reads these on its own 1 s tick: notifying here would
  /// rebuild it per batch, and each rebuild is a frame of its own.
  @visibleForTesting
  void onFrames(List<FrameTiming> timings, {Duration? budget}) {
    final b = (budget ?? _budget).inMicroseconds;
    for (final t in timings) {
      final cost = t.buildDuration.inMicroseconds + t.rasterDuration.inMicroseconds;
      final costMs = cost / 1000;
      final over = cost > b;
      frames++;
      if (over) framesOver++;
      final slowest = math.max(t.buildDuration.inMicroseconds, t.rasterDuration.inMicroseconds);
      framesDropped += math.max(0, (slowest / b).ceil() - 1);
      _frameMs.add(costMs);
      if (_frameMs.length > keepFrames) _frameMs.removeAt(0);
      final p = _pending;
      if (p != null) {
        p.frames++;
        if (over) p.over++;
        if (costMs > p.worst) p.worst = costMs;
      }
    }
  }

  /// The 95th percentile build + raster time of the recent frames.
  double? get frameP95 {
    if (_frameMs.isEmpty) return null;
    final xs = [..._frameMs]..sort();
    return xs[math.min(xs.length - 1, (xs.length * 0.95).floor())];
  }

  void resetFrames() {
    frames = framesOver = framesDropped = 0;
    _frameMs.clear();
    notifyListeners();
  }

  // ---- gauges ----

  static int? rssMb() {
    try {
      return ProcessInfo.currentRss ~/ (1024 * 1024);
    } catch (_) {
      return null;
    }
  }

  static double? imageMb() {
    try {
      return PaintingBinding.instance.imageCache.currentSizeBytes / (1024 * 1024);
    } catch (_) {
      return null;
    }
  }

  // ---- ring ----

  int? _seq;
  Future<void> _ringWrites = Future.value();

  void _toRing(ReelPerfSample s) {
    final store = ring;
    if (store == null) return;
    _ringWrites = _ringWrites
        .then((_) async {
          final seq = _seq ??= int.tryParse(await store.read(ringSeqKey) ?? '') ?? 0;
          _seq = seq + 1;
          await store.write(ringKey(seq), jsonEncode({'seq': seq, ...s.toJson()}));
          await store.write(ringSeqKey, '${seq + 1}');
        })
        .catchError((Object e) => appLogger.d('Reel: perf ring write failed', error: e));
  }

  /// The ring slot for sequence number [seq].
  static String ringKey(int seq) => '$ringPrefix${(seq % ringSize).toString().padLeft(3, '0')}';

  /// Waits for queued ring writes (tests).
  @visibleForTesting
  Future<void> get flushed => _ringWrites;

  @override
  void dispose() {
    _setFrames(false);
    overlay.dispose();
    super.dispose();
  }
}

/// The phone feed's half of the measuring tape. `video_player` has no
/// first-frame event, so the first frame here is the first position tick
/// past where the card's player stood (polled every 100 ms by the plugin):
/// the figure can run up to 100 ms long.
///
/// Every change of the card on screen writes one line, either way through
/// the feed: at its first frame, or, with no first frame, when its clip
/// fails (`end=failed:<stage>`), when the next change begins first
/// (`end=left`, or `end=noclip` for a card that never had a clip to play),
/// or when the feed moves onto a page with no card. Letting everything go
/// (another tab, Watch) drops an unfinished change, as before.
class ReelFeedProbe {
  ReelFeedProbe(this.players, this.perf, {this.deckId, this.origin}) {
    players.addListener(_onPlayers);
  }

  final ReelFeedPlayers players;
  final ReelPerf perf;

  /// The controller's deck now: a page change into a new deck is a deck
  /// switch, not a swipe.
  final String? Function()? deckId;

  /// The current card's clip origin (`plexExtra` / `animeTheme`).
  final String? Function()? origin;

  String? _card;
  String? _deck;
  bool _seen = false;
  bool _resolved = false;
  bool _done = false;
  FeedVideo? _video;
  Duration _from = Duration.zero;

  /// The change this probe began and hasn't ended ([ReelPerf.begin]).
  int? _change;

  void _onPlayers() {
    final cur = players.current;
    if (cur != _card) {
      _detach();
      _card = cur;
      if (cur == null) {
        if (players.letGo) {
          // Released (tab hidden, Watch): the next card is an open again.
          _seen = false;
          _change = null;
          perf.cancel();
        } else {
          // A page with no card (Tonight's picks, the deck's end): the card
          // left is recorded as left.
          _end();
        }
        return;
      }
      _end();
      final deck = deckId?.call();
      final trigger = !_seen ? ReelPerfTrigger.open : (deck != _deck ? ReelPerfTrigger.deck : ReelPerfTrigger.swipe);
      _seen = true;
      _deck = deck;
      _resolved = false;
      _done = false;
      _change = perf.begin(trigger);
    }
    if (cur == null || _done) return;
    if (players.failure(cur) case final stage?) {
      _finish('failed:${stage.name}');
      return;
    }
    if (!_resolved && players.held.contains(cur)) {
      _resolved = true;
      perf.markResolved(preloaded: players.videoFor(cur) != null, origin: origin?.call());
    }
    final v = players.videoFor(cur);
    if (v != null && _video == null) _attach(v);
  }

  /// The change still waiting for its first frame ends here: the viewer
  /// moved on from a card with a clip, or from one that never had one.
  void _end() {
    if (_done || _change == null) return;
    _finish(_resolved ? 'left' : 'noclip');
  }

  void _finish(String end) {
    _done = true;
    _detach();
    perf.markEnded(end, change: _change);
    _change = null;
  }

  /// The window changed size (V2-65): the card on screen is the same, so
  /// this is timed from the change to its picture moving again, the "same
  /// card, picture back" figure. An unfinished swipe is replaced: mid-swipe
  /// the card under the thumb is the one timed.
  void screenChanged() {
    final cur = players.current;
    if (cur == null) return;
    _detach();
    _card = cur;
    _done = false;
    _resolved = true;
    _change = perf.begin(ReelPerfTrigger.fold);
    final v = players.videoFor(cur);
    perf.markResolved(preloaded: v != null, origin: origin?.call());
    // Not open yet: [_onPlayers] takes it when it has a picture.
    if (v != null) _attach(v);
  }

  void _attach(FeedVideo v) {
    perf.markOpened();
    _video = v;
    _from = v.position;
    v.addListener(_onVideo);
  }

  void _onVideo() {
    final v = _video;
    if (v == null) return;
    if (v.playing && v.position > Duration.zero && v.position != _from) {
      _done = true;
      _change = null;
      _detach();
      perf.markFirstFrame();
    }
  }

  void _detach() {
    _video?.removeListener(_onVideo);
    _video = null;
  }

  void dispose() {
    _detach();
    players.removeListener(_onPlayers);
  }
}
