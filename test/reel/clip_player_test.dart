// The fake engine's controllers are closed in tearDown.
// ignore_for_file: close_sinks
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/reel/clip_player.dart';
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
  final volumes = <double>[];
  bool disposed = false;
  Completer<void>? disposeGate;

  /// Holds every open until completed (a slow, or never-finishing, open).
  Completer<void>? openGate;

  @override
  Player get player => throw UnimplementedError();

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
  Future<void> pause() async => calls.add('pause');

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
  Future<void> dispose() async {
    calls.add('dispose');
    await disposeGate?.future;
    disposed = true;
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

  test('preloads the next card on the same core, or clears it', () async {
    await clips.preload(_b);
    await clips.preload(null);
    expect(engine.calls, ['preload ${_b.uri}', 'clearPreloads']);
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
}
