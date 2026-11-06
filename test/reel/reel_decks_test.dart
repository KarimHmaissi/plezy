import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_pool.dart';
import 'package:plezy/services/reel/reel_store.dart';

ReelCardData _card(String id, {double? imdb, double? tmdb, double? audience}) => ReelCardData(
  title: ReelTitle(
    titleId: id,
    groupKey: 'g$id',
    title: 'Title $id',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: id, groupKey: 'g$id'),
    seen: SeenState.unseen,
    imdb: imdb,
    tmdb: tmdb,
    audience: audience,
  ),
  best: IndexedTitle(
    id: 's1:$id',
    serverId: 's1',
    serverName: 'S',
    libraryKey: '1',
    libraryTitle: 'Films',
    ratingKey: id,
    type: 'movie',
    title: 'Title $id',
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

/// Maps entries straight onto invented cards (card id = rating key).
class _Library extends ReelLibrary {
  _Library() : super(database: () => throw UnimplementedError(), facts: _NoFacts());

  @override
  Future<List<ReelCardData>> cards(List<DeckEntry> entries) async => [
    for (final e in entries) _card(e.ratingKey!, imdb: 7.5),
  ];
}

/// The app's synced-data notifier, counting who listens.
class _Synced extends ChangeNotifier {
  int listening = 0;

  void bump() => notifyListeners();

  @override
  void addListener(VoidCallback listener) {
    listening++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listening--;
    super.removeListener(listener);
  }
}

PoolCandidate _candidate(String id) => PoolCandidate(
  entry: DeckEntry(serverId: 's1', ratingKey: id),
  titleId: id,
  score: 1,
);

void main() {
  group('the daily pool', () {
    late ForkDatabase db;
    late LocalCustomisationStore settings;
    late ReelStore store;
    late DateTime now;

    setUp(() {
      db = ForkDatabase.memory();
      settings = LocalCustomisationStore(db);
      now = DateTime(2026, 3, 10, 20);
      store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
    });

    tearDown(() async => db.close());

    ReelPool pool({PoolModel? model, bool host = true}) =>
        ReelPool(store: store, library: _Library(), model: model, host: host, clock: () => now);

    /// The TV's pool for [day] as it reaches the phone's synced settings.
    Future<void> sharePool(DateTime day, List<String> ids) => settings.writeSetting(
      ReelStore.poolKey,
      jsonEncode({
        'day': ReelPool.dateOf(day),
        'entries': [
          for (final id in ids) {'id': id, 'sv': 's1', 'rk': id, 'cl': 'harbor drama'},
        ],
      }),
    );

    PoolModel picks(List<String> ids) =>
        (_, _, _) async => {
          'cards': [
            for (final id in ids) {'id': id, 'cluster': 'space sci-fi'},
          ],
        };

    Future<void> cachePool(DateTime day, List<String> ids) => store.cache(
      ReelPool.dayKey(day),
      jsonEncode([
        for (final id in ids) {'id': id, 'sv': 's1', 'rk': id},
      ]),
    );

    Future<void> recordAt(DateTime at, String id, ReelAction action) async {
      final was = now;
      now = at;
      await store.record(id, action, deck: 'for-you');
      now = was;
    }

    test("an earlier pool comes back as its remainder: titles gone through since its day are left out", () async {
      final yesterday = DateTime(2026, 3, 9, 9);
      await cachePool(yesterday, ['a', 'b', 'c', 'd', 'e']);
      await recordAt(DateTime(2026, 3, 8, 21), 'a', ReelAction.sampled); // before the pool's day
      await recordAt(DateTime(2026, 3, 9, 10), 'b', ReelAction.sampled);
      await recordAt(DateTime(2026, 3, 9, 11), 'c', ReelAction.quickSkip);
      await recordAt(DateTime(2026, 3, 10, 8), 'd', ReelAction.unplayed); // neutral
      final left = await pool().cachedPool();
      expect(left?.map((e) => e.ratingKey), ['a', 'd', 'e']);
    });

    test("today's pool is preferred, and rows without title ids are kept whole", () async {
      await cachePool(DateTime(2026, 3, 9), ['old']);
      await store.cache(
        ReelPool.dayKey(now),
        jsonEncode([
          {'sv': 's1', 'rk': 'x'},
          {'sv': 's1', 'rk': 'y'},
        ]),
      );
      await recordAt(now, 'x', ReelAction.sampled);
      expect((await pool().cachedPool())?.map((e) => e.ratingKey), ['x', 'y']);
    });

    test('the build stores each card with its title id, so its remainder can be taken later', () async {
      final p = pool(
        model: (_, _, _) async => {
          'cards': [
            {'id': 'c2', 'cluster': 'harbor drama'},
            {'id': 'c1', 'cluster': 'space sci-fi'},
          ],
        },
      );
      await p.build([_candidate('m'), _candidate('n')], facts: '');
      final raw = jsonDecode((await store.cached(ReelPool.dayKey(now)))!) as List;
      expect(raw.map((j) => (j as Map)['id']), ['n', 'm']);
      await recordAt(now, 'n', ReelAction.sampled);
      expect((await p.cachedPool())?.map((e) => e.ratingKey), ['m']);
    });

    test("For You opens on code order, then today's build lands, fires rebuilt and loads next", () async {
      var gathered = 0;
      final deck = ForYouDeck(
        pool: pool(
          model: (_, _, _) async => {
            'cards': [
              {'id': 'c3', 'cluster': 'a'},
              {'id': 'c1', 'cluster': 'b'},
            ],
          },
        ),
        library: _Library(),
        candidates: () async {
          gathered++;
          return [_candidate('p'), _candidate('q'), _candidate('r')];
        },
        facts: () async => '',
      );
      var fired = 0;
      deck.rebuilt.addListener(() => fired++);
      final first = await deck.load();
      expect(first.map((c) => c.id), ['p', 'q', 'r']);
      await deck.building;
      expect(fired, 1);
      expect(gathered, 1, reason: 'code order and the build share one gather');
      expect((await deck.load()).map((c) => c.id), ['r', 'p']);
      expect(fired, 1, reason: 'no second build once today is cached');
    });

    test('the gather is kept for the day only, and a failed gather is not kept', () async {
      var gathered = 0;
      var fail = true;
      final deck = ForYouDeck(
        pool: pool(),
        library: _Library(),
        candidates: () async {
          gathered++;
          if (fail) throw StateError('index busy');
          return [_candidate('p')];
        },
        facts: () async => '',
      );
      await expectLater(deck.load(), throwsStateError);
      fail = false;
      await deck.load();
      await deck.load();
      expect(gathered, 2);
      now = now.add(const Duration(days: 1));
      await deck.load();
      expect(gathered, 3);
    });
    test('the TV shares its build through the synced settings, and a phone build keeps to itself', () async {
      await pool(model: picks(['c2', 'c1'])).build([_candidate('m'), _candidate('n')], facts: '');
      final shared = jsonDecode((await settings.readSetting(ReelStore.poolKey))!) as Map;
      expect(shared['day'], '2026-03-10');
      expect((shared['entries'] as List).map((j) => (j as Map)['id']), ['n', 'm']);
      expect((shared['entries'] as List).map((j) => (j as Map)['cl']), ['space sci-fi', 'space sci-fi']);
      expect(SyncUnits.syncsSetting(ReelStore.poolKey), isTrue);

      await settings.writeSetting(ReelStore.poolKey, null);
      await pool(model: picks(['c1']), host: false).build([_candidate('p')], facts: '');
      expect(await settings.readSetting(ReelStore.poolKey), isNull);
      expect(await store.cached(ReelPool.dayKey(now)), isNotNull);
    });

    test("a phone reads the TV's pool as its remainder; its own pool for the same day comes first", () async {
      final phone = pool(host: false);
      expect(await phone.cachedPool(), isNull);

      await sharePool(DateTime(2026, 3, 9), ['a', 'b', 'c']);
      await recordAt(DateTime(2026, 3, 9, 21), 'a', ReelAction.sampled);
      expect((await phone.cachedPool())?.map((e) => e.ratingKey), ['b', 'c']);
      expect((await phone.cachedPool())?.first.cluster, 'harbor drama');

      // An own pool from an earlier day loses to the newer shared one.
      await cachePool(DateTime(2026, 3, 8), ['old']);
      expect((await phone.cachedPool())?.map((e) => e.ratingKey), ['b', 'c']);

      // The same day: this device's own pool first.
      await cachePool(DateTime(2026, 3, 9), ['own']);
      expect((await phone.cachedPool())?.map((e) => e.ratingKey), ['own']);

      // Today's shared pool beats yesterday's own one.
      await sharePool(now, ['x', 'y']);
      expect((await phone.cachedPool())?.map((e) => e.ratingKey), ['x', 'y']);
      expect(await phone.hasToday(), isTrue);
      expect(await phone.hasOwnToday(), isFalse);
    });

    test('a phone builds only after 2 days with no shared pool, or when there never was one', () async {
      final phone = pool(host: false);
      expect(await phone.shouldBuild(), isTrue, reason: 'never a shared pool');

      await sharePool(now, ['a']);
      expect(await phone.shouldBuild(), isFalse);
      await sharePool(DateTime(2026, 3, 9), ['a']);
      expect(await phone.shouldBuild(), isFalse, reason: "yesterday's pool carries the phone through today");
      await sharePool(DateTime(2026, 3, 8), ['a']);
      expect(await phone.shouldBuild(), isTrue);

      await cachePool(now, ['own']);
      expect(await phone.shouldBuild(), isFalse, reason: 'it already built today');
    });

    test('the TV builds whenever it has nothing for today, whatever the shared copy says', () async {
      await sharePool(DateTime(2026, 3, 9), ['a']);
      expect(await pool().shouldBuild(), isTrue);
      await cachePool(now, ['own']);
      expect(await pool().shouldBuild(), isFalse);
    });

    test("For You on a phone opens on the TV's pool and does not build", () async {
      await sharePool(now, ['h', 'k']);
      var called = 0;
      final deck = ForYouDeck(
        pool: pool(
          host: false,
          model: (_, _, _) async {
            called++;
            return null;
          },
        ),
        library: _Library(),
        candidates: () async => [_candidate('p')],
        facts: () async => '',
      );
      expect((await deck.load()).map((c) => c.id), ['h', 'k']);
      await deck.building;
      expect(called, 0);
    });

    test("today's shared pool arriving fires rebuilt once, and only while something listens", () async {
      final synced = _Synced();
      final deck = ForYouDeck(
        pool: pool(host: false),
        library: _Library(),
        candidates: () async => [_candidate('p')],
        facts: () async => '',
        sharedChanges: synced,
      );
      await sharePool(DateTime(2026, 3, 9), ['a']);
      expect((await deck.load()).map((c) => c.id), ['a']);
      var fired = 0;
      void listener() => fired++;
      deck.rebuilt.addListener(listener);
      expect(synced.listening, 1);

      Future<void> sync() async {
        synced.bump();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }

      await sync();
      expect(fired, 0, reason: 'nothing new was synced');
      await sharePool(now, ['b', 'c']);
      await sync();
      expect(fired, 1);
      await sync();
      expect(fired, 1, reason: 'the same shared day fires once');
      expect((await deck.load()).map((c) => c.id), ['b', 'c']);

      deck.rebuilt.removeListener(listener);
      expect(synced.listening, 0);
    });
  });

  test('code order keeps to well-rated titles, in its own order, unrated last', () {
    final kept = ForYouDeck.worthShowing([
      _card('unrated'),
      _card('bad', imdb: 2.4),
      _card('good', imdb: 7.8),
      _card('meh', imdb: 5.9),
      _card('tmdbOnly', tmdb: 6.6),
      _card('plexOnly', audience: 3.1),
      _card('fine', imdb: 6.0),
    ]);
    expect(kept.map((c) => c.id), ['good', 'tmdbOnly', 'fine', 'unrated']);
  });

  test('IMDb outranks the other scores when both are known', () {
    final kept = ForYouDeck.worthShowing([_card('a', imdb: 3.4, tmdb: 7.0)]);
    expect(kept, isEmpty);
  });
}
