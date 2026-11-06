import 'dart:convert';
import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/feed_players.dart';
import 'package:plezy/services/reel/reel_perf.dart';

/// A frame with [build] and [raster] µs of work and [span] µs from vsync to
/// raster finish.
FrameTiming _frame({required int build, required int raster, int? span}) {
  final total = span ?? build + raster;
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: build,
    rasterStart: total - raster,
    rasterFinish: total,
    rasterFinishWallTime: total,
  );
}

class _Video extends ChangeNotifier implements FeedVideo {
  bool _ready = false;
  bool _playing = false;
  Duration _position = Duration.zero;

  @override
  bool get ready => _ready;
  @override
  bool get failed => false;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Duration get position => _position;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  bool get playing => _playing;
  @override
  Duration get buffered => _ready ? duration : Duration.zero;

  @override
  Future<void> initialize() async => _ready = true;
  @override
  Future<void> play() async => _playing = true;
  @override
  Future<void> pause() async => _playing = false;
  @override
  Future<void> seekTo(Duration position) async => _position = position;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  bool get completed => false;
  @override
  Future<void> setLooping(bool looping) async {}

  void tick(Duration to) {
    _position = to;
    notifyListeners();
  }

  @override
  Future<void> dispose() async => super.dispose();

  @override
  Widget view() => const SizedBox();
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Duration now;
  late ReelPerf perf;
  late Map<String, String> ring;

  setUp(() {
    now = Duration.zero;
    ring = {};
    perf = ReelPerf(now: () => now, clock: () => DateTime.utc(2026, 1, 2, 20))
      ..recording = true
      ..ring = (read: (k) async => ring[k], write: (k, v) async => ring[k] = v);
  });

  void at(int ms) => now = Duration(milliseconds: ms);

  test('a key press to first frame is one sample with consecutive splits', () {
    perf.begin(ReelPerfTrigger.key);
    at(20);
    perf.markResolved(preloaded: true, origin: 'plexExtra');
    at(60);
    perf.markOpened();
    at(90);
    perf.markDecoder();
    at(150);
    perf.markFirstFrame();

    final s = perf.last!;
    expect(s.trigger, ReelPerfTrigger.key);
    expect([s.totalMs, s.resolveMs, s.openMs, s.decoderMs, s.renderMs], [150, 20, 40, 30, 60]);
    expect(s.preloaded, isTrue);
    expect(
      s.logLine(),
      startsWith('[ReelPerf] key=150ms resolve=20 open=40 decoder=30 render=60 preload=hit origin=plexExtra frames=0'),
    );
  });

  test('without a decoder line, render runs from the open', () {
    perf.begin(ReelPerfTrigger.swipe);
    at(10);
    perf.markResolved(preloaded: false);
    at(30);
    perf.markOpened();
    at(100);
    perf.markFirstFrame();
    final s = perf.last!;
    expect([s.resolveMs, s.openMs, s.decoderMs, s.renderMs], [10, 20, null, 70]);
    expect(s.logLine(), contains('preload=miss'));
    expect(s.logLine(), isNot(contains('decoder=')));
  });

  test('the native preload line outranks the Dart-side guess', () {
    perf.begin(ReelPerfTrigger.key);
    perf.markResolved(preloaded: true);
    perf.markPreloaded(false);
    perf.markFirstFrame();
    expect(perf.last!.preloaded, isFalse);
  });

  test('records nothing while not recording (the default release state)', () {
    final off = ReelPerf(now: () => now);
    off.begin(ReelPerfTrigger.key);
    off.markResolved();
    off.markFirstFrame();
    expect(off.samples, isEmpty);
  });

  test('a clip opened with no press pending is an open of the Reel', () {
    at(1000);
    perf.markResolved();
    at(1400);
    perf.markFirstFrame();
    expect(perf.last!.trigger, ReelPerfTrigger.open);
    expect(perf.last!.totalMs, 400);
  });

  test('a press left over from another visit is not counted', () {
    perf.begin(ReelPerfTrigger.key);
    at(60000);
    perf.markResolved();
    at(60200);
    perf.markFirstFrame();
    expect(perf.last!.trigger, ReelPerfTrigger.open);
    expect(perf.last!.totalMs, 200);
  });

