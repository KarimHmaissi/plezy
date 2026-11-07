import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/brain/history_brain.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_pool.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy_brain/plezy_brain.dart';

/// An invented card (card id = [key]); its facts say how far they got.
ReelCardData _card(
  String key, {
  SeenState seen = SeenState.unseen,
  bool show = false,
  bool kids = false,
  double? imdb,
}) => ReelCardData(
  title: ReelTitle(
    titleId: key,
    groupKey: 'g$key',
    title: 'Title $key',
    isShow: show,
    copies: [ReelCopy(serverId: 's1', ratingKey: key)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: key, groupKey: 'g$key'),
    seen: seen,
    inKidsLibrary: kids,
    imdb: imdb,
  ),
  best: IndexedTitle(
    id: 's1:$key',
    serverId: 's1',
    serverName: 'Server A',
    libraryKey: '1',
    libraryTitle: show ? 'Shows' : 'Films',
    ratingKey: key,
    type: show ? 'show' : 'movie',
    title: 'Title $key',
    genres: '',
    countries: '',
    directors: '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$key',
    summary: '',
  ),
);

class _NoFacts implements TitleFactsSource {
  @override
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs) async => const {};
  @override
  TitleFacts? peek(String globalKey) => null;
}

/// Maps entries straight onto invented cards: shows by key with their seen
/// state, everything else an unseen film rated [ratings] (7.5 by default).
class _Library extends ReelLibrary {
  _Library({this.shows = const {}, this.ratings = const {}})
    : super(database: () => throw UnimplementedError(), facts: _NoFacts());

  final Map<String, ({SeenState seen, bool kids})> shows;
  final Map<String, double?> ratings;

  @override
  Future<List<ReelCardData>> cards(List<DeckEntry> entries) async => [
    for (final e in entries)
      _card(
        e.ratingKey!,
        show: shows.containsKey(e.ratingKey),
        seen: shows[e.ratingKey]?.seen ?? SeenState.unseen,
        kids: shows[e.ratingKey]?.kids ?? false,
        imdb: ratings.containsKey(e.ratingKey) ? ratings[e.ratingKey] : 7.5,
      ),
  ];
}

/// A brain with fixed watched titles and fixed similar titles per seed.
class _Brain extends HistoryBrain {
  _Brain({this.watched = const [], this.near = const {}});

  final List<TitleProfile> watched;
  final Map<String, List<({TitleProfile profile, double score})>> near;
  final asked = <String>[];

  @override
  Future<List<TitleProfile>> watchedProfiles() async => watched;

  @override
  Future<String> taste() async => 'Harbor dramas, slow sci-fi.';

  @override
  Future<List<({TitleProfile profile, double score})>> similar(
    String id, {
    int limit = 20,
    bool? watched,
    TitleKind? kind,
  }) async {
    asked.add(id);
    return near[id] ?? const [];
  }
}

/// A show on the servers, with its real plays.
TitleProfile _show(String key, List<DateTime> watches) => TitleProfile(
  id: key,
  kind: TitleKind.show,
  title: 'Title $key',
  serverId: 's1',
  ratingKey: key,
  inLibrary: true,
  watches: watches,
  episodesWatched: watches.length,
);

/// An unwatched library title as the brain knows it.
({TitleProfile profile, double score}) _near(String key, double score) => (
  profile: TitleProfile(
    id: key,
    kind: TitleKind.movie,
    title: 'Title $key',
    serverId: 's1',
    ratingKey: key,
    inLibrary: true,
  ),
  score: score,
);

PoolCandidate _candidate(String key) => PoolCandidate(
  entry: DeckEntry(serverId: 's1', ratingKey: key),
  titleId: key,
  score: 1,
);

