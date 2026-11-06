import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mpv/models.dart';
import '../../mpv/player/platform/player_android.dart';
import '../../mpv/player/player.dart';
import '../../utils/app_logger.dart';

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
  Duration get position;
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
  Duration get position => _p.state.position;

  @override
  Future<void> dispose() => _p.dispose();
}

enum ClipPhase { idle, loading, playing, paused, held, failed }

/// The Reel's clip player: plays one card's clip, preloads the next, loops a
/// clip twice and then holds on its last frame, and dips the sound between
/// cards. It never reports a timeline, a scrobble or a media session: it
/// imports none of that code (test/reel/no_reporting_guard_test.dart).
class ClipPlayer {
  ClipPlayer({ClipEngine Function()? engine, this.loops = 2}) : _create = engine ?? ExoClipEngine.new;

  final ClipEngine Function() _create;

  /// Plays before holding on the last frame.
  final int loops;

  ClipEngine? _engine;
  final List<StreamSubscription<Object?>> _subs = [];
  ClipSource? _current;
  int _played = 0;
  bool _muted = false;
  Timer? _fade;
  Stopwatch? _ttff;

  final ValueNotifier<ClipPhase> phase = ValueNotifier(ClipPhase.idle);

  /// Time to first frame of the last clip, for the measure-day stopwatch.
  final ValueNotifier<Duration?> lastTtff = ValueNotifier(null);

  ClipEngine? get engine => _engine;
  ClipSource? get current => _current;
  bool get muted => _muted;

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
      );
    return e;
  }

  /// Plays [source]. [first] fades in from silence over 600 ms (a session's
  /// first clip on the TV, for the soundbar); later cards dip from 30% over
  /// 300 ms after the outgoing clip fades out over 250 ms.
  Future<void> play(ClipSource source, {bool first = false}) async {
    final e = _ensure();
    if (_current != null && !first) await _fadeTo(0, const Duration(milliseconds: 250));
    _current = source;
    _played = 0;
    phase.value = ClipPhase.loading;
    _ttff = Stopwatch()..start();
    await e.setVolume(_muted ? 0 : (first ? 0 : 30));
    await e.open(source.uri);
    if (!_muted) unawaited(_fadeTo(100, Duration(milliseconds: first ? 600 : 300)));
  }

  /// Buffers the next card's opening seconds on the same core.
  Future<void> preload(ClipSource? next) async {
    final e = _ensure();
    if (next == null || !next.preloadable) {
      await e.clearPreloads();
      return;
    }
    await e.preload(next.uri);
  }

  /// Memory pressure: drop the buffered next card without building a core.
  Future<void> dropPreload() async => _engine?.clearPreloads();

  Future<void> pause() async {
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
    _fade?.cancel();
    await _engine?.setVolume(muted ? 0 : 100);
  }

  /// Hide the native surface while a card is dragged (it can't slide).
  Future<void> setVisible(bool visible) async => _engine?.setVisible(visible);

  /// Releases the core and awaits its dispose, so the real player can open
  /// right after (two decoders never run at once on the 3 GB Shield).
  Future<void> release() async {
    _fade?.cancel();
    final e = _engine;
    _engine = null;
    _current = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    phase.value = ClipPhase.idle;
    if (e != null) await e.dispose();
  }

  void _onFirstFrame() {
    final sw = _ttff;
    if (sw != null) {
      sw.stop();
      lastTtff.value = sw.elapsed;
      appLogger.i('[ReelTTFF] ${_current?.origin.name} ${sw.elapsedMilliseconds}ms');
      _ttff = null;
    }
    if (phase.value == ClipPhase.loading) phase.value = ClipPhase.playing;
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
      phase.value = ClipPhase.held;
    }
  }

  Future<void> _fadeTo(double target, Duration over) async {
    _fade?.cancel();
    final e = _engine;
    if (e == null) return;
    const steps = 6;
    final done = Completer<void>();
    var i = 0;
    final start = target == 0 ? 100.0 : (target == 100 ? 30.0 : 50.0);
    _fade = Timer.periodic(over ~/ steps, (t) {
      i++;
      final v = start + (target - start) * (i / steps);
      unawaited(e.setVolume(v));
      if (i >= steps) {
        t.cancel();
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future;
  }

  @visibleForTesting
  int get playedLoops => _played;
}
