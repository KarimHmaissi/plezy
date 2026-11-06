import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mpv/models.dart';
import '../../mpv/player/platform/player_android.dart';
import '../../mpv/player/player.dart';
import '../../screens/video_player/wakelock_controller.dart';
import '../../utils/app_logger.dart';
import 'reel_perf.dart';
import 'reel_volume.dart';

/// Where a clip comes from. Clips never carry request headers: the Plex
/// token rides in the PMS URL only, so nothing Plex reaches AnimeThemes.
enum ClipOrigin { plexExtra, animeTheme }

class ClipSource {
  const ClipSource({required this.uri, required this.origin, this.length, this.preloadable = true});

  final String uri;
  final ClipOrigin origin;
  final Duration? length;

  /// Whether the next card may preload this clip. False for a clip on a
  /// server marked slow this session (spec §8: never preloaded off a slow
  /// guest server); it streams only when its card is on screen.
  final bool preloadable;

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

  /// Initializes the core with no media (V2-04): the first [open] then
  /// skips that step. Allocates no decoder; only an open does.
  Future<void> warm();
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

  /// Whether the core is playing (ExoPlayer's `isPlaying`): false while
  /// paused, buffering or ended, so a pause the Reel didn't ask for (a lost
  /// audio focus) shows here only (V2-22).
  Stream<bool> get playing;

  /// Whether the core is waiting on data (a seek, a stall, an open).
  Stream<bool> get buffering;

  /// Takes the system's audio focus for the clip's sound (V2-22): music
  /// playing elsewhere pauses, and a call or another app pauses the clip.
  Future<bool> requestAudioFocus();
  Future<void> abandonAudioFocus();
  Future<void> dispose();
}

/// ExoPlayer in clip mode (Android): one core for the whole Reel session.
/// Every level it is sent is scaled by [ReelVolume] (On TV mode's volume
/// buttons), and a change to it applies at once.
class ExoClipEngine implements ClipEngine {
  ExoClipEngine({ValueListenable<int>? volume})
    : _p = PlayerAndroid(clipMode: true),
      _volume = volume ?? ReelVolume.level {
    _volume.addListener(_onVolume);
  }

  final PlayerAndroid _p;
  final ValueListenable<int> _volume;

  /// The level last asked for, before [ReelVolume.scale].
  double _asked = 100;

  void _onVolume() => unawaited(_p.setVolume(ReelVolume.scale(_asked, _volume.value)));

  @override
  Player get player => _p;

  @override
  Future<void> warm() => _p.warmClip();

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
  Future<void> setVolume(double volume) {
    _asked = volume;
    return _p.setVolume(ReelVolume.scale(volume, _volume.value));
  }

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
  Stream<bool> get playing => _p.streams.playing;

  @override
  Stream<bool> get buffering => _p.streams.buffering;

  @override
  Future<bool> requestAudioFocus() => _p.requestAudioFocus();

  @override
  Future<void> abandonAudioFocus() => _p.abandonAudioFocus();

  @override
  Future<void> dispose() {
    _volume.removeListener(_onVolume);
    return _p.dispose();
  }
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

/// The Reel's clip player: plays one card's clip, preloads the next, plays a
/// clip as many times as the clip-end pref says (V2-47) and then holds on
/// its last frame, and ramps the sound between cards. It never reports a timeline, a scrobble or a media session: it
/// imports none of that code (test/reel/no_reporting_guard_test.dart).
///
/// Sound and screen (V2-22): the first audible clip of a session takes the
/// system's audio focus, and [release] gives it back, so the main player
/// takes its own focus after Watch. A pause the system makes (a call,
/// another app's sound) reads as [ClipPhase.paused]. The screen is kept on
/// only while a clip opens or plays, so the screensaver still comes in over
/// a paused or held card.
class ClipPlayer {
  /// [wakelock] defaults to the platform's for the real core, and to none
  /// for an injected test engine. [muted] is the saved mute (`reel_muted`).
  ClipPlayer({
    ClipEngine Function()? engine,
    int? Function()? plays,
    ReelPerf? perf,
    WakelockController? wakelock,
    this._muted = false,
    this.openLimit = defaultOpenLimit,
    this.callLimit = defaultCallLimit,
  }) : _create = engine ?? ExoClipEngine.new,
       _plays = plays ?? _twice,
       _perf = perf ?? ReelPerf.instance,
       _wakelock = wakelock ?? (engine == null ? WakelockController() : null) {
    phase.addListener(_syncWakelock);
  }

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

