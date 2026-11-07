import 'dart:convert';

import 'package:drift/drift.dart' show Value;
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

class _NoFacts implements TitleFactsSource {
  @override
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs) async => const {};
  @override
  TitleFacts? peek(String globalKey) => null;
}

/// Maps entries straight onto invented cards (card id = rating key). Keys
/// in [shows] are shows, keys in [seen] are seen, keys in [kidsOnly] have
/// no card (a Kids-only title).
class _Library extends ReelLibrary {
  _Library({this.shows = const {}, this.seen = const {}, this.kidsOnly = const {}, IndexDatabase? db})
    : super(database: () async => db ?? (throw UnimplementedError()), facts: _NoFacts());

  final Set<String> shows;
  final Set<String> seen;
  final Set<String> kidsOnly;

  @override
  Future<List<ReelCardData>> cards(List<DeckEntry> entries) async => [
    for (final e in entries)
      if (!kidsOnly.contains(e.ratingKey))
        _card(e.ratingKey!, server: e.serverId!, show: shows.contains(e.ratingKey), seen: seen.contains(e.ratingKey)),
  ];
}

ReelCardData _card(String id, {String server = 's1', bool show = false, bool seen = false}) => ReelCardData(
  title: ReelTitle(
    titleId: id,
    groupKey: 'g$id',
    title: 'Harbor Lights $id',
    isShow: show,
    copies: [ReelCopy(serverId: server, ratingKey: id)],
  ),
  facts: TitleFacts(
    ref: TitleRef(id: show ? 's:$id' : id, groupKey: 'g$id'),
    seen: seen ? const SeenState(kind: SeenKind.finished) : SeenState.unseen,
    imdb: 7.2,
  ),
  best: IndexedTitle(
    id: '$server:$id',
    serverId: server,
    serverName: 'Server A',
    libraryKey: '1',
    libraryTitle: show ? 'Shows' : 'Films',
    ratingKey: id,
    type: show ? 'show' : 'movie',
    title: 'Harbor Lights $id',
    year: 2026,
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

PoolCandidate _arrival(String id, DateTime added) => PoolCandidate(
  entry: DeckEntry(serverId: 's1', ratingKey: id),
  titleId: id,
  score: 0,
  added: added,
);

PoolCandidate _candidate(String id) => PoolCandidate(
  entry: DeckEntry(serverId: 's1', ratingKey: id),
  titleId: id,
  score: 1,
);

void main() {
  late ForkDatabase db;
  late LocalCustomisationStore settings;
  late ReelStore store;
  // A Tuesday: the week (from Friday) began on 2026-03-06.
  var now = DateTime(2026, 3, 10, 20);

  setUp(() {
    db = ForkDatabase.memory();
    settings = LocalCustomisationStore(db);
    now = DateTime(2026, 3, 10, 20);
    store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
  });

  tearDown(() async => db.close());

  test('the week turns over on Friday, across a month too', () {
    expect(ReelPool.weekStartsOn, DateTime.friday);
    expect(ReelPool.weekOf(DateTime(2026, 3, 10, 20)), '2026-03-06');
    expect(ReelPool.weekOf(DateTime(2026, 3, 12, 23, 59)), '2026-03-06');
    expect(ReelPool.weekOf(DateTime(2026, 3, 13, 0, 1)), '2026-03-13');
    expect(ReelPool.weekOf(DateTime(2026, 3, 1, 9)), '2026-02-27');
    expect(ReelPool.weekKey(DateTime(2026, 3, 10)), 'week:2026-03-06');
  });

  group('the week\'s arrivals', () {
    test('counts every title that arrived but Kids-only ones; asks about the unseen ones not resting', () async {
      await store.notForMe('rest');
      final library = _Library(shows: {'s'}, seen: {'old'}, kidsOnly: {'kid'});
      DateTime? asked;
      final got = await newThisWeekArrivals(
        library: library,
        store: store,
        now: now,
        added: (since) async {
          asked = since;
          return [
            for (final (i, k) in ['f', 's', 'old', 'kid', 'rest', 'f'].indexed)
              (entry: DeckEntry(serverId: 's1', ratingKey: k), added: now.subtract(Duration(days: i))),
          ];
        },
      );
      expect(asked, now.subtract(const Duration(days: 7)));
      expect(got.films, 3, reason: 'f, old (seen) and rest; a repeat counts once');
      expect(got.shows, 1);
      expect(got.candidates.map((c) => c.titleId), ['f', 's'], reason: 'unseen and not resting, newest first');
      expect(got.candidates.first.added, now);
    });

    test('from the index: one per title across servers, and a title with an older copy is not new', () async {
      final idx = IndexDatabase.memory();
      addTearDown(idx.close);
      int secs(Duration ago) => now.subtract(ago).millisecondsSinceEpoch ~/ 1000;
      Future<void> row(String server, String key, String group, {Duration? ago, String type = 'movie'}) => idx
          .into(idx.indexTitles)
          .insert(
            IndexTitlesCompanion.insert(
              id: '$server:$key',
              serverId: server,
              serverName: 'Server $server',
              libraryKey: '1',
              libraryTitle: type == 'show' ? 'Shows' : 'Films',
              ratingKey: key,
              type: type,
              title: 'Quiet Tide $key',
              groupKey: group,
              addedAt: Value(ago == null ? null : secs(ago)),
            ),
          );
      await row('s1', 'a', 'ga', ago: const Duration(days: 2));
      await row('s2', 'a2', 'ga', ago: const Duration(days: 1)); // the same title on a second server
      await row('s1', 'b', 'gb', ago: const Duration(hours: 20));
      await row('s1', 'b0', 'gb', ago: const Duration(days: 30)); // b is an upgrade of an older copy
      await row('s1', 'c', 'gc', ago: const Duration(days: 3), type: 'show');
      await row('s1', 'd', 'gd', ago: const Duration(days: 10)); // before the week
      await row('s1', 'e', 'ge'); // no date

      final got = await newThisWeekArrivals(
        library: _Library(shows: {'c'}, db: idx),
        store: store,
        now: now,
      );
      expect(got.candidates.map((c) => c.entry.rowId), ['s2:a2', 's1:c']);
      expect(got.films, 1);
      expect(got.shows, 1);
      expect(got.candidates.first.added, DateTime.fromMillisecondsSinceEpoch(secs(const Duration(days: 1)) * 1000));
    });
  });

  group('the daily build judges the week', () {
    ReelPool pool({PoolModel? model, bool host = true, ReelStore? on}) => ReelPool(
      store: on ?? store,
      library: _Library(shows: {'n3'}),
      model: model,
      host: host,
      clock: () => now,
    );

    NewArrivals arrivals() => (
      candidates: [
        _arrival('n1', now.subtract(const Duration(days: 1))),
        _arrival('n2', now.subtract(const Duration(days: 2))),
        _arrival('n3', now.subtract(const Duration(days: 4))),
      ],
      films: 3,
      shows: 1,
    );

    test('one call orders For You and picks the week\'s shortlist; the deck opens on it with its counts', () async {
      var calls = 0, gathers = 0;
      String? user, system;
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
              'new_this_week': ['n3', 'n9', 'c1', 'n1', 'n3'],
            };
          },
        ),
        library: _Library(shows: {'n3'}),
        candidates: () async => [_candidate('fresh')],
        facts: () async => '',
        arrivals: () async {
          gathers++;
          return arrivals();
        },
      );
      final deck = NewThisWeekDeck(
        forYou: forYou,
        library: _Library(shows: {'n3'}),
      );
      var fired = 0;
      deck.rebuilt.addListener(() => fired++);
      expect(await deck.load(), isEmpty, reason: 'never raw addedAt: empty until the build judges the week');
      expect(deck.intro, isNull);
      await forYou.building;
      expect(calls, 1);
      expect(gathers, 1);
      expect(fired, 1);

      final cards = await deck.load();
      expect(cards.map((c) => c.id), ['n3', 'n1'], reason: "the build's order");
      expect(deck.intro?.line, '3 films, 1 show arrived. 2 worth a look.');
      expect(deck.id, 'new-this-week');
      expect(deck.name, 'New this week');
      expect(deck.keepsSeen, isFalse);
      expect(deck.raw, isTrue);
      expect(deck.daily, isTrue);

      final lines = user!.split('\n');
      final head = lines.indexWhere((l) => l.startsWith('New this week'));
      expect(head, greaterThan(lines.indexOf('Candidates:')));
      expect(lines[head], contains('3 films, 1 shows'));
      expect(lines.firstWhere((l) => l.startsWith('n1:')), contains('added to the library yesterday'));
      expect(lines.firstWhere((l) => l.startsWith('n3:')), contains('show'));
      expect(system, contains('new_this_week: optional'));
      final props = (tool!['input_schema'] as Map)['properties'] as Map;
      expect(props.containsKey('new_this_week'), isTrue);
      expect((tool!['input_schema'] as Map)['required'], ['cards']);
    });

    test('the week is judged once: later days build without it, and the next Friday asks again', () async {
      var gathers = 0;
      final users = <String>[];
      final forYou = ForYouDeck(
        pool: pool(
          model: (_, u, _) async {
            users.add(u);
            return {
              'cards': [
                {'id': 'c1', 'cluster': 'harbor drama'},
              ],
              'new_this_week': ['n2'],
            };
          },
        ),
        library: _Library(),
        candidates: () async => [_candidate('fresh')],
        facts: () async => '',
        arrivals: () async {
          gathers++;
          return arrivals();
        },
      );
      await forYou.load();
      await forYou.building;
      expect(gathers, 1);
      expect(users.single, contains('New this week'));

      now = DateTime(2026, 3, 11, 20); // Wednesday: same week
      await forYou.load();
      await forYou.building;
      expect(users, hasLength(2), reason: "Wednesday's For You builds");
      expect(gathers, 1, reason: 'the week is not gathered again');
      expect(users.last, isNot(contains('New this week')));
      expect((await pool().cachedWeek())?.entries.map((e) => e.ratingKey), ['n2']);

      now = DateTime(2026, 3, 13, 9); // Friday: a new week
      expect(await pool().cachedWeek(), isNull, reason: "last week's list is not this week's");
      await forYou.load();
      await forYou.building;
      expect(gathers, 2);
      expect(users.last, contains('New this week'));
      expect((await pool().cachedWeek())?.week, '2026-03-13');
    });

    test('an answer with no new_this_week keeps nothing (asked again); an empty one keeps the counts', () async {
      Map<String, dynamic> answer = {
        'cards': [
          {'id': 'c1', 'cluster': 'harbor drama'},
        ],
      };
      final p = pool(model: (_, _, _) async => answer);
      await p.build([_candidate('fresh')], facts: '', arrivals: arrivals());
      expect(await store.cached(ReelPool.weekKey(now)), isNull);
      expect(await p.weekDue(), isTrue);

      answer = {...answer, 'new_this_week': <String>[]};
      await p.build([_candidate('fresh')], facts: '', arrivals: arrivals());
      final week = await p.cachedWeek();
      expect(week?.entries, isEmpty);
      expect(week?.chosen, 0);
      expect((week?.films, week?.shows), (3, 1));
      expect(await p.weekDue(), isFalse);
      expect(
        NewThisWeekDeck.introLine(films: 3, shows: 1, worth: 0),
        '3 films, 1 show arrived. None worth a look yet.',
      );
      expect(NewThisWeekDeck.introLine(films: 1, shows: 0, worth: 1), '1 film, 0 shows arrived. 1 worth a look.');
    });

    test('with nothing unseen to judge, the counts are kept without asking', () async {
      String? user;
      final p = pool(
        model: (_, u, _) async {
          user = u;
          return {
            'cards': [
              {'id': 'c1', 'cluster': 'harbor drama'},
            ],
          };
        },
      );
      await p.build([_candidate('fresh')], facts: '', arrivals: (candidates: const [], films: 2, shows: 0));
      expect(user, isNot(contains('New this week')));
      final week = await p.cachedWeek();
      expect((week?.films, week?.shows, week?.chosen), (2, 0, 0));
    });

    test("the TV shares the week with its pool; a phone reads it as the week's remainder", () async {
      await pool(
        model: (_, _, _) async => {
          'cards': [
            {'id': 'c1', 'cluster': 'harbor drama'},
          ],
          'new_this_week': ['n2', 'n1'],
        },
      ).build([_candidate('fresh')], facts: '', arrivals: arrivals());
      final shared = jsonDecode((await settings.readSetting(ReelStore.poolKey))!) as Map;
      final week = shared['week'] as Map;
      expect(week['week'], '2026-03-06');
      expect((week['rows'] as List).map((j) => (j as Map)['rk']), ['n2', 'n1']);
      expect((week['films'], week['shows']), (3, 1));

      // The phone: its own database, the same synced settings, no build of
      // its own.
      final phoneDb = ForkDatabase.memory();
      addTearDown(phoneDb.close);
      final phoneStore = ReelStore(database: () async => phoneDb, settings: () async => settings, clock: () => now);
      final phone = pool(host: false, on: phoneStore);
      expect(await phone.weekDue(), isFalse, reason: "the TV's list stands for this week");
      expect((await phone.cachedWeek())?.entries.map((e) => e.ratingKey), ['n2', 'n1']);
      await phoneStore.record('n2', ReelAction.sampled, deck: 'new-this-week');
      final rest = await phone.cachedWeek();
      expect(rest?.entries.map((e) => e.ratingKey), ['n1'], reason: 'gone through this week');
      expect(rest?.chosen, 2, reason: 'the intro still counts what the build chose');
    });

    test('the daily sweep keeps this week and last week only', () async {
      for (final k in ['week:2026-02-20', 'week:2026-02-27', 'week:2026-03-06']) {
        await store.cache(k, '{}');
      }
      await store.sweep();
      expect(await store.cached('week:2026-02-20'), isNull);
      expect(await store.cached('week:2026-02-27'), isNotNull);
      expect(await store.cached('week:2026-03-06'), isNotNull);
    });
  });
}
