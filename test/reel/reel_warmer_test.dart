import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_cursor.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_pool.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy/services/reel/reel_warmer.dart';
import 'package:plezy/utils/app_logger.dart';

/// The warm start before the Reel opens (plan V2-14, D3, D15).

ReelCardData _card(String id) => ReelCardData(
  title: ReelTitle(
    titleId: id,
    groupKey: 'g$id',
    title: 'Harbor Lights $id',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: id, groupKey: 'g$id'),
    seen: SeenState.unseen,
    imdb: 7.5,
  ),
  best: IndexedTitle(
    id: 's1:$id',
    serverId: 's1',
    serverName: 'Server A',
    libraryKey: '1',
    libraryTitle: 'Films',
    ratingKey: id,
    type: 'movie',
    title: 'Harbor Lights $id',
    genres: '',
    countries: '',
    directors: '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$id',
    summary: '',
  ),
);

class _NoFacts implements TitleFactsSource {
  @override
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs) async => const {};
  @override
  TitleFacts? peek(String globalKey) => null;
}

/// Entries straight onto invented cards (card id = rating key).
class _Library extends ReelLibrary {
  _Library() : super(database: () => throw UnimplementedError(), facts: _NoFacts());

  @override
  Future<List<ReelCardData>> cards(List<DeckEntry> entries) async => [for (final e in entries) _card(e.ratingKey!)];
}

PoolCandidate _candidate(String id) => PoolCandidate(
  entry: DeckEntry(serverId: 's1', ratingKey: id),
  titleId: id,
  score: 1,
);

