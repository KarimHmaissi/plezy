import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/brain/history_brain.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_person.dart';
import 'package:plezy/services/reel/reel_pool.dart';
import 'package:plezy/services/reel/reel_store.dart';
import 'package:plezy_brain/plezy_brain.dart';

class _NoFacts implements TitleFactsSource {
  @override
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs) async => const {};
  @override
  TitleFacts? peek(String globalKey) => null;
}

/// Maps entries straight onto invented cards (card id = rating key). Keys
/// in [seen] are seen; [scores] are IMDb ratings (none: unrated); keys in
/// [directed] list the card's directors (`|`-joined).
class _Library extends ReelLibrary {
  _Library({this.seen = const {}, this.scores = const {}, this.directed = const {}, IndexDatabase? db})
    : super(database: () async => db ?? (throw UnimplementedError()), facts: _NoFacts());

  final Set<String> seen;
  final Map<String, double> scores;
  final Map<String, String> directed;

  @override
  Future<List<ReelCardData>> cards(List<DeckEntry> entries) async => [
    for (final e in entries)
      _card(
        e.ratingKey!,
        seen: seen.contains(e.ratingKey),
        imdb: scores[e.ratingKey],
        directors: directed[e.ratingKey],
      ),
  ];
}

ReelCardData _card(String id, {bool seen = false, double? imdb, String? directors}) => ReelCardData(
  title: ReelTitle(
    titleId: id,
    groupKey: 'g$id',
    title: 'Harbor Lights $id',
    isShow: false,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: id, groupKey: 'g$id'),
    seen: seen ? const SeenState(kind: SeenKind.finished) : SeenState.unseen,
    imdb: imdb,
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
    year: 2024,
    genres: '',
    countries: '',
    directors: directors ?? '',
    writers: '',
    cast: '',
    collections: '',
    groupKey: 'g$id',
    summary: '',
  ),
);

/// A watched film as the brain knows it: [watches] real dated plays,
/// [bulk] undated ones (imports, marks).
TitleProfile _watched(
  String key, {
  List<String> directors = const [],
  List<String> cast = const [],
  List<DateTime> watches = const [],
  int bulk = 0,
}) => TitleProfile(
  id: 'p:$key',
  kind: TitleKind.movie,
  title: 'Quiet Tide $key',
  directors: directors,
  cast: cast,
  watches: watches,
  bulkPlays: bulk,
);

class _Brain extends HistoryBrain {
  _Brain(this.watched);

  final List<TitleProfile> watched;

  @override
  Future<List<TitleProfile>> watchedProfiles() async => watched;
}

PoolCandidate _candidate(String id) => PoolCandidate(
  entry: DeckEntry(serverId: 's1', ratingKey: id),
  titleId: id,
  score: 1,
);

PersonPick _pick(String name, List<String> ids, {PersonRole role = PersonRole.director, int watched = 4}) =>
    (name: name, role: role, watched: watched, candidates: [for (final id in ids) _candidate(id)]);