void main() {
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

  SeenState finished(DateTime last) => SeenState(kind: SeenKind.finished, last: last, eps: 10, total: 10);
  SeenState watching(DateTime last) => SeenState(kind: SeenKind.inProgress, last: last, eps: 5, total: 10);
  DateTime daysAgo(num d) => now.subtract(Duration(hours: (d * 24).round()));

  group('the seed: a show they just finished', () {
    test('the newest active show they finished or caught up on, never a Kids show or one still going', () async {
      final library = _Library(
        shows: {
          'harbor': (seen: finished(daysAgo(2)), kids: false),
          'lantern': (seen: finished(daysAgo(1)), kids: true),
          'tide': (seen: watching(daysAgo(0.5)), kids: false),
          'mill': (seen: finished(daysAgo(4)), kids: false),
        },
      );
      final brain = _Brain(
        watched: [
          _show('mill', [daysAgo(5), daysAgo(4)]),
          _show('harbor', [daysAgo(3), daysAgo(2)]),
          _show('lantern', [daysAgo(2), daysAgo(1)]),
          _show('tide', [daysAgo(1), daysAgo(0.5)]),
        ],
      );
      final seed = await whatsNextSeed(library: library, brain: brain, now: now);
      expect(seed?.id, 'harbor', reason: 'the newest finished, after a Kids show and one still going');
    });

    test('one play on a show finished long ago, a show not on the servers, or an old finish never seeds it', () async {
      final library = _Library(
        shows: {
          'rewatch': (seen: finished(daysAgo(1)), kids: false),
          'away': (seen: finished(daysAgo(1)), kids: false),
          'old': (seen: finished(daysAgo(20)), kids: false),
        },
      );
      final brain = _Brain(
        watched: [
          // One episode seen again: not an active show.
          _show('rewatch', [DateTime(2025, 1, 2), DateTime(2025, 1, 3), daysAgo(1)]),
          TitleProfile(id: 'away', kind: TitleKind.show, title: 'Title away', watches: [daysAgo(2), daysAgo(1)]),
          _show('old', [daysAgo(21), daysAgo(20)]),
        ],
      );
      expect(await whatsNextSeed(library: library, brain: brain, now: now), isNull);
    });

    test('whatsNextList: the seed and the unseen titles like it, nothing resting, the show itself left out', () async {
      final library = _Library(shows: {'harbor': (seen: finished(daysAgo(1)), kids: false)});
      final brain = _Brain(
        watched: [
          _show('harbor', [daysAgo(2), daysAgo(1)]),
        ],
        near: {
          'harbor': [_near('quay', 0.9), _near('harbor', 0.8), _near('reef', 0.7), _near('dune', 0.6)],
        },
      );
      await store.notForMe('reef');
      final list = await whatsNextList(library: library, store: store, brain: brain, now: now);
      expect(list?.seed.id, 'harbor');
      expect(list?.candidates.map((c) => c.titleId), ['quay', 'dune']);
      expect(list?.candidates.first.like, ['Title harbor'], reason: 'the finished show is each one\'s anchor');

      final none = await whatsNextList(library: library, store: store, brain: _Brain(), now: now);
      expect(none, isNull);
    });
  });

  group("the What's next deck", () {
    final library = _Library(
      shows: {'harbor': (seen: finished(DateTime(2026, 3, 9)), kids: false)},
      ratings: {'low': 4.2, 'unrated': null},
    );
    final seed = _card('harbor', show: true, seen: finished(DateTime(2026, 3, 9)));

    ReelPool pool({PoolModel? model}) => ReelPool(store: store, library: library, model: model, clock: () => now);

    test('code order until a build orders it: similarity, kept to what the public rates', () async {
      final forYou = ForYouDeck(
        pool: pool(),
        library: library,
        candidates: () async => const [],
        facts: () async => '',
      );
      final deck = WhatsNextDeck(
        seed: seed,
        forYou: forYou,
        library: library,
        candidates: () async => [_candidate('quay'), _candidate('unrated'), _candidate('low'), _candidate('dune')],
      );
      expect((await deck.load()).map((c) => c.id), ['quay', 'dune', 'unrated']);
      expect(deck.id, 'whats-next');
      expect(deck.name, "What's next after Title harbor");
      expect(deck.keepsSeen, isFalse);
      expect(deck.daily, isTrue);
      expect(identical(deck.rebuilt, forYou.rebuilt), isTrue);
    });

    test('the For You call orders it through its optional whats_next array, with no call of its own', () async {
      var calls = 0;
      String? user;
      String? system;
      Map<String, Object?>? tool;
      final forYou = ForYouDeck(
        pool: pool(
          model: (s, u, t) async {
            calls++;
            system = s;
            user = u;
            tool = t;
            return {
              'cards': [
                {'id': 'c1', 'cluster': 'harbor drama'},
              ],
              // Unknown ids, a For You id and a repeat are ignored.
              'whats_next': ['n3', 'n9', 'c1', 'n1', 'n3'],
            };
          },
        ),
        library: library,
        candidates: () async => [_candidate('fresh')],
        facts: () async => '',
        next: () async => (seed: seed, candidates: [_candidate('quay'), _candidate('dune'), _candidate('reef')]),
      );
      final deck = WhatsNextDeck(
        seed: seed,
        forYou: forYou,
        library: library,
        candidates: () async => [_candidate('quay'), _candidate('dune'), _candidate('reef')],
      );
      var fired = 0;
      deck.rebuilt.addListener(() => fired++);
      expect((await deck.load()).map((c) => c.id), ['quay', 'dune', 'reef'], reason: 'code order first');
      await forYou.building;
      expect(calls, 1);
      expect(fired, 1);
      expect((await deck.load()).map((c) => c.id), ['reef', 'quay']);
      expect(calls, 1, reason: 'no second build once today is cached');

      final lines = user!.split('\n');
      final head = lines.indexWhere((l) => l.startsWith("What's next"));
      expect(head, greaterThan(lines.indexOf('Candidates:')));
      expect(lines[head], contains('they just finished Title harbor'));
      expect(lines[head], contains('10/10 eps, finished'));
      expect(lines.firstWhere((l) => l.startsWith('n2:')), startsWith('n2: Title dune · film'));
      expect(system, contains('whats_next: optional'));
      final schema = tool!['input_schema'] as Map;
      expect((schema['properties'] as Map).containsKey('whats_next'), isTrue);
      expect(schema['required'], ['cards']);
    });

    test("an order kept for another show is never read for this one", () async {
      final forYou = ForYouDeck(
        pool: pool(),
        library: library,
        candidates: () async => const [],
        facts: () async => '',
      );
      await store.cache(
        ReelPool.nextKey(now),
        jsonEncode({
          'seed': 'lantern',
          'rows': [
            {'id': 'reef', 'sv': 's1', 'rk': 'reef'},
          ],
        }),
      );
      expect(await pool().cachedNext('harbor'), isNull);
      expect((await pool().cachedNext('lantern'))?.map((e) => e.ratingKey), ['reef']);
      final deck = WhatsNextDeck(
        seed: seed,
        forYou: forYou,
        library: library,
        candidates: () async => [_candidate('quay')],
      );
      expect((await deck.load()).map((c) => c.id), ['quay']);
    });

    test('a build with no whats_next keeps code order, and no list means no section', () async {
      String? user;
      final forYou = ForYouDeck(
        pool: pool(
          model: (_, u, _) async {
            user = u;
            return {
              'cards': [
                {'id': 'c1', 'cluster': 'harbor drama'},
              ],
            };
          },
        ),
        library: library,
        candidates: () async => [_candidate('fresh')],
        facts: () async => '',
        next: () async => null,
      );
      await forYou.load();
      await forYou.building;
      expect(user, isNot(contains("What's next")));
      expect(await store.cached(ReelPool.nextKey(now)), isNull);
    });

    test("the TV shares the order with its pool; a phone reads it as the day's remainder", () async {
      await pool(
        model: (_, _, _) async => {
          'cards': [
            {'id': 'c1', 'cluster': 'harbor drama'},
          ],
          'whats_next': ['n2', 'n1'],
        },
      ).build(
        [_candidate('fresh')],
        facts: '',
        next: (seed: seed, candidates: [_candidate('quay'), _candidate('dune')]),
      );
      final shared = jsonDecode((await settings.readSetting(ReelStore.poolKey))!) as Map;
      expect((shared['next'] as Map)['seed'], 'harbor');
      expect(((shared['next'] as Map)['rows'] as List).map((j) => (j as Map)['rk']), ['dune', 'quay']);

      // The phone: its own database, the same synced settings.
      final phoneDb = ForkDatabase.memory();
      addTearDown(phoneDb.close);
      final phoneStore = ReelStore(database: () async => phoneDb, settings: () async => settings, clock: () => now);
      final phone = ReelPool(store: phoneStore, library: library, host: false, clock: () => now);
      expect((await phone.cachedNext('harbor'))?.map((e) => e.ratingKey), ['dune', 'quay']);
      expect(await phone.cachedNext('lantern'), isNull);
      await phoneStore.record('dune', ReelAction.sampled, deck: 'whats-next');
      expect((await phone.cachedNext('harbor'))?.map((e) => e.ratingKey), ['quay'], reason: 'gone through today');
    });

    test("Rebuild today's For You drops today's order too", () async {
      await pool(
        model: (_, _, _) async => {
          'cards': [
            {'id': 'c1', 'cluster': 'harbor drama'},
          ],
          'whats_next': ['n1'],
        },
      ).build([_candidate('fresh')], facts: '', next: (seed: seed, candidates: [_candidate('quay')]));
      expect(await store.cached(ReelPool.nextKey(now)), isNotNull);
      await pool().clearToday();
      expect(await store.cached(ReelPool.nextKey(now)), isNull);
    });
  });
}