MediaItem _item(String id) =>
    MediaItem(id: id, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Harbor Lights $id', serverId: 's1');

List<String> _log(String prefix) =>
    MemoryLogOutput.getLogs().map((e) => e.message).where((m) => m.startsWith(prefix)).toList().reversed.toList();

void main() {
  late ForkDatabase db;
  late ReelStore store;
  late DateTime now;
  late int gathers;
  late int calls;
  late Completer<void>? gatherGate;
  late Completer<void>? callGate;
  late bool playing;
  late List<String> itemsAsked;
  late List<String> artFor;

  setUp(() {
    db = ForkDatabase.memory();
    final settings = LocalCustomisationStore(db);
    now = DateTime(2026, 3, 10, 18);
    store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
    gathers = 0;
    calls = 0;
    gatherGate = null;
    callGate = null;
    playing = false;
    itemsAsked = [];
    artFor = [];
    MemoryLogOutput.clearLogs();
  });

  tearDown(() async => db.close());

  /// For You over four candidates; the day's Sonnet call orders them 4, 3,
  /// 2, 1, counted in [calls]; the gather is counted in [gathers].
  ForYouDeck forYou({bool model = true}) {
    final pool = ReelPool(
      store: store,
      library: _Library(),
      clock: () => now,
      model: !model
          ? null
          : (_, _, _) async {
              calls++;
              await callGate?.future;
              return {
                'cards': [
                  for (final id in ['c4', 'c3', 'c2', 'c1']) {'id': id},
                ],
              };
            },
    );
    return ForYouDeck(
      pool: pool,
      library: _Library(),
      candidates: () async {
        gathers++;
        await gatherGate?.future;
        return [
          for (final id in ['1', '2', '3', '4']) _candidate(id),
        ];
      },
      facts: () async => '',
    );
  }

  ReelWarmer warmer(ForYouDeck deck, {bool art = true, bool Function()? foreground}) => ReelWarmer(
    store: store,
    forYou: deck,
    playing: () => playing,
    foreground: foreground,
    clock: () => now,
    cachedItem: (sv, rk) async {
      itemsAsked.add(rk);
      return _item(rk);
    },
    precacheArt: (card, item, {required clip}) async => artFor.add('${card.id}${clip ? ' clip' : ''}'),
    artAllowed: () => art,
  );

  /// The Reel was used on this device [ago].
  Future<void> usedAgo(Duration ago) =>
      ReelStore(database: () async => db, clock: () => now.subtract(ago)).record('9', ReelAction.sampled);

  test('D3: a Reel not used in 7 days gets no build and no gather; the sweep still runs', () async {
    await usedAgo(const Duration(days: 8));
    final deck = forYou();
    final outcome = await warmer(deck).run();
    expect(outcome, 'skipped: the Reel was not used in 7 days');
    expect(calls, 0);
    expect(gathers, 0);
    expect(await store.cached(ReelStore.sweptKey), ReelStore.dayStamp(now));
    expect(await store.cached(ReelStore.deckKey('for-you', now)), isNull);
  });

  test("used lately: today's build runs once, then the first cards are read from the caches only", () async {
    await usedAgo(const Duration(days: 6));
    await store.cache('src:g4', jsonEncode({'v': ClipResolver.sourceFormat, 'k': 'plex', 'a': 'plex:1'}));
    await store.cache('src:g3', ClipResolver.missRow);
    final deck = forYou();
    final outcome = await warmer(deck).run();
    expect(calls, 1, reason: 'one Sonnet call, through the pool (AiSpend records it)');
    expect(gathers, 1);
    expect(await deck.pool.hasToday(), isTrue);
    expect(outcome, startsWith('done build=built'));
    expect(outcome, contains('list=pool'));
    // The pool's order: 4, 3, 2 are the first three.
    expect(outcome, contains('cards=clip+item,miss+item,?+item'));
    expect(itemsAsked, ['4', '3', '2']);
    expect(artFor, ['4 clip'], reason: "the first card's art only, as a clip card's");
    expect(_log('[ReelWarmer] done'), hasLength(1));
  });

  test('the cards start at the kept cursor, and the art is the card the Reel opens on', () async {
    await usedAgo(const Duration(hours: 2));
    await store.cache(ReelStore.cursorKey('for-you', now), const ReelCursor(id: '3', after: '2').encode());
    await warmer(forYou()).run();
    expect(itemsAsked, ['3', '2', '1']);
    expect(artFor, ['3']);
  });

  test("with today's pool already here, nothing is gathered or called", () async {
    await usedAgo(const Duration(days: 1));
    await store.cache(
      ReelPool.dayKey(now),
      jsonEncode([
        for (final id in ['2', '1']) {'id': id, 'sv': 's1', 'rk': id},
      ]),
    );
    final outcome = await warmer(forYou()).run();
    expect(outcome, contains('build=had'));
    expect(gathers, 0);
    expect(calls, 0);
    expect(itemsAsked, ['2', '1']);
  });

  test("no build (no AI key): today's code order is kept as deck:for-you:<day> for the open", () async {
    await usedAgo(const Duration(days: 1));
    final deck = forYou(model: false);
    final outcome = await warmer(deck).run();
    expect(outcome, contains('build=none'));
    expect(outcome, contains('list=kept 4'));
    final kept = jsonDecode((await store.cached(ReelStore.deckKey('for-you', now)))!) as List;
    expect(kept.map((r) => (r as Map)['rk']), ['1', '2', '3', '4']);
    expect(gathers, 1);

    // The Reel's own load (on the same For You, as ReelApp shares it)
    // reads the kept order: it splits, where code order loads whole.
    final parts = await deck.loadParts(2);
    expect(parts.head.map((c) => c.id), ['1', '2']);
    expect(parts.rest, isNotNull);
    expect((await parts.rest!()).map((c) => c.id), ['3', '4']);
    expect(gathers, 1);
  });

  test('memory trimmed: no art is warmed', () async {
    await usedAgo(const Duration(days: 1));
    final outcome = await warmer(forYou(), art: false).run();
    expect(outcome, endsWith('art=skipped (memory)'));
    expect(artFor, isEmpty);
  });

  test('video playing: nothing past the sweep runs, and the day is left for a later look', () async {
    await usedAgo(const Duration(days: 1));
    playing = true;
    final w = warmer(forYou());
    expect(await w.run(), 'paused at use (video is playing)');
    expect(gathers, 0);
    playing = false;
    expect(await w.run(), startsWith('done'));
  });

  test('playback starting during the gather stops the warm start before the Sonnet call', () async {
    await usedAgo(const Duration(days: 1));
    gatherGate = Completer<void>();
    final w = warmer(forYou());
    final run = w.run();
    await pumpEventQueue();
    expect(gathers, 1);
    playing = true;
    gatherGate!.complete();
    expect(await run, 'paused at build call (video is playing)');
    expect(calls, 0);
  });

  test("a Reel start during the build joins it: one call, and the warm start's later steps are dropped", () async {
    await usedAgo(const Duration(days: 1));
    callGate = Completer<void>();
    final deck = forYou();
    final w = warmer(deck);
    final run = w.run();
    await pumpEventQueue();
    expect(calls, 1);

    // The Reel opens on the same For You (ReelApp shares it).
    w.yieldNow();
    final reelLoad = deck.loadParts(ReelDeck.headEntries);
    await pumpEventQueue();
    callGate!.complete();
    expect(await run, 'yielded at snapshot');
    await reelLoad;
    await deck.building;
    expect(calls, 1, reason: 'no second Sonnet call');
    expect(gathers, 1, reason: 'the Reel joined the gather');
    expect(itemsAsked, isEmpty);
    expect(artFor, isEmpty);
    expect(_log('[ReelWarmer] yields to the Reel at build call'), hasLength(1));
  });

  test('scheduling: after the start delay, never with the Reel open or in the background, once a day', () {
    fakeAsync((async) {
      var fg = false;
      final w = warmer(forYou(), foreground: () => fg);
      unawaited(usedAgo(const Duration(days: 1)));
      async.flushMicrotasks();
      w.arm();
      async.elapse(const Duration(seconds: 59));
      expect(gathers, 0);
      async.elapse(const Duration(seconds: 2));
      expect(gathers, 0, reason: 'in the background');
      expect(w.armed, isTrue, reason: 'it looks again later');

      fg = true;
      w.reelActive(true);
      async.elapse(w.recheck);
      expect(gathers, 0, reason: 'the Reel opened today: its own open did the work');
      w.reelActive(false);

      // The next day.
      now = now.add(const Duration(days: 1));
      async.elapse(w.recheck);
      async.flushMicrotasks();
      expect(gathers, 1);
      expect(calls, 1);
      async.elapse(w.recheck * 4);
      expect(calls, 1, reason: 'once a day');
      w.dispose();
      expect(w.armed, isFalse);
    });
  });
}