  test('cancel drops the change; a new press replaces an unfinished one', () {
    perf.begin(ReelPerfTrigger.key);
    perf.cancel();
    perf.markFirstFrame();
    expect(perf.samples, isEmpty);

    perf.begin(ReelPerfTrigger.key);
    at(500);
    perf.begin(ReelPerfTrigger.deck);
    at(800);
    perf.markResolved();
    perf.markFirstFrame();
    expect(perf.samples.single.trigger, ReelPerfTrigger.deck);
    expect(perf.samples.single.totalMs, 300);
  });

  test('medians are per trigger and the hit rate leaves opens out', () {
    void sample(ReelPerfTrigger t, int ms, {bool? preloaded}) {
      perf.begin(t);
      final start = now;
      perf.markResolved(preloaded: preloaded);
      now = start + Duration(milliseconds: ms);
      perf.markFirstFrame();
    }

    sample(ReelPerfTrigger.open, 1800, preloaded: false);
    sample(ReelPerfTrigger.key, 100, preloaded: true);
    sample(ReelPerfTrigger.key, 300, preloaded: true);
    sample(ReelPerfTrigger.key, 200, preloaded: false);
    sample(ReelPerfTrigger.deck, 900, preloaded: false);

    expect(perf.p50((s) => s.totalMs, trigger: ReelPerfTrigger.key), 200);
    expect(perf.p50((s) => s.totalMs, trigger: ReelPerfTrigger.open), 1800);
    expect(perf.p50((s) => s.decoderMs, trigger: ReelPerfTrigger.key), isNull);
    expect(perf.preloadHits, (hits: 2, of: 4));
  });

  test('the ring keeps the last 200 cards in perf:000..perf:199', () async {
    for (var i = 0; i < 205; i++) {
      perf.begin(ReelPerfTrigger.swipe);
      perf.markResolved();
      perf.markFirstFrame();
    }
    await perf.flushed;
    expect(ring.keys.where((k) => k != ReelPerf.ringSeqKey), hasLength(ReelPerf.ringSize));
    expect(ring[ReelPerf.ringSeqKey], '205');
    expect((jsonDecode(ring['perf:004']!) as Map)['seq'], 204);
    expect((jsonDecode(ring['perf:005']!) as Map)['seq'], 5);
    expect((jsonDecode(ring['perf:004']!) as Map)['t'], 'swipe');
  });

  test('the ring carries on from the stored sequence', () async {
    ring[ReelPerf.ringSeqKey] = '199';
    perf.begin(ReelPerfTrigger.key);
    perf.markResolved();
    perf.markFirstFrame();
    perf.begin(ReelPerfTrigger.key);
    perf.markResolved();
    perf.markFirstFrame();
    await perf.flushed;
    expect((jsonDecode(ring['perf:199']!) as Map)['seq'], 199);
    expect((jsonDecode(ring['perf:000']!) as Map)['seq'], 200);
    expect(ring[ReelPerf.ringSeqKey], '201');
  });

  test('frames over budget, dropped vsyncs and the p95', () {
    const budget = Duration(microseconds: 16667);
    perf.begin(ReelPerfTrigger.key);
    perf.onFrames([
      _frame(build: 4000, raster: 5000),
      _frame(build: 9000, raster: 9000, span: 20000),
      _frame(build: 30000, raster: 6000, span: 40000),
    ], budget: budget);
    expect(perf.frames, 3);
    expect(perf.framesOver, 2);
    // Pipelined: 9 + 9 ms over a 20 ms span misses nothing; a 30 ms build
    // misses one vsync.
    expect(perf.framesDropped, 1);
    expect(perf.frameP95, 36);

    perf.markResolved();
    perf.markFirstFrame();
    final s = perf.last!;
    expect([s.frames, s.framesOver], [3, 2]);
    expect(s.worstFrameMs, 36);

    perf.resetFrames();
    expect([perf.frames, perf.framesOver, perf.framesDropped], [0, 0, 0]);
    expect(perf.frameP95, isNull);
  });

  test('the frame budget is one vsync of the display', () {
    expect(ReelPerf.budgetFor(60).inMicroseconds, 16667);
    expect(ReelPerf.budgetFor(120).inMicroseconds, 8333);
    expect(ReelPerf.budgetFor(0).inMicroseconds, 16667);
  });

