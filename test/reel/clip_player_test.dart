// The fake engine's controllers are closed in tearDown.
// ignore_for_file: close_sinks
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/reel/clip_player.dart';

class FakeClipEngine implements ClipEngine {
  final calls = <String>[];
  final completedCtl = StreamController<bool>.broadcast(sync: true);
  final firstFrameCtl = StreamController<void>.broadcast(sync: true);
  final errorCtl = StreamController<PlayerError>.broadcast(sync: true);
  final volumes = <double>[];
  bool disposed = false;
  Completer<void>? disposeGate;

  @override
  Player get player => throw UnimplementedError();

  @override
  Future<void> open(String uri) async => calls.add('open $uri');

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
  Duration position = const Duration(seconds: 20);

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

  test('the first clip fades in from silence; later cards dip from 30%', () {
    fakeAsync((async) {
      clips.play(_a, first: true);
      async.flushMicrotasks();
      expect(engine.volumes.first, 0);
      async.elapse(const Duration(milliseconds: 700));
      expect(engine.volumes.last, closeTo(100, 0.01));

      engine.volumes.clear();
      clips.play(_b);
      async.elapse(const Duration(milliseconds: 300));
      expect(engine.volumes.any((v) => v.abs() < 0.01), isTrue, reason: 'the outgoing clip fades out to silence');
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 400));
      expect(engine.volumes, contains(30));
      expect(engine.volumes.last, closeTo(100, 0.01));
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
}