  /// How long the core must stay stopped, while the Reel wants it playing
  /// and it isn't buffering or at the end, before that reads as a pause the
  /// system made. It rides over the stop an error or a loop sends first.
  static const Duration externalPauseGrace = Duration(milliseconds: 250);

  static int? _twice() => 2;

  /// The longest a clip's open may take. The core's open returns once the
  /// clip is handed to the player (buffering comes after), so an open still
  /// waiting after this means the core is wedged (its thread gone after a
  /// long standby): the core is let go and the clip reads as failed, so the
  /// card falls back and the next clip builds a fresh core.
  static const Duration defaultOpenLimit = Duration(seconds: 10);

  /// The longest any other call to the core may take (pause, play, seek,
  /// preload, dispose): a wedged core never holds up a card change or a
  /// release.
  static const Duration defaultCallLimit = Duration(seconds: 5);

  final Duration openLimit;
  final Duration callLimit;

  /// [call], given up on after [callLimit] (a wedged core).
  Future<void> _bounded(Future<void>? call, String what) async {
    if (call == null) return;
    try {
      await call.timeout(callLimit);
    } on TimeoutException {
      appLogger.w('Reel: clip core $what timed out after ${callLimit.inMilliseconds}ms');
    }
  }

  final ClipEngine Function() _create;

  /// The debug overlay's tape (it records nothing unless switched on).
  final ReelPerf _perf;

  /// How many times a clip plays before it holds on its last frame; null
  /// loops it for good. Asked at each end, so a change to the clip-end pref
  /// applies to the clip already playing.
  final int? Function() _plays;

  /// Keeps the screen on while a clip opens or plays (null in tests).
  final WakelockController? _wakelock;
  bool _wakeOn = false;

  ClipEngine? _engine;
  final List<StreamSubscription<Object?>> _subs = [];
  ClipSource? _current;
  int _played = 0;
  bool _muted;

  /// This session's core holds (or has asked for) the audio focus.
  bool _focus = false;

  /// The focus was asked for at least once on this core: [release] gives it
  /// back.
  bool _focusAsked = false;

  /// The Reel wants the core playing: set by every open, resume, replay and
  /// loop; cleared by a pause, a hold and [release].
  bool _wantPlaying = false;

  /// What the core last said about itself ([ClipEngine.playing],
  /// [ClipEngine.buffering]); [_ended] from its end until it plays again.
  bool _enginePlaying = false;
  bool _engineBuffering = false;
  bool _ended = false;

  /// The system paused the clip (a lost audio focus): a focus that comes
  /// back may play it again; a pause of the Reel's own may not.
  bool _pausedExternally = false;
  Timer? _externalPause;

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

