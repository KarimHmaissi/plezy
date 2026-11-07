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
  final leadInCtl = StreamController<ClipLeadIn>.broadcast(sync: true);
  final volumes = <double>[];

  /// V2-23: the start and the measure flag each open and preload was sent,
  /// by `open <uri>` / `preload <uri>`, and every lead-in policy sent.
  final startAts = <String, Duration?>{};
  final measures = <String, bool>{};
  final leadInPolicies = <({bool enabled, bool measureOnly})>[];

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

  /// The disk cache key each open and preload was sent (V2-10), by
  /// `open <uri>` / `preload <uri>`.
  final cacheKeys = <String, String?>{};

  @override
  Future<void> warm() async {
    calls.add('warm');
    await warmGate?.future;
    final err = warmError;
    if (err != null) throw err;
  }

  @override
  Future<void> open(String uri, {String? cacheKey, Duration? startAt, bool measure = false, ClipOrigin? origin}) async {
    calls.add('open $uri');
    cacheKeys['open $uri'] = cacheKey;
    startAts['open $uri'] = startAt;
    measures['open $uri'] = measure;
    await openGate?.future;
  }

  /// `preload <uri>` for the next card; other ranks say theirs (V2-09).
  @override
  Future<void> preload(
    String uri, {
    ClipPreloadRank rank = ClipPreloadRank.next,
    ClipOrigin? origin,
    String? cacheKey,
    Duration? startAt,
    bool measure = false,
  }) async {
    cacheKeys['preload $uri'] = cacheKey;
    startAts['preload $uri'] = startAt;
    measures['preload $uri'] = measure;
    calls.add(rank == ClipPreloadRank.next ? 'preload $uri' : 'preload $uri as ${rank.name}');
  }

  @override
  Future<void> clearPreloads({ClipPreloadRank? rank}) async =>
      calls.add(rank == null ? 'clearPreloads' : 'clearPreloads ${rank.name}');

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
  Future<void> seekExact(Duration position) async => calls.add('seekExact ${position.inMilliseconds}');

  @override
  Future<void> setLeadInPolicy({required bool enabled, required bool measureOnly}) async =>
      leadInPolicies.add((enabled: enabled, measureOnly: measureOnly));

  @override
  Stream<ClipLeadIn> get leadIns => leadInCtl.stream;

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
  Future<void> setNormalization(bool on) async => calls.add('normalization $on');

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
  Future<void> open(String uri, {String? cacheKey, Duration? startAt, bool measure = false, ClipOrigin? origin}) async {
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

/// A core whose normalisation call fails (no effect on the device).
class _NoNormalizationEngine extends FakeClipEngine {
  @override
  Future<void> setNormalization(bool on) async {
    calls.add('normalization $on');
    throw PlatformException(code: 'effect', message: 'no loudness effect');
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
    await engine.leadInCtl.close();
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
      // Held as the card behind: an open of another clip leaves it there.
      await clips.preload(_b, rank: ClipPreloadRank.previous);
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
        matches(
          RegExp(
            r'^\[ReelTTFF\] key=\d+ms open=\d+ms preloaded=true rank=previous trigger=step origin=animeTheme lead=0$',
          ),
        ),
      );
      expect(
        lines.last,
        matches(RegExp(r'^\[ReelTTFF\] key=none open=\d+ms preloaded=false rank=none origin=plexExtra lead=0$')),
      );
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
      expect(lines[1], contains('preloaded=true rank=next trigger=deck'));
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
    expect(engine.calls, ['preload ${_b.uri}', 'clearPreloads next']);
    expect(clips.preloaded, isEmpty);
  });

  test('a clip off a server marked slow is never preloaded (V2-11)', () async {
    await clips.preload(_a);
    await clips.preload(
      const ClipSource(uri: 'https://cdn.example/c.mp4', origin: ClipOrigin.plexExtra, preloadable: false),
    );
    expect(engine.calls, ['preload ${_a.uri}', 'clearPreloads next']);
  });

  group('preload ranks (V2-09)', () {
    const c = ClipSource(uri: 'https://v.example/c.webm', origin: ClipOrigin.animeTheme);

    test('each rank holds its own clip, and the same ask twice goes to the core once', () async {
      await clips.preload(_a);
      await clips.preload(_b, rank: ClipPreloadRank.previous);
      await clips.preload(c, rank: ClipPreloadRank.deckNext);
      await clips.preload(c, rank: ClipPreloadRank.deckNext);
      expect(engine.calls, ['preload ${_a.uri}', 'preload ${_b.uri} as previous', 'preload ${c.uri} as deckNext']);
      expect(clips.preloaded, {
        ClipPreloadRank.next: _a.uri,
        ClipPreloadRank.previous: _b.uri,
        ClipPreloadRank.deckNext: c.uri,
      });
    });

    test('a clip asked for at another rank moves there', () async {
      await clips.preload(c, rank: ClipPreloadRank.deckNext);
      await clips.preload(c);
      expect(clips.preloaded, {ClipPreloadRank.next: c.uri});
    });

    test('playing a held clip takes it out of its rank; the others stay', () async {
      await clips.preload(_a);
      await clips.preload(_b, rank: ClipPreloadRank.previous);
      await clips.play(_b);
      expect(clips.preloaded, {ClipPreloadRank.next: _a.uri});
    });

    test('clearing an empty rank asks nothing of the core', () async {
      await clips.preload(_a);
      engine.calls.clear();
      await clips.clearPreload(ClipPreloadRank.previous);
      await clips.clearPreload(ClipPreloadRank.next);
      expect(engine.calls, ['clearPreloads next']);
    });

    test('memory pressure drops every rank at once', () async {
      await clips.preload(_a);
      await clips.preload(_b, rank: ClipPreloadRank.deckPrevious);
      await clips.dropPreload();
      expect(engine.calls.last, 'clearPreloads');
      expect(clips.preloaded, isEmpty);
    });

    test('a release forgets every rank', () async {
      await clips.preload(_a);
      await clips.release();
      expect(clips.preloaded, isEmpty);
    });
  });

  group('disk cache (V2-10)', () {
    const key = 'plex:server-a:/library/parts/41/1700000000/file.mp4';
    const plex = ClipSource(
      uri: 'https://cdn.example/p.mp4?X-Plex-Token=abc123',
      origin: ClipOrigin.plexExtra,
      cacheKey: key,
    );

    test('a Plex clip opens and preloads with its cache key; an opening with none', () async {
      await clips.preload(plex);
      await clips.preload(_b, rank: ClipPreloadRank.previous);
      await clips.play(plex);
      await clips.play(_b);
      expect(engine.cacheKeys, {
        'preload ${plex.uri}': key,
        'preload ${_b.uri}': null,
        'open ${plex.uri}': key,
        'open ${_b.uri}': null,
      });
    });

    test('the card two ahead holds a Plex clip only (D1: an opening never goes to disk)', () async {
      await clips.preload(_b, rank: ClipPreloadRank.ahead);
      expect(engine.calls, isEmpty, reason: 'nothing held, so nothing to clear');
      expect(clips.preloaded, isEmpty);
      await clips.preload(_a, rank: ClipPreloadRank.ahead);
      expect(clips.preloaded, isEmpty, reason: 'a Plex clip without a key is not cached either');
      await clips.preload(plex, rank: ClipPreloadRank.ahead);
      expect(engine.calls, ['preload ${plex.uri} as ahead']);
      expect(clips.preloaded, {ClipPreloadRank.ahead: plex.uri});
      // Two steps later it is the next card: it moves, as the core rebuilds it in memory.
      await clips.preload(plex);
      expect(clips.preloaded, {ClipPreloadRank.next: plex.uri});
      expect(engine.calls.last, 'preload ${plex.uri}');
    });
  });

  group('unmute (V2-19)', () {
    test('rises from silence over the ramp instead of jumping to full', () {
      fakeAsync((async) {
        clips = ClipPlayer(engine: () => engine, muted: true);
        clips.play(_a, first: true);
        async.flushMicrotasks();
        engine.firstFrameCtl.add(null);
        async.elapse(const Duration(seconds: 1));
        expect(clips.level, 0);

        engine.volumes.clear();
        clips.setMuted(false);
        async.flushMicrotasks();
        expect(engine.volumes.where((v) => v >= 100), isEmpty, reason: 'no jump to full on the unmute');
        async.elapse(ClipPlayer.unmuteRamp ~/ 6);
        expect(engine.volumes.last, closeTo(100 / 6, 0.01));
        async.elapse(ClipPlayer.unmuteRamp);
        expect(clips.level, closeTo(100, 0.01));
        // Every step rises, and none by more than a sixth of the way.
        for (var i = 1; i < engine.volumes.length; i++) {
          expect(engine.volumes[i] - engine.volumes[i - 1], inInclusiveRange(0, 100 / 6 + 0.01));
        }
      });
    });

    test('mute is still at once, and cuts an unmute ramp short', () {
      fakeAsync((async) {
        clips = ClipPlayer(engine: () => engine, muted: true);
        clips.play(_a, first: true);
        async.flushMicrotasks();
        engine.firstFrameCtl.add(null);
        clips.setMuted(false);
        async.elapse(ClipPlayer.unmuteRamp ~/ 2);
        expect(clips.level, inExclusiveRange(0, 100));
        clips.setMuted(true);
        async.flushMicrotasks();
        expect(clips.level, 0);
        expect(engine.volumes.last, 0);
        async.elapse(ClipPlayer.unmuteRamp);
        expect(engine.volumes.last, 0, reason: 'the cancelled ramp sends nothing more');
      });
    });

    test('an unmute while a clip opens leaves the open its own ramp', () {
      fakeAsync((async) {
        clips = ClipPlayer(engine: () => engine, muted: true);
        engine.openGate = Completer<void>();
        clips.play(_a);
        async.flushMicrotasks();
        clips.setMuted(false);
        async.elapse(const Duration(milliseconds: 50));
        engine.openGate!.complete();
        async.flushMicrotasks();
        expect(clips.level, lessThanOrEqualTo(ClipPlayer.dipLevel));
        async.elapse(const Duration(seconds: 1));
        expect(clips.level, closeTo(100, 0.01));
      });
    });
  });

  group('loudness normalisation (V2-19, D9)', () {
    test('off by default: a core is never asked to normalise', () async {
      await clips.play(_a, first: true);
      await clips.play(_b);
      clips.syncNormalization();
      expect(engine.calls.where((c) => c.startsWith('normalization')), isEmpty);
    });

    test('switched on, each new core is told before its first open', () async {
      clips = ClipPlayer(engine: () => engine, normalize: () => true);
      await clips.play(_a, first: true);
      final told = engine.calls.indexOf('normalization true');
      expect(told, isNonNegative);
      expect(told, lessThan(engine.calls.indexOf('open ${_a.uri}')));
      await clips.play(_b);
      expect(engine.calls.where((c) => c == 'normalization true'), hasLength(1), reason: 'once per core');

      await clips.release();
      engine.calls.clear();
      await clips.play(_a, first: true);
      expect(engine.calls, contains('normalization true'), reason: 'a rebuilt core starts off again');
    });

    test('a flip reaches the core in use at once, and only when it changed', () async {
      var on = false;
      clips = ClipPlayer(engine: () => engine, normalize: () => on);
      await clips.play(_a, first: true);
      on = true;
      clips.syncNormalization();
      clips.syncNormalization();
      on = false;
      clips.syncNormalization();
      expect(engine.calls.where((c) => c.startsWith('normalization')), ['normalization true', 'normalization false']);

      // A flip with no core waits for the next core.
      await clips.release();
      on = true;
      clips.syncNormalization();
      expect(engine.calls.where((c) => c.startsWith('normalization')), hasLength(2));
    });

    test('the next card picks up a flip the settings listener missed', () async {
      var on = false;
      clips = ClipPlayer(engine: () => engine, normalize: () => on);
      await clips.play(_a, first: true);
      on = true;
      await clips.play(_b);
      final told = engine.calls.indexOf('normalization true');
      expect(told, isNonNegative);
      expect(told, lessThan(engine.calls.indexOf('open ${_b.uri}')));
    });

    test('a core that throws on the switch never breaks the card', () async {
      final refusing = _NoNormalizationEngine();
      engine = refusing;
      clips = ClipPlayer(engine: () => refusing, normalize: () => true);
      await clips.play(_a, first: true);
      await Future<void>.delayed(Duration.zero);
      expect(refusing.calls, contains('open ${_a.uri}'));
      expect(clips.phase.value, ClipPhase.loading);
    });
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
      engine.logCtl.add(log('clip', 'Open clip: preloaded=true rank=next held=[previous] sources=2'));
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

    test("the core's own line wins: a miss it reports with its rank is a miss", () async {
      await clips.preload(_b);
      perf.begin(ReelPerfTrigger.key);
      final playing = clips.play(_b, first: true);
      engine.logCtl.add(log('clip', 'Open clip: preloaded=false rank=next held=[] sources=1'));
      await playing;
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

  group('turning the sound on never jumps to full', () {
    test('it rises from silence over the unmute ramp, step by step, to the full level', () {
      fakeAsync((async) {
        clips = ClipPlayer(engine: () => engine, muted: true);
        clips.play(_a, first: true);
        async.elapse(const Duration(seconds: 1));
        expect(clips.level, 0);
        engine.volumes.clear();

        clips.setMuted(false);
        async.flushMicrotasks();
        expect(engine.volumes.where((v) => v > 0), isEmpty, reason: 'nothing audible before the first step');

        async.elapse(ClipPlayer.unmuteRamp ~/ 2);
        expect(clips.level, greaterThan(0));
        expect(clips.level, lessThan(100));

        async.elapse(ClipPlayer.unmuteRamp);
        expect(clips.level, 100);
        expect(engine.volumes.first, lessThan(ClipPlayer.dipLevel));
        expect(engine.volumes, orderedEquals([...engine.volumes]..sort()));
        expect(engine.volumes.length, greaterThan(3));
      });
    });

    test('muting is immediate, and unmuting a clip that has its sound changes nothing', () {
      fakeAsync((async) {
        clips.play(_a, first: true);
        async.elapse(const Duration(seconds: 1));
        expect(clips.level, 100);
        engine.volumes.clear();
        clips.setMuted(false);
        async.elapse(const Duration(seconds: 1));
        expect(engine.volumes, isEmpty);

        clips.setMuted(true);
        expect(clips.level, 0);
        expect(engine.volumes.last, 0);
      });
    });
  });
  group('V2-23: lead-in skip', () {
    const key = 'plex:server-a:/library/parts/41/1700000000/file.mp4';
    const measured = ClipSource(
      uri: 'https://server-a.example/library/parts/41/1700000000/file.mp4',
      origin: ClipOrigin.plexExtra,
      cacheKey: key,
      length: Duration(seconds: 120),
      startAt: Duration(milliseconds: 6006),
    );
    final unmeasured = measured.withStartAt(null);
    const opening = ClipSource(
      uri: 'https://v.example/harbor-lights-op1.webm',
      origin: ClipOrigin.animeTheme,
      startAt: Duration(milliseconds: 6006),
    );

    test('a measured Plex trailer opens and preloads at its start, and may be measured', () async {
      await clips.preload(unmeasured);
      expect(engine.startAts['preload ${measured.uri}'], isNull, reason: 'unknown, never "from 0"');
      expect(engine.measures['preload ${measured.uri}'], isTrue);
      await clips.play(measured);
      expect(engine.startAts['open ${measured.uri}'], const Duration(milliseconds: 6006));
      expect(engine.measures['open ${measured.uri}'], isTrue);
    });

    test('an AnimeThemes opening is never cut nor measured', () async {
      await clips.preload(opening);
      await clips.play(opening);
      expect(engine.startAts['preload ${opening.uri}'], isNull);
      expect(engine.measures['preload ${opening.uri}'], isFalse);
      expect(engine.startAts['open ${opening.uri}'], isNull);
      expect(engine.measures['open ${opening.uri}'], isFalse);
    });

    test('a preload is sent again when only its start changed', () async {
      await clips.preload(unmeasured);
      await clips.preload(unmeasured);
      expect(engine.calls.where((c) => c == 'preload ${measured.uri}'), hasLength(1));
      await clips.preload(measured);
      expect(engine.calls.where((c) => c == 'preload ${measured.uri}'), hasLength(2));
      expect(engine.startAts['preload ${measured.uri}'], const Duration(milliseconds: 6006));
    });

    test('Replay and the loop go to 0 after a clipped open: 0 is the cut', () async {
      await clips.play(measured);
      engine.firstFrameCtl.add(null);
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      await clips.replay();
      expect(engine.calls.where((c) => c.startsWith('seek')), ['seek 0', 'seek 0']);
      expect(clips.restartAt, Duration.zero);
    });

    test('a start learned after an unclipped open: Replay and the loop seek exactly to it', () async {
      await clips.play(unmeasured);
      engine.firstFrameCtl.add(null);
      final heard = <ClipLeadIn>[];
      clips.leadIns.listen(heard.add);
      engine.leadInCtl.add(
        const ClipLeadIn(cacheKey: key, start: Duration(milliseconds: 6006), playingUnclipped: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(heard.single.start, const Duration(milliseconds: 6006));
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      await clips.replay();
      expect(engine.calls.where((c) => c.startsWith('seek')), ['seekExact 6006', 'seekExact 6006']);
      // RW never goes back into the lead-in.
      engine.position = const Duration(seconds: 8);
      await clips.seekBy(const Duration(seconds: -10));
      expect(engine.calls.last, 'seekExact 6006');
    });

    test('an answer that raced ahead of the open (the core opened it clipped) never moves Replay', () async {
      // Dart sent the open before it heard the answer, so it opened with no
      // start; the core had the answer first and clipped the open (R7).
      await clips.play(unmeasured);
      engine.firstFrameCtl.add(null);
      engine.leadInCtl.add(const ClipLeadIn(cacheKey: key, start: Duration(milliseconds: 6006)));
      await Future<void>.delayed(Duration.zero);
      expect(clips.restartAt, Duration.zero);
      engine.completedCtl.add(true);
      await Future<void>.delayed(Duration.zero);
      await clips.replay();
      expect(engine.calls.where((c) => c.startsWith('seek')), ['seek 0', 'seek 0']);
    });

    test('a clipped open counts its length from the cut', () async {
      await clips.play(measured);
      engine.firstFrameCtl.add(null);
      expect(clips.progress.value.length, const Duration(milliseconds: 120000 - 6006));
    });

    test('with Skip trailer intros off nothing is cut, and the core is told', () async {
      clips = ClipPlayer(engine: () => engine, skipIntros: () => false);
      await clips.play(measured);
      engine.firstFrameCtl.add(null);
      expect(engine.leadInPolicies.single, (enabled: false, measureOnly: false));
      expect(engine.measures['open ${measured.uri}'], isFalse);
      expect(clips.progress.value.length, const Duration(seconds: 120));
      expect(clips.cutsLeadIns, isFalse);
    });

    test('measure-only measures but never cuts', () async {
      clips = ClipPlayer(engine: () => engine, leadInMeasureOnly: () => true);
      await clips.play(measured);
      engine.firstFrameCtl.add(null);
      expect(engine.leadInPolicies.single, (enabled: true, measureOnly: true));
      expect(engine.measures['open ${measured.uri}'], isTrue);
      expect(clips.progress.value.length, const Duration(seconds: 120));
      expect(clips.cutsLeadIns, isFalse);
    });

    test('a policy change reaches the core once', () async {
      var on = true;
      clips = ClipPlayer(engine: () => engine, skipIntros: () => on);
      await clips.play(measured);
      clips.syncLeadInPolicy();
      on = false;
      clips.syncLeadInPolicy();
      clips.syncLeadInPolicy();
      await Future<void>.delayed(Duration.zero);
      expect(engine.leadInPolicies, [(enabled: true, measureOnly: false), (enabled: false, measureOnly: false)]);
    });

    test('[ReelTTFF] says the lead-in it opened with', () async {
      MemoryLogOutput.clearLogs();
      await clips.play(measured);
      engine.firstFrameCtl.add(null);
      await clips.play(unmeasured);
      engine.firstFrameCtl.add(null);
      final lines = MemoryLogOutput.getLogs().map((e) => e.message).where((m) => m.startsWith('[ReelTTFF]')).toList();
      expect(lines[1], endsWith('lead=6006'));
      expect(lines[0], endsWith('lead=?'));
    });
  });
}
