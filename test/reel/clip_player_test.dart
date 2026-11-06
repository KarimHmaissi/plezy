// The fake engine's controllers are closed in tearDown.
// ignore_for_file: close_sinks
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/reel/clip_player.dart';
import 'package:plezy/screens/video_player/wakelock_controller.dart';
import 'package:plezy/services/reel/reel_perf.dart';
import 'package:plezy/utils/app_logger.dart';

class FakeClipEngine implements ClipEngine {
  final calls = <String>[];
  final completedCtl = StreamController<bool>.broadcast(sync: true);
  final firstFrameCtl = StreamController<void>.broadcast(sync: true);
  final errorCtl = StreamController<PlayerError>.broadcast(sync: true);
  final logCtl = StreamController<PlayerLog>.broadcast(sync: true);
  final positionCtl = StreamController<Duration>.broadcast(sync: true);
  final durationCtl = StreamController<Duration>.broadcast(sync: true);
  final playingCtl = StreamController<bool>.broadcast(sync: true);
  final bufferingCtl = StreamController<bool>.broadcast(sync: true);
  final volumes = <double>[];

  /// What [requestAudioFocus] answers.
  bool grantFocus = true;
  bool disposed = false;
  Completer<void>? disposeGate;

  /// Holds every open until completed (a slow, or never-finishing, open).
  Completer<void>? openGate;

  /// Holds every pause until completed (a pause still on its way).
  Completer<void>? pauseGate;

  /// Holds every warm until completed (a slow, or never-finishing, core
  /// init); [warmError] makes a warm throw once let through.
  Completer<void>? warmGate;
  Object? warmError;

  @override
  Player get player => throw UnimplementedError();

  @override
  Future<void> warm() async {
    calls.add('warm');
    await warmGate?.future;
    final err = warmError;
    if (err != null) throw err;
  }

  @override
  Future<void> open(String uri) async {
    calls.add('open $uri');
    await openGate?.future;
  }

  @override
  Future<void> preload(String uri) async => calls.add('preload $uri');

  @override
  Future<void> clearPreloads() async => calls.add('clearPreloads');

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async {
    calls.add('pause');
    await pauseGate?.future;
  }

  @override
  Future<void> seek(Duration position) async => calls.add('seek ${position.inSeconds}');

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> setVisible(bool visible) async => calls.add('visible $visible');

  @override
  Stream<bool> get completed => completedCtl.stream;

  @override
  Stream<void> get firstFrame => firstFrameCtl.stream;

  @override
  Stream<PlayerError> get errors => errorCtl.stream;

  @override
  Stream<PlayerLog> get logs => logCtl.stream;

  @override
  Duration position = const Duration(seconds: 20);

  @override
  Stream<Duration> get positions => positionCtl.stream;

  @override
  Stream<Duration> get durations => durationCtl.stream;

  @override
  Duration duration = Duration.zero;

  @override
  Stream<bool> get playing => playingCtl.stream;

  @override
  Stream<bool> get buffering => bufferingCtl.stream;

  @override
  Future<bool> requestAudioFocus() async {
    calls.add('requestAudioFocus');
    return grantFocus;
  }

  @override
  Future<void> abandonAudioFocus() async => calls.add('abandonAudioFocus');

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await disposeGate?.future;
    disposed = true;
  }
}

/// A core that throws on its open (it couldn't start, or refused the clip).
class _RefusingEngine extends FakeClipEngine {
  @override
  Future<void> open(String uri) async {
    calls.add('open $uri');
    throw PlatformException(code: 'open', message: 'the core could not open the clip');
  }
}

/// A core whose pause never answers while [hangPause] is set.
class _SilentEngine extends FakeClipEngine {
  bool hangPause = false;

  @override
  Future<void> pause() async {
    calls.add('pause');
    if (hangPause) await Completer<void>().future;
  }
}

