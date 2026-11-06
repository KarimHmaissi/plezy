import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_prefetcher.dart';

void main() {
  late ReelPrefetcher q;
  late List<String> started;
  late Map<String, Completer<void>> gates;

  setUp(() {
    q = ReelPrefetcher();
    started = [];
    gates = {};
  });

  tearDown(() => q.dispose());

  /// A task that records when it starts and finishes when the test says.
  ReelPrefetchTask task(
    String card,
    int offset, {
    ReelPrefetchStage stage = ReelPrefetchStage.resolve,
    String lane = 'Server A',
  }) => ReelPrefetchTask(
    cardId: card,
    offset: offset,
    stage: stage,
    lane: lane,
    run: () {
      final key = '$card/${stage.name}';
      started.add(key);
      return (gates[key] = Completer<void>()).future;
    },
  );

  /// Lets the task under [key] finish, then lets the queue move on.
  Future<void> finish(String key) async {
    gates[key]!.complete();
    await pumpEventQueue();
  }

  /// The window around card c3: two cards ahead, one behind, each with its
  /// art and text after its clip.
  List<ReelPrefetchTask> window() => [
    for (final (card, offset) in [('c5', 2), ('c2', -1), ('c4', 1), ('c3', 0)])
      for (final stage in ReelPrefetchStage.values) task(card, offset, stage: stage),
  ];

  test('the card on screen starts at once; the rest go nearest first, clip before art', () async {
    q.schedule(1, window());
    expect(started, ['c3/resolve', 'c3/metadata'], reason: 'lookahead waits while the server is busy');

    for (final key in ['c3/resolve', 'c3/metadata', 'c4/resolve', 'c4/metadata', 'c2/resolve', 'c2/metadata']) {
      await finish(key);
    }
    expect(started, [
      'c3/resolve',
      'c3/metadata',
      'c4/resolve',
      'c4/metadata',
      'c2/resolve',
      'c2/metadata',
      'c5/resolve',
    ], reason: 'one lookahead task at a time per server');
  });

  test('AnimeThemes has its own lane, so an opening never waits behind a server read', () async {
    q.schedule(1, [
      task('c3', 0),
      task('c4', 1),
      task('c5', 2, lane: ReelPrefetcher.animeThemesLane),
      task('c2', -1, lane: 'Server B'),
    ]);
    expect(started, ['c3/resolve', 'c2/resolve', 'c5/resolve'], reason: 'c4 waits for c3 on Server A');
  });

  test('a new window drops what it no longer asks for; a running task finishes', () async {
    q.schedule(1, window());
    await finish('c3/resolve');
    await finish('c3/metadata');
    expect(started.last, 'c4/resolve');
    final dropped = q.done('c2/resolve');
    final kept = q.done('c5/resolve');

    // Two steps on: c5 is on screen, c4 behind it, c6 and c7 ahead.
    q.schedule(2, [task('c5', 0), task('c6', 1), task('c4', -1), task('c7', 2)]);
    expect(await dropped, isFalse);
    expect(started.last, 'c5/resolve', reason: 'the new card on screen starts at once');

    await finish('c4/resolve');
    await finish('c5/resolve');
    expect(await kept, isTrue);
    expect(started.last, 'c6/resolve', reason: 'nearest first once the server is free');
    expect(started, isNot(contains('c2/resolve')));
    expect(started.where((k) => k == 'c4/resolve'), hasLength(1), reason: 'a running task is never doubled');
  });

  test('a window from an older generation is ignored', () async {
    q.schedule(3, [task('c3', 0), task('c4', 1, lane: 'Server B')]);
    final stale = task('c9', 1, lane: 'Server C');
    q.schedule(2, [stale]);
    expect(await q.done('c9/resolve'), isTrue, reason: 'no such task queued');
    expect(started, ['c3/resolve', 'c4/resolve']);
  });

  test('a queued task moved to a new distance keeps whoever waits on it', () async {
    q.schedule(1, [task('c3', 0), task('c4', 1), task('c5', 2)]);
    final waiting = q.done('c5/resolve');
    q.schedule(2, [task('c4', 0), task('c5', 1)]);
    expect(q.queued.single.offset, 1);
    await finish('c3/resolve');
    await finish('c4/resolve');
    expect(started.last, 'c5/resolve');
    await finish('c5/resolve');
    expect(await waiting, isTrue);
  });

  test('held: only the card on screen runs until its clip shows a frame', () async {
    q.hold();
    q.schedule(1, [task('c3', 0), task('c4', 1, lane: 'Server B'), task('c5', 2, lane: 'Server C')]);
    expect(started, ['c3/resolve']);
    q.release();
    expect(started, ['c3/resolve', 'c4/resolve', 'c5/resolve']);
  });

  test('a hold lifts by itself after its cap', () {
    fakeAsync((async) {
      final capped = ReelPrefetcher(holdCap: const Duration(seconds: 4));
      capped
        ..hold()
        ..schedule(1, [task('c3', 0), task('c4', 1, lane: 'Server B')]);
      async.elapse(const Duration(seconds: 3));
      expect(started, ['c3/resolve']);
      async.elapse(const Duration(seconds: 2));
      expect(started, ['c3/resolve', 'c4/resolve']);
      capped.dispose();
    });
  });

  test('clear drops everything queued; nothing starts after it', () async {
    q.schedule(1, window());
    final queued = q.done('c4/metadata');
    q.clear();
    expect(await queued, isFalse);
    await finish('c3/resolve');
    await finish('c3/metadata');
    expect(started, ['c3/resolve', 'c3/metadata']);
    expect(q.queued, isEmpty);
  });

  test('a task that throws frees its lane', () async {
    q.schedule(1, [
      ReelPrefetchTask(
        cardId: 'c3',
        offset: 1,
        stage: ReelPrefetchStage.resolve,
        lane: 'Server A',
        run: () async => throw StateError('read failed'),
      ),
      task('c4', 2),
    ]);
    await pumpEventQueue();
    expect(started, ['c4/resolve']);
  });

  group('lanes', () {
    ReelTitle title({bool anime = false, bool show = false, List<ReelCopy> copies = const []}) =>
        ReelTitle(titleId: 't', groupKey: 'g', title: 'Harbor Lights', isShow: show, anime: anime, copies: copies);

    test('an anime show starts in the AnimeThemes lane', () {
      expect(
        ReelPrefetcher.laneFor(
          title(
            anime: true,
            show: true,
            copies: const [ReelCopy(serverId: 'Server A', ratingKey: '1')],
          ),
        ),
        ReelPrefetcher.animeThemesLane,
      );
    });

    test('anything else starts on the server the ladder asks first: an HD copy before 4K', () {
      expect(
        ReelPrefetcher.laneFor(
          title(
            copies: const [
              ReelCopy(serverId: 'Server B', ratingKey: '1', is4k: true),
              ReelCopy(serverId: 'Server A', ratingKey: '2'),
            ],
          ),
        ),
        'Server A',
      );
    });
  });
}