void main() {
  late ForkDatabase db;
  late LocalCustomisationStore settings;
  late ReelStore store;
  var now = DateTime(2026, 3, 10, 20);

  setUp(() {
    db = ForkDatabase.memory();
    settings = LocalCustomisationStore(db);
    now = DateTime(2026, 3, 10, 20);
    store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
  });

  tearDown(() async => db.close());

  ReelPool pool({PoolModel? model, bool host = true, ReelStore? on, ReelLibrary? library}) =>
      ReelPool(store: on ?? store, library: library ?? _Library(), model: model, host: host, clock: () => now);

  final day1 = DateTime(2025, 1, 5), day2 = DateTime(2025, 6, 1), day3 = DateTime(2026, 2, 1);

  group('who counts', () {
    test('three titles with a real watch; once per title; directors and the first three cast names only', () {
      final ranked = ReelPerson.rank([
        // Ada Marlow directs two and stars in a third: three titles.
        _watched('a', directors: ['Ada Marlow'], watches: [day1, day2]),
        _watched('b', directors: ['Ada Marlow'], cast: ['Ada Marlow'], watches: [day2]),
        _watched('c', cast: ['Bo Lindqvist', 'Ada Marlow'], watches: [day3]),
        // Bo Lindqvist: c, d and e, but e only as the fourth name billed.
        _watched('d', cast: ['Bo Lindqvist'], watches: [day1]),
        _watched('e', cast: ['Cy Okafor', 'Dee Hollis', 'Eli Brandt', 'Bo Lindqvist'], watches: [day1]),
        // An import alone is not a real watch.
        _watched('f', cast: ['Bo Lindqvist'], bulk: 3),
      ]);
      expect(ranked.map((p) => p.name), ['Ada Marlow']);
      expect(ranked.single.titles, 3, reason: 'b counts once though she is credited twice');
      expect(ranked.single.role, PersonRole.director, reason: 'directed two of the three');
      expect(ranked.single.last, day3);
    });

    test('most titles first, then the newest watch, then by name; the role is the one in more titles', () {
      List<TitleProfile> films(String name, int n, DateTime at, {bool director = false}) => [
        for (var i = 0; i < n; i++)
          _watched(
            '$name$i',
            directors: director ? [name] : const [],
            cast: director ? const [] : [name],
            watches: [at],
          ),
      ];
      final ranked = ReelPerson.rank([
        ...films('Fen Arden', 3, day1),
        ...films('Gil Moreau', 4, day1, director: true),
        ...films('Hana Ivers', 3, day3),
        ...films('Ari Vance', 3, day1),
      ]);
      expect(ranked.map((p) => p.name), ['Gil Moreau', 'Hana Ivers', 'Ari Vance', 'Fen Arden']);
      expect(ranked.map((p) => p.role), [PersonRole.director, PersonRole.cast, PersonRole.cast, PersonRole.cast]);
    });

    test('names match across spellings of case and spacing', () {
      final ranked = ReelPerson.rank([
        _watched('a', directors: ['Ada Marlow'], watches: [day1]),
        _watched('b', directors: ['ada marlow '], watches: [day1]),
        _watched('c', directors: ['ADA MARLOW'], watches: [day1]),
      ]);
      expect(ranked.single.name, 'Ada Marlow', reason: 'the first spelling met names them');
      expect(ReelPerson.credits('ada marlow', directors: '', cast: 'Cy Okafor|Ada Marlow'), isTrue);
      expect(
        ReelPerson.credits('Ada Marlow', directors: '', cast: 'Cy Okafor|Dee Hollis|Eli Brandt|Ada Marlow'),
        isFalse,
      );
      expect(ReelPerson.credits('Ada Marlow', directors: 'Ada Marlow|Bo Lindqvist', cast: ''), isTrue);
      expect(ReelPerson.credits('Ada Marlow', directors: 'Ada Marlowe', cast: ''), isFalse);
    });
  });

  group('who is chosen', () {
    PersonStat stat(String name) => PersonStat(name: name, role: PersonRole.cast, titles: 3);

    test("today's person stays; then those not featured lately in rank order; then the longest rested", () {
      final ranked = [stat('Ada Marlow'), stat('Bo Lindqvist'), stat('Cy Okafor'), stat('Dee Hollis')];
      expect(ReelPerson.rotation(ranked, const {}, '2026-03-10').map((p) => p.name), [
        'Ada Marlow',
        'Bo Lindqvist',
        'Cy Okafor',
        'Dee Hollis',
      ]);
      final order = ReelPerson.rotation(ranked, {
        'ada marlow': '2026-03-09',
        'bo lindqvist': '2026-03-05',
        'dee hollis': '2026-03-10',
      }, '2026-03-10');
      expect(order.map((p) => p.name), ['Dee Hollis', 'Cy Okafor', 'Bo Lindqvist', 'Ada Marlow']);
    });

    test('the top person with three unseen titles; seen and resting titles do not count', () async {
      await store.notForMe('b2');
      final watched = [
        for (final k in ['1', '2', '3']) _watched('a$k', directors: ['Ada Marlow'], watches: [day3]),
        for (final k in ['1', '2', '3']) _watched('b$k', cast: ['Bo Lindqvist'], watches: [day1]),
      ];
      final asked = <String>[];
      final library = _Library(seen: {'a2'}, scores: {'b1': 6.1, 'b3': 8.4});
      final got = await personPick(
        library: library,
        store: store,
        pool: pool(library: library),
        brain: _Brain(watched),
        titlesWith: (name) async {
          asked.add(name);
          final keys = name == 'Ada Marlow' ? ['a1', 'a2', 'a3'] : ['b1', 'b2', 'b3', 'b4', 'b5'];
          return [for (final k in keys) DeckEntry(serverId: 's1', ratingKey: k)];
        },
      );
      expect(asked, ['Ada Marlow', 'Bo Lindqvist'], reason: 'Ada has only two unseen titles');
      expect(got?.name, 'Bo Lindqvist');
      expect(got?.role, PersonRole.cast);
      expect(got?.watched, 3);
      expect(got?.candidates.map((c) => c.titleId), ['b3', 'b1', 'b4', 'b5'], reason: 'best rated first, unrated last');
    });

    test("a person featured lately waits while someone else qualifies; today's stays all day", () async {
      final day0 = DateTime(2024, 6, 1);
      final watched = [
        for (final k in ['1', '2', '3', '4']) _watched('a$k', directors: ['Ada Marlow'], watches: [day3]),
        for (final k in ['1', '2', '3']) _watched('b$k', cast: ['Bo Lindqvist'], watches: [day1]),
        for (final k in ['1', '2', '3']) _watched('c$k', cast: ['Cy Okafor'], watches: [day0]),
      ];
      Future<List<DeckEntry>> titles(String name) async => [
        for (var i = 0; i < 3; i++) DeckEntry(serverId: 's1', ratingKey: '${name[0]}u$i'),
      ];
      Future<PersonPick?> pick() =>
          personPick(library: _Library(), store: store, pool: pool(), brain: _Brain(watched), titlesWith: titles);
      Future<String?> day() async {
        final p = await pick();
        if (p != null) await pool().keepPerson(p);
        return p?.name;
      }

      expect(await day(), 'Ada Marlow');
      expect(await day(), 'Ada Marlow', reason: 'the same day keeps its person');
      now = DateTime(2026, 3, 11, 9);
      expect(await day(), 'Bo Lindqvist', reason: 'Ada rests');
      now = DateTime(2026, 3, 12, 9);
      expect(await day(), 'Cy Okafor', reason: 'someone not featured lately beats a higher rank resting');
      now = DateTime(2026, 3, 13, 9);
      expect((await pick())?.name, 'Ada Marlow', reason: 'everyone rests: the one featured longest ago');

      now = DateTime(2026, 3, 10 + ReelPool.personRest - 1, 9);
      expect((await pool().featuredPeople()).keys, contains('ada marlow'), reason: 'her day is still remembered');
      now = DateTime(2026, 3, 10 + ReelPool.personRest, 9);
      expect((await pool().featuredPeople()).keys, isNot(contains('ada marlow')));
      expect((await pick())?.name, 'Ada Marlow', reason: 'her rest is over: she ranks first again');
    });

    test('nobody qualifies, or nobody has enough unseen titles: no person', () async {
      final few = [
        _watched('a1', directors: ['Ada Marlow'], watches: [day1]),
        _watched('a2', directors: ['Ada Marlow'], watches: [day1]),
      ];
      var asked = 0;
      Future<List<DeckEntry>> titles(String name) async {
        asked++;
        return [DeckEntry(serverId: 's1', ratingKey: 'x')];
      }

      expect(
        await personPick(library: _Library(), store: store, pool: pool(), brain: _Brain(few), titlesWith: titles),
        isNull,
      );
      expect(asked, 0);
      final enough = [
        ...few,
        _watched('a3', directors: ['Ada Marlow'], watches: [day1]),
      ];
      expect(
        await personPick(library: _Library(), store: store, pool: pool(), brain: _Brain(enough), titlesWith: titles),
        isNull,
      );
      expect(asked, 1);
    });

    test('from the index: directed or in the first three cast names, one row per title', () async {
      final idx = IndexDatabase.memory();
      addTearDown(idx.close);
      Future<void> row(String key, String group, {String directors = '', String cast = ''}) => idx
          .into(idx.indexTitles)
          .insert(
            IndexTitlesCompanion.insert(
              id: 's1:$key',
              serverId: 's1',
              serverName: 'Server A',
              libraryKey: '1',
              libraryTitle: 'Films',
              ratingKey: key,
              type: 'movie',
              title: 'Quiet Tide $key',
              groupKey: group,
              directors: Value(directors),
              cast: Value(cast),
            ),
          );
      await row('d', 'gd', directors: 'Ada Marlow');
      await row('d4k', 'gd', directors: 'Ada Marlow'); // the same title's other copy
      await row('c', 'gc', cast: 'Bo Lindqvist|Ada Marlow');
      await row('late', 'gl', cast: 'Bo Lindqvist|Cy Okafor|Dee Hollis|Ada Marlow'); // billed fourth
      await row('near', 'gn', directors: 'Ada Marlowe'); // a different person
      await row('none', 'gx', cast: 'Cy Okafor');
      final watched = [
        for (final k in ['1', '2', '3']) _watched('a$k', directors: ['Ada Marlow'], watches: [day1]),
      ];
      final library = _Library(db: idx);
      // Two titles only: below the minimum, so no pick; the read is checked
      // through the minimum lowered by a third title.
      expect(await personPick(library: library, store: store, pool: pool(), brain: _Brain(watched)), isNull);
      await row('e', 'ge', cast: 'Ada Marlow');
      final got = await personPick(library: library, store: store, pool: pool(), brain: _Brain(watched));
      expect(got?.candidates.map((c) => c.titleId).toSet(), {'d', 'c', 'e'});
    });
  });

  group('the day\'s row', () {
    test('kept once a day in code order; read as the remainder; the sweep keeps the rest window', () async {
      final p = pool();
      await p.keepPerson(_pick('Ada Marlow', ['x1', 'x2', 'x3']));
      await p.keepPerson(_pick('Bo Lindqvist', ['y1', 'y2', 'y3']));
      var list = await p.cachedPerson();
      expect(list?.name, 'Ada Marlow', reason: "today's person is not replaced");
      expect(list?.ai, isFalse);
      expect(list?.entries.map((e) => e.ratingKey), ['x1', 'x2', 'x3']);
      await store.record('x1', ReelAction.sampled, deck: 'person');
      list = await p.cachedPerson();
      expect(list?.entries.map((e) => e.ratingKey), ['x2', 'x3'], reason: 'gone through today');
      expect(await p.featuredPeople(), {'ada marlow': '2026-03-10'});

      now = DateTime(2026, 3, 11, 9);
      expect(await p.cachedPerson(), isNull, reason: "yesterday's person is not today's");
      expect(await p.featuredPeople(), {'ada marlow': '2026-03-10'});

      for (final k in ['person:2026-02-20', 'person:2026-02-25', 'person:2026-02-26']) {
        await store.cache(k, '{}');
      }
      await store.sweep();
      expect(await store.cached('person:2026-02-20'), isNull);
      expect(await store.cached('person:2026-02-25'), isNull);
      expect(await store.cached('person:2026-02-26'), isNotNull, reason: '14 days, today included');
      expect(await store.cached('person:2026-03-10'), isNotNull);
    });
  });

  group('the daily build orders the person', () {
    Map<String, dynamic> answer(List<String>? person) => {
      'cards': [
        {'id': 'c1', 'cluster': 'harbor drama'},
      ],
      'person': ?person,
    };

    test('one call orders For You and the person; the deck opens in its order, named for them', () async {
      var calls = 0, gathers = 0;
      String? user, system;
      Map<String, Object?>? tool;
      final answered = Completer<void>();
      final library = _Library(directed: {'x1': 'Ada Marlow', 'x2': 'Bo Lindqvist|Ada Marlow'});
      final forYou = ForYouDeck(
        pool: pool(
          library: library,
          model: (s, u, t) async {
            calls++;
            system = s;
            user = u;
            tool = t;
            await answered.future;
            // Unknown ids, a For You id and a repeat are ignored.
            return answer(['p3', 'p9', 'c1', 'p1', 'p3']);
          },
        ),
        library: library,
        candidates: () async => [_candidate('fresh')],
        facts: () async => '',
        person: () async {
          gathers++;
          return _pick('Ada Marlow', ['x1', 'x2', 'x3']);
        },
      );
      final deck = PersonDeck(forYou: forYou, library: library);
      expect(deck.name, 'A person you love');
      final first = await deck.load();
      expect(first.map((c) => c.id), ['x1', 'x2', 'x3'], reason: 'code order until the build lands');
      expect(deck.name, 'Directed by Ada Marlow');
      answered.complete();
      await forYou.building;
      expect(calls, 1);
      expect(gathers, 1, reason: 'the deck and the build share the day\'s gather');

      final cards = await deck.load();
      expect(cards.map((c) => c.id), ['x3', 'x1'], reason: "the build's order");
      expect(deck.intro?.line, "You've watched 4 titles with them. 2 you haven't seen.");
      expect((deck.id, deck.keepsSeen, deck.raw, deck.daily), ('person', false, true, true));

      final lines = user!.split('\n');
      final head = lines.indexWhere((l) => l.startsWith('Person ('));
      expect(head, greaterThan(lines.indexOf('Candidates:')));
      expect(lines[head], contains('Ada Marlow, a director'));
      expect(lines[head], contains('watched 4 titles with them'));
      expect(lines.firstWhere((l) => l.startsWith('p1:')), contains('directed by them'));
      expect(lines.firstWhere((l) => l.startsWith('p2:')), contains('directed by them'));
      expect(lines.firstWhere((l) => l.startsWith('p3:')), contains('with them in the cast'));
      expect(system, contains('person: optional'));
      final props = (tool!['input_schema'] as Map)['properties'] as Map;
      expect(props.containsKey('person'), isTrue);
      expect((tool!['input_schema'] as Map)['required'], ['cards']);
    });

    test('an answer with no person array keeps code order; an ordered day is not asked again', () async {
      final users = <String>[];
      List<String>? order;
      final p = pool(
        model: (_, u, _) async {
          users.add(u);
          return answer(order);
        },
      );
      final pick = _pick('Ada Marlow', ['x1', 'x2', 'x3'], role: PersonRole.cast);
      await p.keepPerson(pick);
      await p.build([_candidate('fresh')], facts: '', person: pick);
      expect(users.single, contains('Person (Ada Marlow, an actor'));
      var list = await p.cachedPerson();
      expect((list?.ai, list?.entries.length), (false, 3));

      order = ['p2'];
      await p.build([_candidate('fresh')], facts: '', person: pick);
      list = await p.cachedPerson();
      expect(list?.ai, isTrue);
      expect(list?.entries.map((e) => e.ratingKey), ['x2']);

      await p.build([_candidate('fresh')], facts: '', person: pick);
      expect(users.last, isNot(contains('Person (')), reason: 'already in the build\'s order');
      expect((await p.cachedPerson())?.entries.map((e) => e.ratingKey), ['x2']);
      expect(PersonDeck.nameFor(list), 'Starring Ada Marlow');
    });

    test('the TV shares the person with its pool; a phone shows the TV\'s person over its own', () async {
      await pool(
        model: (_, _, _) async => answer(['p2', 'p1']),
      ).build([_candidate('fresh')], facts: '', person: _pick('Ada Marlow', ['x1', 'x2']));
      final shared = jsonDecode((await settings.readSetting(ReelStore.poolKey))!) as Map;
      final person = shared['person'] as Map;
      expect((person['day'], person['name'], person['ai']), ('2026-03-10', 'Ada Marlow', true));
      expect((person['rows'] as List).map((j) => (j as Map)['rk']), ['x2', 'x1']);

      final phoneDb = ForkDatabase.memory();
      addTearDown(phoneDb.close);
      final phoneStore = ReelStore(database: () async => phoneDb, settings: () async => settings, clock: () => now);
      final phone = pool(host: false, on: phoneStore);
      // The phone had gathered its own person before the TV's arrived.
      await phone.keepPerson(_pick('Bo Lindqvist', ['y1', 'y2', 'y3']));
      final list = await phone.cachedPerson();
      expect(list?.name, 'Ada Marlow');
      expect(list?.entries.map((e) => e.ratingKey), ['x2', 'x1']);
      expect(await phone.featuredPeople(), {'ada marlow': '2026-03-10', 'bo lindqvist': '2026-03-10'});

      // The TV itself reads its own row first.
      await store.cache(
        ReelPool.personKey(now),
        jsonEncode({'day': '2026-03-10', 'name': 'Cy Okafor', 'role': 'cast', 'watched': 3, 'ai': false, 'rows': []}),
      );
      expect((await pool().cachedPerson())?.name, 'Cy Okafor');
    });

    test('with no person, the deck is empty and keeps its own name', () async {
      final forYou = ForYouDeck(
        pool: pool(),
        library: _Library(),
        candidates: () async => const [],
        facts: () async => '',
        person: () async => null,
      );
      final deck = PersonDeck(forYou: forYou, library: _Library());
      expect(await deck.load(), isEmpty);
      expect(deck.name, 'A person you love');
      expect(deck.intro, isNull);
      expect(PersonDeck.introLine(watched: 3, unseen: 1), "You've watched 3 titles with them. 1 you haven't seen.");
    });

    test('peek names the deck from the kept row without gathering', () async {
      var gathers = 0;
      final forYou = ForYouDeck(
        pool: pool(),
        library: _Library(),
        candidates: () async => const [],
        facts: () async => '',
        person: () async {
          gathers++;
          return null;
        },
      );
      final deck = PersonDeck(forYou: forYou, library: _Library());
      await deck.peek();
      expect(deck.name, 'A person you love');
      await pool().keepPerson(_pick('Ada Marlow', ['x1', 'x2', 'x3']));
      await deck.peek();
      expect(deck.name, 'Directed by Ada Marlow');
      expect(gathers, 0);
    });
  });
}
