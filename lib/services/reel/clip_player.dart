import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mpv/models.dart';
import '../../mpv/player/platform/player_android.dart';
import '../../mpv/player/player.dart';
import '../../utils/app_logger.dart';
import 'reel_perf.dart';

/// Where a clip comes from. Clips never carry request headers: the Plex
/// token rides in the PMS URL only, so nothing Plex reaches AnimeThemes.
enum ClipOrigin { plexExtra, animeTheme }

class ClipSource {
  const ClipSource({required this.uri, required this.origin, this.length});

  final String uri;
  final ClipOrigin origin;
  final Duration? length;

  /// Whether the next card may preload this clip (spec §8: a slow guest
  /// server's sources would not be).
  bool get preloadable => true;

  @override
  bool operator ==(Object other) => other is ClipSource && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;
}

/// The few things the Reel asks of a native player. The app's [Player]
/// carries every watch-state side effect only through the video player
/// screen, which the Reel never opens; this interface keeps it that way.
abstract interface class ClipEngine {
  Player get player;
  Future<void> open(String uri);
  Future<void> preload(String uri);
  Future<void> clearPreloads();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setVisible(bool visible);
  Stream<bool> get completed;
  Stream<void> get firstFrame;
  Stream<PlayerError> get errors;

  /// The native player's forwarded log lines (the debug overlay reads the
  /// preload and decoder lines; they arrive only with debug logging on).
  Stream<PlayerLog> get logs;
  Duration get position;

  /// The playhead about four times a second, and the clip's length when it
  /// is known (the TV's progress line, V2-28).
  Stream<Duration> get positions;
  Stream<Duration> get durations;
  Duration get duration;
  Future<void> dispose();
}

/// ExoPlayer in clip mode (Android): one core for the whole Reel session.
class ExoClipEngine implements ClipEngine {
  ExoClipEngine() : _p = PlayerAndroid(clipMode: true);

  final PlayerAndroid _p;

  @override
  Player get player => _p;

  @override
  Future<void> open(String uri) => _p.open(Media(uri), play: true);

  @override
  Future<void> preload(String uri) => _p.preloadClip(uri);

  @override
  Future<void> clearPreloads() => _p.clearPreloads();

  @override
  Future<void> play() => _p.play();

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> seek(Duration position) => _p.seek(position);

  @override
  Future<void> setVolume(double volume) => _p.setVolume(volume);

  @override
  Future<void> setVisible(bool visible) => _p.setVisible(visible);

  @override
  Stream<bool> get completed => _p.streams.completed;

  @override
  Stream<void> get firstFrame => _p.streams.playbackRestart;

  @override
  Stream<PlayerError> get errors => _p.streams.error;

  @override
  Stream<PlayerLog> get logs => _p.streams.log;

  @override
  Duration get position => _p.state.position;

  @override
  Stream<Duration> get positions => _p.streams.position;

  @override
  Stream<Duration> get durations => _p.streams.duration;

  @override
  Duration get duration => _p.state.duration;

  @override
  Future<void> dispose() => _p.dispose();
}

enum ClipPhase { idle, loading, playing, paused, held, failed }

/// How far through the clip on screen is (V2-28): zero until its first
/// frame, the whole length once it holds.
@immutable
class ClipProgress {
  const ClipProgress(this.position, this.length);

  static const ClipProgress zero = ClipProgress(Duration.zero, Duration.zero);

  final Duration position;
  final Duration length;

  /// 0–1, or null while the length is unknown.
  double? get fraction {
    if (length <= Duration.zero) return null;
    return (position.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) => other is ClipProgress && other.position == position && other.length == length;

  @override
  int get hashCode => Object.hash(position, length);
}

/// The Reel's clip player: plays one card's clip, preloads the next, loops a
/// clip twice and then holds on its last frame, and ramps the sound between
/// cards. It never reports a timeline, a scrobble or a media session: it
/// imports none of that code (test/reel/no_reporting_guard_test.dart).
class ClipPlayer {
  ClipPlayer({ClipEngine Function()? engine, this.loops = 2, ReelPerf? perf})
    : _create = engine ?? ExoClipEngine.new,
      _perf = perf ?? ReelPerf.instance;

  /// The outgoing clip's ramp to silence. It runs alongside the next open
  /// rather than before it (V2-01), so a card change never waits on it. One
  /// constant, judged by ear on the soundbar (the item's device check).
  static const Duration outgoingFade = Duration(milliseconds: 120);

  /// A session's first clip rises from silence over this (for the soundbar).
  static const Duration firstFadeIn = Duration(milliseconds: 600);

  /// Later cards rise from at most [dipLevel] over this.
  static const Duration fadeIn = Duration(milliseconds: 300);
  static const double dipLevel = 30;

  /// A key press older than this when a clip opens is from another visit.
  static const Duration staleKey = Duration(seconds: 30);

  final ClipEngine Function() _create;

  /// The debug overlay's tape (it records nothing unless switched on).
  final ReelPerf _perf;

  /// Plays before holding on the last frame.
  final int loops;