const _a = ClipSource(uri: 'https://cdn.example/a.mp4', origin: ClipOrigin.plexExtra);
const _b = ClipSource(uri: 'https://v.example/b.webm', origin: ClipOrigin.animeTheme);

void main() {
  late FakeClipEngine engine;
  late ClipPlayer clips;

  tearDown(() async {
    await engine.completedCtl.close();
    await engine.firstFrameCtl.close();
    await engine.errorCtl.close();
    await engine.logCtl.close();
    await engine.positionCtl.close();
    await engine.durationCtl.close();
    await engine.playingCtl.close();
    await engine.bufferingCtl.close();
  });

  setUp(() {
    engine = FakeClipEngine();
    clips = ClipPlayer(engine: () => engine);
  });

  test('plays, reports first frame, loops twice, then holds on the last frame', () async {
    await clips.play(_a, first: true);
    expect(engine.calls, contains('open ${_a.uri}'));
    expect(clips.phase.value, ClipPhase.loading);
    engine.firstFrameCtl.add(null);
    expect(clips.phase.value, ClipPhase.playing);
    expect(clips.lastTtff.value, isNotNull);

    engine.completedCtl.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(engine.calls.sublist(engine.calls.length - 2), ['seek 0', 'play']);
    expect(clips.phase.value, ClipPhase.playing);

    engine.completedCtl.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(engine.calls.last, 'pause');
    expect(clips.phase.value, ClipPhase.held);

    // OK / Play on a held clip replays it.
    await clips.resume();
    expect(engine.calls.sublist(engine.calls.length - 2), ['seek 0', 'play']);
    expect(clips.phase.value, ClipPhase.playing);
  });

  test('the first clip rises from silence without a jump; later cards dip from 30%', () {
    fakeAsync((async) {
      clips.play(_a, first: true);
      async.flushMicrotasks();
      expect(engine.volumes.first, 0);
      async.elapse(const Duration(milliseconds: 100));
      // One step of six, from 0: no jump to 30 % or more on the first tick.
      expect(engine.volumes.last, closeTo(100 / 6, 0.01));
      async.elapse(const Duration(milliseconds: 600));
      expect(engine.volumes.last, closeTo(100, 0.01));

      engine.volumes.clear();
      clips.play(_b);
      async.flushMicrotasks();
      expect(engine.volumes, contains(ClipPlayer.dipLevel));
      async.elapse(const Duration(milliseconds: 400));
      expect(engine.volumes.last, closeTo(100, 0.01));
    });
  });

  group('V2-01: a card change opens at once', () {
    test('the next clip opens before any fade has run, in loading, with nothing on screen', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.elapse(const Duration(milliseconds: 700));
        engine.firstFrameCtl.add(null);
        expect(clips.onScreen.value, _a);

        clips.play(_b);
        // Synchronous: the phase and the picture move before any await.
        expect(clips.phase.value, ClipPhase.loading);
        expect(clips.onScreen.value, isNull);
        expect(clips.current, _b);
        async.flushMicrotasks();
        expect(engine.calls.last, 'open ${_b.uri}');
        engine.firstFrameCtl.add(null);
        expect(clips.onScreen.value, _b);
        expect(clips.phase.value, ClipPhase.playing);
      });
    });

    test('the outgoing clip ramps to silence alongside a slow open, within the one constant', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.elapse(const Duration(milliseconds: 700));
        engine.openGate = Completer<void>();
        engine.volumes.clear();
        var done = false;
        clips.play(_b).then((_) => done = true);
        async.flushMicrotasks();
        expect(engine.calls.last, 'open ${_b.uri}');
        async.elapse(ClipPlayer.outgoingFade);
        expect(clips.level, closeTo(0, 0.01));
        expect(engine.volumes, everyElement(lessThan(100)));
        engine.openGate!.complete();
        async.flushMicrotasks();
        expect(done, isTrue);
        async.elapse(ClipPlayer.fadeIn);
        expect(clips.level, closeTo(100, 0.01));
      });
    });

    test('an interrupted ramp carries on from where it was, not from 100', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.elapse(const Duration(milliseconds: 300));
        final mid = clips.level;
        expect(mid, inExclusiveRange(0, 100));
        engine.openGate = Completer<void>();
        engine.volumes.clear();
        clips.play(_b);
        async.elapse(const Duration(milliseconds: 20));
        expect(engine.volumes, isNotEmpty);
        expect(engine.volumes, everyElement(lessThan(mid)));
        engine.openGate!.complete();
        async.flushMicrotasks();
      });
    });

    test('muting during a card change never stalls the next clip', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.elapse(const Duration(milliseconds: 700));
        engine.openGate = Completer<void>();
        var done = false;
        clips.play(_b).then((_) => done = true);
        async.elapse(const Duration(milliseconds: 40));
        clips.setMuted(true);
        engine.openGate!.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(done, isTrue);
        expect(engine.calls, contains('open ${_b.uri}'));
        expect(clips.level, 0);
        expect(engine.volumes.last, 0);
      });
    });

    test('a slow open that a later card overtakes never ramps the later card', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.elapse(const Duration(milliseconds: 700));
        final slow = engine.openGate = Completer<void>();
        clips.play(_b);
        async.flushMicrotasks();
        engine.openGate = null;
        clips.play(_a);
        async.flushMicrotasks();
        async.elapse(ClipPlayer.fadeIn);
        expect(clips.level, closeTo(100, 0.01));
        engine.volumes.clear();
        slow.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 400));
        expect(engine.volumes, isEmpty, reason: 'the overtaken open returns without touching the sound');
      });
    });

    test('release clears the picture', () async {
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      await clips.release();
      expect(clips.onScreen.value, isNull);
    });

    test('[ReelTTFF] times the key press to the first frame, with the open and the preload', () async {
      MemoryLogOutput.clearLogs();
      await clips.preload(_b);
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      clips.markKey(Stopwatch()..start());
      await clips.play(_b);
      engine.firstFrameCtl.add(null);
      final lines = MemoryLogOutput.getLogs().map((e) => e.message).where((m) => m.startsWith('[ReelTTFF]')).toList();
      // Newest first.
      expect(lines, hasLength(2));
      expect(
        lines.first,
        matches(RegExp(r'^\[ReelTTFF\] key=\d+ms open=\d+ms preloaded=false trigger=step origin=animeTheme$')),
      );
      expect(lines.last, matches(RegExp(r'^\[ReelTTFF\] key=none open=\d+ms preloaded=false origin=plexExtra$')));
    });

    test('a preloaded card says so; a press that led to no clip times nothing', () async {
      MemoryLogOutput.clearLogs();
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      await clips.preload(_b);
      clips.markKey(Stopwatch()..start(), trigger: 'deck');
      await clips.play(_b);
      engine.firstFrameCtl.add(null);
      // An AI card: the controller pauses the core instead of opening.
      clips.markKey(Stopwatch()..start());
      await clips.pause();
      await clips.play(_a);
      engine.firstFrameCtl.add(null);
      final lines = MemoryLogOutput.getLogs().map((e) => e.message).where((m) => m.startsWith('[ReelTTFF]')).toList();
      expect(lines[1], contains('preloaded=true trigger=deck'));
      expect(lines[0], startsWith('[ReelTTFF] key=none'));
    });
  });

  group('the clip-end pref sets the plays (V2-47)', () {
    test('loop plays on for good and never holds', () async {
      clips = ClipPlayer(engine: () => engine, plays: () => null);
      await clips.play(_a);
      engine.firstFrameCtl.add(null);
      for (var i = 0; i < 4; i++) {
        engine.completedCtl.add(true);
        await Future<void>.delayed(Duration.zero);
      }
      expect(clips.phase.value, ClipPhase.playing);
      expect(engine.calls, isNot(contains('pause')));
      expect(clips.playedLoops, 4);
    });

    test('next card holds after one play', () async {
      clips = ClipPlayer(engine: () => engine, plays: () => 1);
      await clips.play(_a);
      engine.firstFrameCtl.add(null);
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls.last, 'pause');
      expect(clips.phase.value, ClipPhase.held);
    });

    test('the pref is read at each end, so a change applies to the clip playing', () async {
      int? plays = 2;
      clips = ClipPlayer(engine: () => engine, plays: () => plays);
      await clips.play(_a);
      engine.firstFrameCtl.add(null);
      plays = null;
      engine.completedCtl.add(true);
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(clips.phase.value, ClipPhase.playing);
      plays = 1;
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(clips.phase.value, ClipPhase.held);
    });
  });

  test('preloads the next card on the same core, or clears it', () async {
    await clips.preload(_b);
    await clips.preload(null);
    expect(engine.calls, ['preload ${_b.uri}', 'clearPreloads']);
  });

  test('a clip off a server marked slow is never preloaded (V2-11)', () async {
    await clips.preload(
      const ClipSource(uri: 'https://cdn.example/c.mp4', origin: ClipOrigin.plexExtra, preloadable: false),
    );
    expect(engine.calls, ['clearPreloads']);
  });

  test('muted stays muted across cards', () async {
    await clips.setMuted(true);
    await clips.play(_a);
    expect(engine.volumes, everyElement(0));
  });

  test('release awaits the native dispose before returning', () async {
    await clips.play(_a);
    engine.disposeGate = Completer<void>();
    var released = false;
    final f = clips.release().then((_) => released = true);
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse);
    engine.disposeGate!.complete();
    await f;
    expect(engine.disposed, isTrue);
    expect(clips.phase.value, ClipPhase.idle);
    expect(clips.engine, isNull);
  });

  test('two releases at once (the app hidden, then paused) both finish and dispose the core', () async {
    await clips.play(_a);
    final first = clips.release();
    final second = clips.release();
    await Future.wait([first, second]);
    expect(engine.disposed, isTrue);
    expect(engine.calls.where((c) => c == 'dispose'), hasLength(1));
    expect(clips.phase.value, ClipPhase.idle);
  });

  group('a wedged core (the Shield after a long standby)', () {
    test('an open that never comes back fails the clip, lets the core go, and the next clip builds a fresh one', () {
      fakeAsync((async) {
        final built = <FakeClipEngine>[];
        final wedged = Completer<void>();
        clips = ClipPlayer(
          engine: () {
            final e = FakeClipEngine()..openGate = built.isEmpty ? wedged : null;
            built.add(e);
            return engine = e;
          },
        );
        var done = false;
        clips.play(_a, first: true).then((_) => done = true);
        async.elapse(ClipPlayer.defaultOpenLimit - const Duration(milliseconds: 1));
        expect(done, isFalse);
        expect(clips.phase.value, ClipPhase.loading);
        async.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue, reason: 'the open is never waited on for good');
        expect(clips.phase.value, ClipPhase.failed);
        expect(clips.current, _a, reason: 'the failure is read as this clip\'s');
        expect(clips.engine, isNull);
        async.flushMicrotasks();
        expect(built.first.disposed, isTrue);

        clips.play(_b);
        async.flushMicrotasks();
        expect(built, hasLength(2));
        expect(built.last.calls, contains('open ${_b.uri}'));
        expect(clips.phase.value, ClipPhase.loading);
        // The wedged open landing late changes nothing.
        wedged.complete();
        async.flushMicrotasks();
        expect(clips.engine, same(built.last));
        expect(clips.phase.value, ClipPhase.loading);
      });
    });

    test('an open the core throws on fails the clip like one that never came back, and nothing escapes', () async {
      final built = <FakeClipEngine>[];
      clips = ClipPlayer(
        engine: () {
          final e = built.isEmpty ? _RefusingEngine() : FakeClipEngine();
          built.add(e);
          return engine = e;
        },
      );
      await clips.play(_a, first: true);
      expect(clips.phase.value, ClipPhase.failed);
      expect(clips.current, _a, reason: 'the failure is read as this clip\'s');
      expect(clips.engine, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(built.first.disposed, isTrue);

      await clips.play(_b);
      expect(built, hasLength(2), reason: 'the next clip builds a fresh core');
      expect(clips.phase.value, ClipPhase.loading);
    });

    test('a pause or a release on a core that never answers is given up on', () {
      fakeAsync((async) {
        final stuck = _SilentEngine();
        clips = ClipPlayer(engine: () => engine = stuck);
        clips.play(_a, first: true);
        async.flushMicrotasks();
        var paused = false, released = false;
        stuck.hangPause = true;
        clips.pause().then((_) => paused = true);
        async.elapse(ClipPlayer.defaultCallLimit);
        expect(paused, isTrue);
        stuck.disposeGate = Completer<void>();
        clips.release().then((_) => released = true);
        async.elapse(ClipPlayer.defaultCallLimit * 3);
        expect(released, isTrue);
        expect(clips.phase.value, ClipPhase.idle);
      });
    });
  });

  group('warm core (V2-04)', () {
    test('a warm builds and initializes the core with no media; the first clip opens on that core', () async {
      var built = 0;
      clips = ClipPlayer(
        engine: () {
          built++;
          return engine = FakeClipEngine();
        },
      );
      final took = await clips.warm();
      expect(took, isNotNull);
      expect(built, 1);
      expect(engine.calls, ['warm'], reason: 'no open, preload, surface or focus: nothing that takes a decoder');
      expect(clips.phase.value, ClipPhase.idle);
      expect(clips.current, isNull);
      expect(clips.keepsScreenOn, isFalse);

      await clips.play(_a, first: true);
      expect(built, 1, reason: 'the open reuses the warm core');
      expect(engine.calls.where((c) => c.startsWith('open')), ['open ${_a.uri}']);
      expect(engine.calls.where((c) => c == 'warm'), hasLength(1));
    });

    test('a core already built is left as it is', () async {
      await clips.play(_a, first: true);
      expect(await clips.warm(), isNull);
      expect(engine.calls, isNot(contains('warm')));
    });

    test('a warm that never comes back lets the core go within the call limit; the next clip builds afresh', () {
      fakeAsync((async) {
        final built = <FakeClipEngine>[];
        clips = ClipPlayer(
          engine: () {
            final e = FakeClipEngine()..warmGate = built.isEmpty ? Completer<void>() : null;
            built.add(e);
            return engine = e;
          },
        );
        Duration? took = const Duration(days: 1);
        var done = false;
        clips.warm().then((d) {
          took = d;
          done = true;
        });
        async.elapse(ClipPlayer.defaultCallLimit - const Duration(milliseconds: 1));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue, reason: 'a warm is never waited on for good');
        expect(took, isNull);
        expect(clips.engine, isNull);
        async.flushMicrotasks();
        expect(built.first.disposed, isTrue);
        expect(clips.phase.value, ClipPhase.idle);

        clips.play(_a, first: true);
        async.flushMicrotasks();
        expect(built, hasLength(2));
        expect(built.last.calls.where((c) => c.startsWith('open') || c == 'warm'), ['open ${_a.uri}']);
      });
    });

    test('a slow warm with an open already under way leaves the core to the open', () {
      fakeAsync((async) {
        final slow = FakeClipEngine()..warmGate = Completer<void>();
        clips = ClipPlayer(engine: () => engine = slow);
        clips.warm();
        async.flushMicrotasks();
        clips.play(_a, first: true);
        async.elapse(ClipPlayer.defaultCallLimit);
        expect(clips.engine, same(slow), reason: "the warm's limit doesn't cut the open short");
        expect(slow.disposed, isFalse);
        expect(clips.phase.value, ClipPhase.loading);
        slow.firstFrameCtl.add(null);
        expect(clips.phase.value, ClipPhase.playing);
      });
    });

    test('a warm the core throws on lets it go; its error is no clip failure', () async {
      final built = <FakeClipEngine>[];
      clips = ClipPlayer(
        engine: () {
          final e = FakeClipEngine()..warmError = built.isEmpty ? StateError('init failed') : null;
          built.add(e);
          return engine = e;
        },
      );
      final first = clips.warm();
      // The core reports its failed init as a player error, with no clip open.
      built.first.errorCtl.add(const PlayerError('init failed'));
      expect(await first, isNull);
      expect(clips.phase.value, ClipPhase.idle);
      expect(clips.engine, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(built.first.disposed, isTrue);

      await clips.play(_a, first: true);
      expect(built, hasLength(2));
      expect(clips.phase.value, ClipPhase.loading);
      // Once a clip is open, an error is that clip's.
      built.last.errorCtl.add(const PlayerError('decoder'));
      expect(clips.phase.value, ClipPhase.failed);
    });
  });

  test('FF/RW move 10 s within the clip, never before 0', () async {
    await clips.play(_a);
    await clips.seekBy(const Duration(seconds: 10));
    engine.position = const Duration(seconds: 4);
    await clips.seekBy(const Duration(seconds: -10));
    expect(engine.calls.where((c) => c.startsWith('seek')), ['seek 30', 'seek 0']);
  });

  group('progress line (V2-28)', () {
    test('follows the clip on screen only, from its first frame', () async {
      await clips.play(_a, first: true);
      engine.durationCtl.add(const Duration(seconds: 90));
      // The outgoing clip's tick before this one's first frame.
      engine.positionCtl.add(const Duration(seconds: 40));
      expect(clips.progress.value, ClipProgress.zero);

      engine.firstFrameCtl.add(null);
      expect(clips.progress.value, const ClipProgress(Duration.zero, Duration(seconds: 90)));
      engine.positionCtl.add(const Duration(seconds: 45));
      expect(clips.progress.value.fraction, closeTo(0.5, 1e-9));

      // The next card starts again from nothing.
      await clips.play(const ClipSource(uri: 'https://cdn.example/c.mp4', origin: ClipOrigin.plexExtra));
      expect(clips.progress.value, ClipProgress.zero);
    });

    test('a clip as long as the one before takes the length the core holds', () async {
      engine.duration = const Duration(seconds: 60);
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      engine.positionCtl.add(const Duration(seconds: 15));
      expect(clips.progress.value.fraction, closeTo(0.25, 1e-9));
    });

    test('a held clip reads as full; Replay starts it again', () async {
      await clips.play(_a, first: true);
      engine.durationCtl.add(const Duration(seconds: 80));
      engine.firstFrameCtl.add(null);
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(clips.phase.value, ClipPhase.held);
      expect(clips.progress.value.fraction, 1);
      // A late tick does not pull a held line back.
      engine.positionCtl.add(const Duration(seconds: 79));
      expect(clips.progress.value.fraction, 1);

      await clips.replay();
      expect(clips.progress.value.fraction, 0);
    });

    test('no length known is no fraction, and release clears it', () async {
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      engine.positionCtl.add(const Duration(seconds: 5));
      expect(clips.progress.value.fraction, isNull);
      await clips.release();
      expect(clips.progress.value, ClipProgress.zero);
    });
  });

  group('debug overlay tape (V2-07)', () {
    late ReelPerf perf;

    setUp(() {
      perf = ReelPerf()..recording = true;
      clips = ClipPlayer(engine: () => engine, perf: perf);
    });

    PlayerLog log(String prefix, String text) => PlayerLog(level: PlayerLogLevel.debug, prefix: prefix, text: text);

    test('a key press to the first frame records one card, preloaded when the next card was', () async {
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      expect(perf.last!.trigger, ReelPerfTrigger.open);
      expect(perf.last!.preloaded, isFalse);
      expect(perf.last!.origin, 'plexExtra');

      await clips.preload(_b);
      perf.begin(ReelPerfTrigger.key);
      final playing = clips.play(_b);
      engine.logCtl.add(log('clip', 'Open clip: preloaded=true'));
      await playing;
      engine.logCtl.add(log('decoder-hang', 'Decoder initialized: c2.example.decoder (12ms)'));
      engine.firstFrameCtl.add(null);
      final s = perf.last!;
      expect(perf.samples, hasLength(2));
      expect(s.trigger, ReelPerfTrigger.key);
      expect(s.preloaded, isTrue);
      expect(s.origin, 'animeTheme');
      expect(s.openMs, isNotNull);
      expect(s.decoderMs, isNotNull);
    });

    test('a preload cleared before the open is a miss', () async {
      await clips.preload(_b);
      await clips.preload(null);
      perf.begin(ReelPerfTrigger.key);
      await clips.play(_b, first: true);
      engine.firstFrameCtl.add(null);
      expect(perf.last!.preloaded, isFalse);
    });

    test('a release drops the card still waiting for its picture', () async {
      perf.begin(ReelPerfTrigger.key);
      await clips.play(_a, first: true);
      await clips.release();
      perf.markFirstFrame();
      expect(perf.samples, isEmpty);
    });
  });

  group('audio focus and keep-screen-on (V2-22)', () {
    late List<bool> wake;

    setUp(() {
      wake = [];
      clips = ClipPlayer(
        engine: () => engine,
        wakelock: WakelockController(platformToggle: (on) async => wake.add(on)),
      );
    });

    int count(String call) => engine.calls.where((c) => c == call).length;

    test('takes the focus once per session and gives it back on release, before the core goes', () async {
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      await clips.play(_b);
      await clips.pause();
      await clips.resume();
      await clips.replay();
      expect(count('requestAudioFocus'), 1);
      expect(engine.calls.indexOf('requestAudioFocus'), lessThan(engine.calls.indexOf('open ${_a.uri}')));

      await clips.release();
      final abandon = engine.calls.indexOf('abandonAudioFocus');
      expect(abandon, greaterThanOrEqualTo(0));
      expect(abandon, lessThan(engine.calls.indexOf('dispose')));

      // The next session asks again.
      await clips.play(_a, first: true);
      expect(count('requestAudioFocus'), 2);
    });

    test('a muted session takes no focus until the first unmute', () async {
      clips = ClipPlayer(engine: () => engine, muted: true);
      expect(clips.muted, isTrue);
      await clips.play(_a, first: true);
      engine.firstFrameCtl.add(null);
      expect(count('requestAudioFocus'), 0);
      expect(clips.level, 0);

      await clips.setMuted(false);
      expect(count('requestAudioFocus'), 1);

      // Nothing was asked of a session that never took it.
      final quiet = FakeClipEngine();
      final muted = ClipPlayer(engine: () => quiet, muted: true);
      await muted.play(_b, first: true);
      await muted.release();
      expect(quiet.calls, isNot(contains('abandonAudioFocus')));
    });

    test('a refused focus is asked for again on the next resume', () async {
      engine.grantFocus = false;
      await clips.play(_a, first: true);
      await Future<void>.delayed(Duration.zero);
      engine.firstFrameCtl.add(null);
      engine.grantFocus = true;
      await clips.pause();
      await clips.resume();
      expect(count('requestAudioFocus'), 2);
    });

    test('a stop the Reel did not ask for reads as paused; the focus coming back plays on', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.flushMicrotasks();
        engine.firstFrameCtl.add(null);
        engine.playingCtl.add(true);
        expect(clips.phase.value, ClipPhase.playing);

        // A call takes the focus: the core stops by itself.
        engine.playingCtl.add(false);
        async.elapse(ClipPlayer.externalPauseGrace ~/ 2);
        expect(clips.phase.value, ClipPhase.playing);
        async.elapse(ClipPlayer.externalPauseGrace);
        expect(clips.phase.value, ClipPhase.paused);
        expect(clips.keepsScreenOn, isFalse);

        // The call ends and the system hands the focus back.
        engine.playingCtl.add(true);
        expect(clips.phase.value, ClipPhase.playing);
        expect(clips.keepsScreenOn, isTrue);
        expect(engine.calls.last, isNot('pause'));
      });
    });

    test('after a system pause, OK resumes and asks for the focus again', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.flushMicrotasks();
        engine.firstFrameCtl.add(null);
        engine.playingCtl.add(true);
        engine.playingCtl.add(false);
        async.elapse(ClipPlayer.externalPauseGrace * 2);
        expect(clips.phase.value, ClipPhase.paused);

        clips.togglePause();
        async.flushMicrotasks();
        expect(clips.phase.value, ClipPhase.playing);
        expect(count('requestAudioFocus'), 2);
      });
    });

    test('a stall, a loop, an error and the viewer\'s own pause are not system pauses', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.flushMicrotasks();
        engine.firstFrameCtl.add(null);
        engine.playingCtl.add(true);

        // A stall.
        engine.bufferingCtl.add(true);
        engine.playingCtl.add(false);
        async.elapse(ClipPlayer.externalPauseGrace * 2);
        expect(clips.phase.value, ClipPhase.playing);
        engine.bufferingCtl.add(false);
        engine.playingCtl.add(true);

        // The end of the first loop, before the seek back plays.
        engine.completedCtl.add(true);
        engine.playingCtl.add(false);
        async.elapse(ClipPlayer.externalPauseGrace * 2);
        expect(clips.phase.value, ClipPhase.playing);
        engine.playingCtl.add(true);

        // An error stops the core just before it says why.
        engine.playingCtl.add(false);
        engine.errorCtl.add(const PlayerError('decode failed'));
        async.elapse(ClipPlayer.externalPauseGrace * 2);
        expect(clips.phase.value, ClipPhase.failed);
      });
    });

    test('a returning focus does not override the viewer\'s pause or a hold', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.flushMicrotasks();
        engine.firstFrameCtl.add(null);
        engine.playingCtl.add(true);
        clips.pause();
        async.flushMicrotasks();
        engine.playingCtl.add(false);
        async.elapse(ClipPlayer.externalPauseGrace * 2);
        expect(clips.phase.value, ClipPhase.paused);

        engine.calls.clear();
        engine.playingCtl.add(true);
        async.flushMicrotasks();
        expect(engine.calls, ['pause']);
        expect(clips.phase.value, ClipPhase.paused);
      });
    });

    test('keeps the screen on only while a clip opens or plays', () async {
      await clips.play(_a, first: true);
      expect(clips.keepsScreenOn, isTrue);
      engine.firstFrameCtl.add(null);
      expect(clips.keepsScreenOn, isTrue);

      await clips.pause();
      expect(clips.keepsScreenOn, isFalse);
      await clips.resume();
      expect(clips.keepsScreenOn, isTrue);

      // Held on the last frame: the screensaver may come in.
      engine.completedCtl.add(true);
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(clips.phase.value, ClipPhase.held);
      expect(clips.keepsScreenOn, isFalse);

      await clips.replay();
      expect(clips.keepsScreenOn, isTrue);
      engine.errorCtl.add(const PlayerError('decode failed'));
      expect(clips.keepsScreenOn, isFalse);

      await clips.play(_b);
      await clips.release();
      expect(clips.keepsScreenOn, isFalse);
      await Future<void>.delayed(Duration.zero);
      // The platform sees the requests coalesced (WakelockController), on
      // first and off last.
      expect(wake.first, isTrue);
      expect(wake.last, isFalse);
    });
  });
}