  /// Whether the screen is being kept on.
  @visibleForTesting
  bool get keepsScreenOn => _wakeOn;

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
          // No clip open yet (a warm core's init failing): not a clip's
          // failure, so no card reads it as one. [warm] lets the core go.
          if (_current == null) {
            appLogger.w('Reel: clip core error with no clip open: ${err.message}');
            return;
          }
          appLogger.w('Reel: clip error: ${err.message}');
          phase.value = ClipPhase.failed;
        }),
      )
      ..add(e.logs.listen(_onLog))
      ..add(e.playing.listen(_onEnginePlaying))
      ..add(e.buffering.listen((b) => _engineBuffering = b))
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

  /// Builds the core and initializes it with no media (the TV's cold open,
  /// V2-04), alongside the deck load, so the first [play] doesn't wait for
  /// the core. Allocates no decoder: only an open hands the core a clip. A
  /// core already built is left as it is.
  ///
  /// Bounded by [callLimit]. A warm that runs out or throws lets the core
  /// go (the next [play] builds a fresh one), unless a [play] has started
  /// on it meanwhile: that open's own [openLimit] decides then. Returns how
  /// long the warm took, or null when nothing was warmed.
  Future<Duration?> warm() async {
    if (_engine != null) return null;
    final e = _ensure();
    final opens = _opens;
    final sw = Stopwatch()..start();
    try {
      await e.warm().timeout(callLimit);
    } on TimeoutException {
      appLogger.w('Reel: clip core warm timed out after ${callLimit.inMilliseconds}ms');
      if (_opens == opens) _abandon(e);
      return null;
    } catch (err) {
      appLogger.w('Reel: clip core warm failed', error: err);
      if (_opens == opens) _abandon(e);
      return null;
    }
    return sw.elapsed;
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
    _wantPlaying = true;
    _pausedExternally = false;
    _ended = false;
    _cancelExternalPause();
    // Asked for before the open starts the sound (the audio-focus guide).
    _takeFocus();
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
    try {
      await e.open(source.uri).timeout(openLimit);
    } on TimeoutException {
      if (open != _opens || !identical(_engine, e)) return;
      appLogger.w('Reel: clip open timed out after ${openLimit.inMilliseconds}ms; the clip core is let go');
      _abandon(e);
      phase.value = ClipPhase.failed;
      return;
    } catch (err) {
      // The core threw on the open (it couldn't start, or refused the
      // clip): read as an open that never came back, so the card falls back
      // at once and the next clip builds a fresh core, instead of the error
      // escaping into the card change that asked for it while the phase
      // stays loading.
      if (open != _opens || !identical(_engine, e)) return;
      appLogger.w('Reel: clip open failed; the clip core is let go', error: err);
      _abandon(e);
      phase.value = ClipPhase.failed;
      return;
    }
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
      await _bounded(e.clearPreloads(), 'clearPreloads');
      return;
    }
    _preloaded = next.uri;
    await _bounded(e.preload(next.uri), 'preload');
  }

  /// Memory pressure: drop the buffered next card without building a core.
  Future<void> dropPreload() async {
    _preloaded = null;
    await _bounded(_engine?.clearPreloads(), 'clearPreloads');
  }

  Future<void> pause() async {
    // A press that led to no clip (an AI card, the end of a deck) times
    // nothing.
    _key = null;
    _wantPlaying = false;
    _pausedExternally = false;
    _cancelExternalPause();
    await _bounded(_engine?.pause(), 'pause');
    if (phase.value == ClipPhase.playing || phase.value == ClipPhase.loading) phase.value = ClipPhase.paused;
  }

  Future<void> resume() async {
    if (phase.value == ClipPhase.held) return replay();
    if (_engine != null && _current != null) _wantPlaying = true;
    _pausedExternally = false;
    // After a lost focus the system keeps the clip silent until the focus
    // is asked for again.
    _takeFocus();
    await _bounded(_engine?.play(), 'play');
    if (phase.value == ClipPhase.paused) phase.value = ClipPhase.playing;
  }

  Future<void> togglePause() => phase.value == ClipPhase.playing ? pause() : resume();

  Future<void> replay() async {
    final e = _engine;
    if (e == null || _current == null) return;
    _played = 0;
    _wantPlaying = true;
    _pausedExternally = false;
    _takeFocus();
    await _bounded(e.seek(Duration.zero), 'seek');
    await _bounded(e.play(), 'play');
    if (onScreen.value != null) progress.value = ClipProgress(Duration.zero, _length);
    phase.value = ClipPhase.playing;
  }

  /// FF / RW: ±10 s within the clip.
  Future<void> seekBy(Duration delta) async {
    final e = _engine;
    if (e == null) return;
    final to = e.position + delta;
    await _bounded(e.seek(to < Duration.zero ? Duration.zero : to), 'seek');
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    _cancelFade();
    _setLevel(muted ? 0 : 100);
    // A muted session takes no focus, so the first unmute does.
    if (!muted && _wantPlaying) _takeFocus();
  }

  /// Hide the native surface while a card is dragged (it can't slide).
  Future<void> setVisible(bool visible) => _bounded(_engine?.setVisible(visible), 'setVisible');

  /// Releases the core and awaits its dispose, so the real player can open
  /// right after (two decoders never run at once on the 3 GB Shield).
  Future<void> release() async {
    _cancelFade();
    _cancelExternalPause();
    final e = _engine;
    final focusAsked = _focusAsked;
    _focus = false;
    _focusAsked = false;
    _wantPlaying = false;
    _pausedExternally = false;
    _enginePlaying = false;
    _engineBuffering = false;
    _ended = false;
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
    // Taken before the first await: Android's hidden and paused arrive
    // back to back, and a second release must not walk the same list.
    final subs = List.of(_subs);
    _subs.clear();
    for (final s in subs) {
      await _bounded(s.cancel(), 'unsubscribe');
    }
    onScreen.value = null;
    phase.value = ClipPhase.idle;
    // Both are let go before the core goes, so the main player's own focus
    // and wakelock (after Watch) start from a clean slate.
    await _bounded(_wakelock?.setEnabled(false), 'wakelock');
    if (e != null) await _letGo(e, focusAsked: focusAsked);
  }

  /// Gives back [e]'s audio focus (when it was asked for) and disposes it,
  /// each bounded by [callLimit].
  Future<void> _letGo(ClipEngine e, {required bool focusAsked}) async {
    if (focusAsked) {
      try {
        await _bounded(e.abandonAudioFocus(), 'abandonAudioFocus');
      } catch (err) {
        appLogger.w('Reel: abandoning audio focus failed', error: err);
      }
    }
    await _bounded(e.dispose(), 'dispose');
  }

  /// The core's open never came back: it is let go (in the background,
  /// bounded) and the next [play] builds a fresh one. [current] stays, so
  /// the failure is read as this clip's.
  void _abandon(ClipEngine e) {
    if (!identical(_engine, e)) return;
    _cancelFade();
    _cancelExternalPause();
    final focusAsked = _focusAsked;
    _focus = false;
    _focusAsked = false;
    _wantPlaying = false;
    _enginePlaying = false;
    _engineBuffering = false;
    _engine = null;
    _preloaded = null;
    _openKey = null;
    _ttff = null;
    _level = 0;
    onScreen.value = null;
    final subs = List.of(_subs);
    _subs.clear();
    unawaited(
      () async {
        for (final s in subs) {
          await _bounded(s.cancel(), 'unsubscribe');
        }
        await _letGo(e, focusAsked: focusAsked);
      }().catchError((Object err) => appLogger.w('Reel: letting a wedged clip core go failed', error: err)),
    );
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
    _ended = true;
    _cancelExternalPause();
    _played++;
    final plays = _plays();
    if (plays == null || _played < plays) {
      unawaited(e.seek(Duration.zero).then((_) => e.play()));
    } else {
      // Hold on the last frame; Replay is focused by the view, and Lean
      // back moves on from here (ReelController).
      _wantPlaying = false;
      unawaited(e.pause());
      if (onScreen.value != null) progress.value = ClipProgress(_length, _length);
      phase.value = ClipPhase.held;
    }
  }

  /// Asks for the audio focus once per session, for an audible clip only:
  /// a muted Reel never pauses music playing elsewhere.
  void _takeFocus() {
    final e = _engine;
    if (e == null || _muted || _focus) return;
    _focus = true;
    _focusAsked = true;
    unawaited(_askFocus(e));
  }

  Future<void> _askFocus(ClipEngine e) async {
    var granted = false;
    try {
      granted = await e.requestAudioFocus();
    } catch (err) {
      appLogger.w('Reel: audio focus request failed', error: err);
    }
    if (granted || !identical(_engine, e)) return;
    // Refused (a call holds it): the next resume, replay or card asks again.
    appLogger.i('Reel: audio focus not granted');
    _focus = false;
  }

  /// The core started or stopped. A stop the Reel didn't ask for, that
  /// isn't a stall or the clip's end, is the system's pause (a lost audio
  /// focus): after [externalPauseGrace] it shows as [ClipPhase.paused]. A
  /// start the Reel didn't ask for is the focus coming back: it plays on
  /// only if the system was the one that paused it.
  void _onEnginePlaying(bool playing) {
    _enginePlaying = playing;
    if (playing) {
      _ended = false;
      _cancelExternalPause();
      if (_wantPlaying) return;
      if (_pausedExternally) {
        _pausedExternally = false;
        _wantPlaying = true;
        _focus = true;
        if (phase.value == ClipPhase.paused) phase.value = ClipPhase.playing;
      } else if (phase.value == ClipPhase.paused || phase.value == ClipPhase.held) {
        // Paused by the viewer, or holding: the returning focus doesn't
        // override that.
        unawaited(_engine?.pause());
      }
      return;
    }
    if (!_wantPlaying || phase.value != ClipPhase.playing) return;
    _cancelExternalPause();
    _externalPause = Timer(externalPauseGrace, _checkExternalPause);
  }

  void _checkExternalPause() {
    _externalPause = null;
    if (_enginePlaying || _engineBuffering || _ended || !_wantPlaying || phase.value != ClipPhase.playing) return;
    appLogger.i('[Reel] clip paused by the system (audio focus)');
    _wantPlaying = false;
    _pausedExternally = true;
    // A permanent loss never hands the focus back: the viewer's resume asks.
    _focus = false;
    phase.value = ClipPhase.paused;
  }

  void _cancelExternalPause() {
    _externalPause?.cancel();
    _externalPause = null;
  }

  /// The screen stays on while a clip opens or plays, and only then.
  void _syncWakelock() {
    final on = phase.value == ClipPhase.playing || phase.value == ClipPhase.loading;
    if (on == _wakeOn) return;
    _wakeOn = on;
    unawaited(_wakelock?.setEnabled(on));
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