  ClipEngine? _engine;
  final List<StreamSubscription<Object?>> _subs = [];
  ClipSource? _current;
  int _played = 0;
  bool _muted = false;

  /// The volume last sent to the core (0–100): every ramp starts here.
  double _level = 0;
  Timer? _fade;
  Completer<void>? _fadeDone;

  /// Bumped by every [play], so a slow open never ramps a later card.
  int _opens = 0;
  Stopwatch? _ttff;
  bool _openPreloaded = false;

  /// The press that asked for the next card ([markKey]), until a clip
  /// opens for it; then the open's, until its first frame.
  ({Stopwatch watch, String trigger})? _key;
  ({Stopwatch watch, String trigger})? _openKey;

  /// The clip last handed to the core's preload, until it is used or cleared.
  String? _preloaded;

  final ValueNotifier<ClipPhase> phase = ValueNotifier(ClipPhase.idle);

  /// The clip whose picture is on screen: null from the top of [play] until
  /// that clip's first frame, so a card never draws over the clip before it.
  final ValueNotifier<ClipSource?> onScreen = ValueNotifier(null);

  /// Time to first frame of the last clip, for the measure-day stopwatch.
  final ValueNotifier<Duration?> lastTtff = ValueNotifier(null);

  /// The TV's progress line (V2-28): the clip on screen only, so the clip
  /// before it never moves the line of the card that is opening.
  final ValueNotifier<ClipProgress> progress = ValueNotifier(ClipProgress.zero);

  /// The current clip's length: its source's, until the core reports one.
  Duration _length = Duration.zero;

  ClipEngine? get engine => _engine;
  ClipSource? get current => _current;
  bool get muted => _muted;

  @visibleForTesting
  double get level => _level;

  ClipEngine _ensure() {
    final existing = _engine;
    if (existing != null) return existing;
    final e = _create();
    _engine = e;
    _subs
      ..add(e.completed.listen((done) => done ? _onCompleted() : null))
      ..add(e.firstFrame.listen((_) => _onFirstFrame()))
      ..add(
        e.errors.listen((err) {
          appLogger.w('Reel: clip error: ${err.message}');
          phase.value = ClipPhase.failed;
        }),
      )
      ..add(e.logs.listen(_onLog))
      ..add(e.positions.listen(_onPosition))
      ..add(
        e.durations.listen((d) {
          if (d <= Duration.zero) return;
          _length = d;
          if (onScreen.value != null) progress.value = ClipProgress(progress.value.position, d);
        }),
      );
    return e;
  }

  /// TV: a D-pad press that asks for another card ([trigger] `step` or
  /// `deck`), timed from the key handler. The next [play] takes it, and that
  /// clip's first frame logs `[ReelTTFF] key=… open=… preloaded=…`. A held
  /// key's repeats each replace it, so `key=` runs from the press that
  /// picked the card the cursor landed on.
  void markKey(Stopwatch since, {String trigger = 'step'}) => _key = (watch: since, trigger: trigger);

  /// Plays [source], opening it at once: the phase moves to loading and
  /// [onScreen] clears before any await, and the outgoing clip ramps to
  /// silence over [outgoingFade] alongside the open instead of before it.
  /// [first] rises from silence over [firstFadeIn] (a session's first clip
  /// on the TV, for the soundbar); later cards rise from [dipLevel] at most
  /// over [fadeIn].
  Future<void> play(ClipSource source, {bool first = false}) async {
    final e = _ensure();
    final open = ++_opens;
    _openPreloaded = _preloaded == source.uri;
    _perf.markResolved(preloaded: _openPreloaded, origin: source.origin.name);
    _preloaded = null;
    final key = _key;
    _key = null;
    _openKey = key != null && key.watch.elapsed < staleKey ? key : null;
    final outgoing = _current != null && !first;
    _current = source;
    _played = 0;
    _length = source.length ?? Duration.zero;
    progress.value = ClipProgress.zero;
    onScreen.value = null;
    phase.value = ClipPhase.loading;
    _ttff = Stopwatch()..start();
    if (_muted || first || !outgoing) {
      _cancelFade();
      _setLevel(0);
    } else {
      unawaited(_fadeTo(0, outgoingFade));
    }
    await e.open(source.uri);
    if (open != _opens || !identical(_engine, e)) return;
    _perf.markOpened();
    if (_muted) return;
    _cancelFade();
    if (_level > dipLevel) _setLevel(dipLevel);
    unawaited(_fadeTo(100, first ? firstFadeIn : fadeIn));
  }

  /// Buffers the next card's opening seconds on the same core.
  Future<void> preload(ClipSource? next) async {
    final e = _ensure();
    if (next == null || !next.preloadable) {
      _preloaded = null;
      await e.clearPreloads();
      return;
    }
    _preloaded = next.uri;
    await e.preload(next.uri);
  }

  /// Memory pressure: drop the buffered next card without building a core.
  Future<void> dropPreload() async {
    _preloaded = null;
    await _engine?.clearPreloads();
  }