  group('phone feed probe', () {
    late Map<String, _Video> made;
    late ReelFeedPlayers players;
    late ReelFeedProbe probe;
    var deck = 'deck-a';

    FeedClip clip(String id, [int offset = 0]) =>
        (id: id, uri: Uri.parse('https://cdn.example/$id.mp4'), offset: offset);

    setUp(() {
      made = {};
      deck = 'deck-a';
      players = ReelFeedPlayers(create: (uri) => made[uri.pathSegments.last.split('.').first] = _Video());
      probe = ReelFeedProbe(players, perf, deckId: () => deck, origin: () => 'plexExtra');
    });

    tearDown(() {
      probe.dispose();
      players.dispose();
    });

    test('the first card is an open; a swipe onto a parked player is a preload hit', () async {
      players.sync(current: 'a', window: [clip('a'), clip('b', 1)]);
      at(40);
      await _settle();
      at(120);
      made['a']!.tick(const Duration(milliseconds: 100));
      expect(perf.last!.trigger, ReelPerfTrigger.open);
      expect(perf.last!.preloaded, isFalse);
      expect(perf.last!.totalMs, 120);

      at(1000);
      players.sync(current: 'b', window: [clip('b'), clip('a', -1)]);
      await _settle();
      // Parked at 0 and playing, but no picture moved yet.
      expect(perf.samples, hasLength(1));
      at(1090);
      made['b']!.tick(const Duration(milliseconds: 80));
      final s = perf.last!;
      expect(s.trigger, ReelPerfTrigger.swipe);
      expect(s.preloaded, isTrue);
      expect(s.resolveMs, 0);
      expect(s.totalMs, 90);
      expect(s.origin, 'plexExtra');
    });

    test('a new deck is a deck switch, and a release starts over with an open', () async {
      players.sync(current: 'a', window: [clip('a')]);
      await _settle();
      made['a']!.tick(const Duration(milliseconds: 100));

      deck = 'deck-b';
      players.sync(current: 'c', window: [clip('c')]);
      await _settle();
      made['c']!.tick(const Duration(milliseconds: 100));
      expect(perf.last!.trigger, ReelPerfTrigger.deck);

      await players.releaseAll();
      players.sync(current: 'c', window: [clip('c')]);
      await _settle();
      made['c']!.tick(const Duration(milliseconds: 100));
      expect(perf.last!.trigger, ReelPerfTrigger.open);
      expect(perf.samples, hasLength(3));
    });

    test('a screen switch is a fold sample: same card, timed to its picture moving again', () async {
      players.sync(current: 'a', window: [clip('a'), clip('b', 1)]);
      await _settle();
      made['a']!.tick(const Duration(seconds: 2));
      expect(perf.samples, hasLength(1));

      at(5000);
      probe.screenChanged();
      at(5100);
      made['a']!.tick(const Duration(seconds: 2));
      expect(perf.samples, hasLength(1), reason: 'the picture has not moved yet');
      at(5240);
      made['a']!.tick(const Duration(seconds: 2, milliseconds: 100));
      final s = perf.last!;
      expect(s.trigger, ReelPerfTrigger.fold);
      expect(s.totalMs, 240);
      expect(s.preloaded, isTrue);
      expect(s.origin, 'plexExtra');
      expect(s.logLine(), startsWith('[ReelPerf] fold=240ms'));

      // The next swipe is a swipe again.
      players.sync(current: 'b', window: [clip('b'), clip('a', -1)]);
      await _settle();
      made['b']!.tick(const Duration(milliseconds: 80));
      expect(perf.last!.trigger, ReelPerfTrigger.swipe);
    });

    test('a screen switch before the card has a picture waits for it', () async {
      at(0);
      players.sync(current: 'a', window: [clip('a')]);
      probe.screenChanged();
      expect(perf.samples, isEmpty);
      await _settle();
      at(300);
      made['a']!.tick(const Duration(milliseconds: 100));
      expect(perf.last!.trigger, ReelPerfTrigger.fold);
      expect(perf.last!.totalMs, 300);
    });

    test('a screen switch with nothing on screen records nothing', () {
      probe.screenChanged();
      at(100);
      expect(perf.samples, isEmpty);
    });
  });
}