  Future<void> pause() async {
    // A press that led to no clip (an AI card, the end of a deck) times
    // nothing.
    _key = null;
    await _engine?.pause();
    if (phase.value == ClipPhase.playing || phase.value == ClipPhase.loading) phase.value = ClipPhase.paused;
  }

  Future<void> resume() async {
    if (phase.value == ClipPhase.held) return replay();
    await _engine?.play();
    if (phase.value == ClipPhase.paused) phase.value = ClipPhase.playing;
  }

  Future<void> togglePause() => phase.value == ClipPhase.playing ? pause() : resume();

  Future<void> replay() async {
    final e = _engine;
    if (e == null || _current == null) return;
    _played = 0;
    await e.seek(Duration.zero);
    await e.play();
    if (onScreen.value != null) progress.value = ClipProgress(Duration.zero, _length);
    phase.value = ClipPhase.playing;
  }

  /// FF / RW: ±10 s within the clip.
  Future<void> seekBy(Duration delta) async {
    final e = _engine;
    if (e == null) return;
    final to = e.position + delta;
    await e.seek(to < Duration.zero ? Duration.zero : to);
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    _cancelFade();
    _setLevel(muted ? 0 : 100);
  }

  /// Hide the native surface while a card is dragged (it can't slide).
  Future<void> setVisible(bool visible) async => _engine?.setVisible(visible);

  /// Releases the core and awaits its dispose, so the real player can open
  /// right after (two decoders never run at once on the 3 GB Shield).
  Future<void> release() async {
    _cancelFade();
    final e = _engine;
    _engine = null;
    _current = null;
    _preloaded = null;
    _key = null;
    _openKey = null;
    _ttff = null;
    _level = 0;
    _length = Duration.zero;
    progress.value = ClipProgress.zero;
    _perf.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    onScreen.value = null;
    phase.value = ClipPhase.idle;
    if (e != null) await e.dispose();
  }

  void _onFirstFrame() {
    final sw = _ttff;
    if (sw != null) {
      sw.stop();
      lastTtff.value = sw.elapsed;
      final key = _openKey;
      final keyMs = key == null ? 'none' : '${key.watch.elapsedMilliseconds}ms';
      appLogger.i(
        '[ReelTTFF] key=$keyMs open=${sw.elapsedMilliseconds}ms preloaded=$_openPreloaded'
        '${key == null ? '' : ' trigger=${key.trigger}'} origin=${_current?.origin.name}',
      );
      _ttff = null;
      _openKey = null;
      _perf.markFirstFrame();
    }
    onScreen.value = _current;
    // The core reports a length only when it changes, so a clip as long as
    // the one before it takes the length the core already holds.
    if (_length <= Duration.zero) _length = _engine?.duration ?? Duration.zero;
    progress.value = ClipProgress(Duration.zero, _length);
    if (phase.value == ClipPhase.loading) phase.value = ClipPhase.playing;
  }

  /// The playhead of the clip on screen; a tick from before its first frame
  /// (the outgoing clip's) is not this clip's.
  void _onPosition(Duration at) {
    if (onScreen.value == null || phase.value == ClipPhase.held) return;
    progress.value = ClipProgress(at, _length);
  }

  /// ExoPlayerCore's `Open clip: preloaded=` and `Decoder initialized:`
  /// lines (forwarded only while the player's debug log is on).
  void _onLog(PlayerLog log) {
    if (log.prefix == 'clip' && log.text.startsWith('Open clip: preloaded=')) {
      _perf.markPreloaded(log.text.endsWith('true'));
    } else if (log.prefix == 'decoder-hang' && log.text.startsWith('Decoder initialized')) {
      _perf.markDecoder();
    }
  }

  void _onCompleted() {
    final e = _engine;
    if (e == null) return;
    _played++;
    if (_played < loops) {
      unawaited(e.seek(Duration.zero).then((_) => e.play()));
    } else {
      // Hold on the last frame; Replay is focused by the view.
      unawaited(e.pause());
      if (onScreen.value != null) progress.value = ClipProgress(_length, _length);
      phase.value = ClipPhase.held;
    }
  }

  void _setLevel(double v) {
    _level = v;
    unawaited(_engine?.setVolume(v));
  }

  /// Stops a ramp where it is. Its future completes, so nothing waiting on
  /// it ever hangs.
  void _cancelFade() {
    _fade?.cancel();
    _fade = null;
    final done = _fadeDone;
    _fadeDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  /// Ramps from the current [_level] to [target] in six steps.
  Future<void> _fadeTo(double target, Duration over) {
    _cancelFade();
    if (_engine == null) return Future.value();
    final start = _level;
    if (start == target || over <= Duration.zero) {
      _setLevel(target);
      return Future.value();
    }
    const steps = 6;
    final done = _fadeDone = Completer<void>();
    var i = 0;
    _fade = Timer.periodic(over ~/ steps, (t) {
      i++;
      _setLevel(start + (target - start) * (i / steps));
      if (i >= steps) {
        t.cancel();
        if (identical(_fadeDone, done)) {
          _fade = null;
          _fadeDone = null;
        }
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  @visibleForTesting
  int get playedLoops => _played;
}
