import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/fork_database.dart';
import 'package:plezy/services/ai/ai_history.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/brain/history_brain.dart';
import 'package:plezy_brain/plezy_brain.dart';
import 'package:plezy/services/customisation/customisation_store.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/reel/clip_resolver.dart';
import 'package:plezy/services/reel/reel_decks.dart';
import 'package:plezy/services/reel/reel_library.dart';
import 'package:plezy/services/reel/reel_pool.dart';
import 'package:plezy/services/reel/reel_signals.dart';
import 'package:plezy/services/reel/reel_store.dart';

import '../test_helpers/media_items.dart';

ReelCardData _card(
  String id, {
  double? imdb,
  double? tmdb,
  double? audience,
  String? tagline,
  String? summary,
  int? runtime,
  bool show = false,
  SeenState seen = SeenState.unseen,
  bool kids = false,
}) => ReelCardData(
  title: ReelTitle(
    titleId: id,
    groupKey: 'g$id',
    title: 'Title $id',
    isShow: show,
    copies: [ReelCopy(serverId: 's1', ratingKey: id)],
  ),
  facts: TitleFacts(
    // A brain show id starts with "s:".
    ref: TitleRef(id: show ? 's:$id' : id, groupKey: 'g$id'),
    seen: seen,
    inKidsLibrary: kids,
    imdb: imdb,
    tmdb: tmdb,
    audience: audience,
    runtimeMinutes: runtime,
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
    summary: summary ?? '',
    tagline: tagline,
  ),
);

class _NoFacts implements TitleFactsSource {
  @override
  Future<Map<TitleId, TitleFacts>> load(Iterable<TitleRef> refs) async => const {};
  @override
  TitleFacts? peek(String globalKey) => null;
}

/// Maps entries straight onto invented cards (card id = rating key), each
/// with its own words from [texts] when given.
class _Library extends ReelLibrary {
  _Library({this.texts = const {}, this.lengths = const {}, this.shows = const {}})
    : super(database: () => throw UnimplementedError(), facts: _NoFacts());

  /// Shows by key: how far they got, and whether a Kids library has it.
  final Map<String, ({SeenState seen, bool kids})> shows;

  final Map<String, ({String? tagline, String? summary})> texts;

  /// A title's length in minutes (an episode's for a show).
  final Map<String, ({int? minutes, bool show})> lengths;

  @override
  Future<List<ReelCardData>> cards(List<DeckEntry> entries) async => [
    for (final e in entries)
      _card(
        e.ratingKey!,
        imdb: 7.5,
        tagline: texts[e.ratingKey]?.tagline,
        summary: texts[e.ratingKey]?.summary,
        runtime: lengths[e.ratingKey]?.minutes,
        show: lengths[e.ratingKey]?.show ?? shows.containsKey(e.ratingKey),
        seen: shows[e.ratingKey]?.seen ?? SeenState.unseen,
        kids: shows[e.ratingKey]?.kids ?? false,
      ),
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

/// A brain with no history of its own.
class _Brain extends HistoryBrain {
  @override
  Future<String> taste() async => 'Harbor dramas, slow sci-fi.';
  @override
  Future<List<TitleProfile>> watchedProfiles() async => const [];
}

/// An unwatched library title as the brain knows it (card id = [key]).
TitleProfile _unseen(String key, {TitleKind kind = TitleKind.movie}) =>
    TitleProfile(id: 'p:$key', kind: kind, title: 'Title $key', serverId: 's1', ratingKey: key, inLibrary: true);

/// A brain with its own history and fixed similar titles per seed.
class _SeededBrain extends HistoryBrain {
  _SeededBrain({required this.watched, required this.near, this.names = const {}});

  final List<TitleProfile> watched;
  final Map<String, List<({TitleProfile profile, double score})>> near;
  final Map<String, String> names;
  final asked = <String>[];

  @override
  Future<List<TitleProfile>> watchedProfiles() async => watched;

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

  @override
  Future<TitleProfile?> profile(String id) async =>
      names[id] == null ? null : TitleProfile(id: id, kind: TitleKind.movie, title: names[id]!);
}

AiHistoryEntry _answer(String label, List<String> keys) => AiHistoryEntry(
  id: label,
  request: label,
  intro: '',
  createdAt: DateTime(2026, 3, 1),
  items: [for (final k in keys) testMediaItem(id: k, serverId: 's1')],
  reasons: const {},
);

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

    ReelPool pool({PoolModel? model, bool host = true, ReelLibrary? library}) =>
        ReelPool(store: store, library: library ?? _Library(), model: model, host: host, clock: () => now);

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

    test("the build reads each candidate's own words and keeps checked hooks with the pool", () async {
      final library = _Library(
        texts: {
          'm': (tagline: 'Every tide returns', summary: 'A ferry pilot finds a letter. Then the island goes dark.'),
          'n': (tagline: null, summary: null),
        },
      );
      String? user;
      Map<String, Object?>? tool;
      String? system;
      await pool(
        library: library,
        model: (s, u, t) async {
          system = s;
          user = u;
          tool = t;
          return {
            'cards': [
              {'id': 'c1', 'cluster': 'harbor drama', 'hook': 'A ferry pilot and an unsent letter'},
              // No words of its own to write from: the hook is dropped.
              {'id': 'c2', 'cluster': 'harbor drama', 'hook': 'Made up from memory'},
            ],
          };
        },
      ).build([_candidate('m'), _candidate('n')], facts: '');
      final lines = user!.split('\n');
      expect(
        lines.firstWhere((l) => l.startsWith('c1:')),
        contains('premise: Every tide returns A ferry pilot finds a letter. Then the island goes dark.'),
      );
      expect(lines.firstWhere((l) => l.startsWith('c2:')), isNot(contains('premise:')));
      expect(system, contains('hook: optional, at most 12 words'));
      final props = (((tool!['input_schema'] as Map)['properties'] as Map)['cards'] as Map)['items'] as Map;
      expect((props['properties'] as Map).containsKey('hook'), isTrue);

      final raw = jsonDecode((await store.cached(ReelPool.dayKey(now)))!) as List;
      expect(raw.map((j) => (j as Map)['hk']), ['A ferry pilot and an unsent letter', null]);
      final cached = await pool(library: library).cachedPool();
      expect(cached?.map((e) => e.hook), ['A ferry pilot and an unsent letter', null]);
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

    test("Fits tonight keeps today's For You order to short films and short episodes, each chip its length", () async {
      final library = _Library(
        lengths: {
          'long': (minutes: 142, show: false),
          'film': (minutes: 110, show: false),
          'tense': (minutes: 50, show: true),
          'short': (minutes: 38, show: true),
          'unknown': (minutes: null, show: false),
          'brief': (minutes: 92, show: false),
          'half': (minutes: 45, show: true),
        },
      );
      final forYou = ForYouDeck(
        pool: pool(library: library),
        library: library,
        candidates: () async => const [],
        facts: () async => '',
      );
      await cachePool(now, ['long', 'film', 'tense', 'short', 'unknown', 'brief', 'half']);
      final deck = FitsTonightDeck(forYou: forYou);
      final cards = await deck.load();
      expect(cards.map((c) => c.id), ['film', 'short', 'brief', 'half']);
      expect(cards.map((c) => c.chip), ['1h 50m', '38m episodes', '1h 32m', '45m episodes']);
      expect(deck.daily, isTrue);
      expect(deck.keepsSeen, isFalse);
      expect(deck.id, isNot(forYou.id));
    });

    test("Fits tonight takes For You's fresh build when it lands", () async {
      final library = _Library(lengths: {'p': (minutes: 95, show: false), 'q': (minutes: 30, show: true)});
      final forYou = ForYouDeck(
        pool: pool(
          library: library,
          model: (_, _, _) async => {
            'cards': [
              {'id': 'c2', 'cluster': 'a'},
              {'id': 'c1', 'cluster': 'b'},
            ],
          },
        ),
        library: library,
        candidates: () async => [_candidate('p'), _candidate('q'), _candidate('r')],
        facts: () async => '',
      );
      final deck = FitsTonightDeck(forYou: forYou);
      var fired = 0;
      deck.rebuilt.addListener(() => fired++);
      expect((await deck.load()).map((c) => c.id), ['p', 'q'], reason: 'r has no known length');
      await forYou.building;
      expect(fired, 1);
      expect((await deck.load()).map((c) => c.id), ['q', 'p']);
    });

    test('the Fits tonight limits: a film to the minute, an episode to the minute', () {
      TitleFacts facts(int? minutes, {bool show = false}) => TitleFacts(
        ref: TitleRef(id: show ? 's:x' : 'm:x', groupKey: 'gx'),
        seen: SeenState.unseen,
        runtimeMinutes: minutes,
        episodes: show ? 24 : null,
      );
      expect(FitsTonightDeck.fitLine(facts(fitsTonightFilmMinutes)), '1h 50m');
      expect(FitsTonightDeck.fitLine(facts(fitsTonightFilmMinutes + 1)), isNull);
      expect(FitsTonightDeck.fitLine(facts(48)), '48m');
      expect(FitsTonightDeck.fitLine(facts(fitsTonightEpisodeMinutes, show: true)), '45m episodes');
      expect(FitsTonightDeck.fitLine(facts(fitsTonightEpisodeMinutes + 1, show: true)), isNull);
      expect(FitsTonightDeck.fitLine(facts(null)), isNull);
      expect(FitsTonightDeck.fitLine(facts(0, show: true)), isNull);
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

    test("the build's candidates carry the Reel's facts from both devices, and passes are not bans", () async {
      await recordAt(DateTime(2026, 3, 9, 21), 'm', ReelAction.toEnd);
      await recordAt(DateTime(2026, 3, 10, 9), 'm', ReelAction.details);
      await recordAt(DateTime(2026, 3, 8, 21), 'n', ReelAction.save);
      // The phone's aggregate: 'n' watched to the end there twice.
      await settings.writeSetting(
        ReelSignals.phoneKey,
        jsonEncode({
          'v': 1,
          'days': {
            '2026-03-09': {'n': 'ee'},
          },
        }),
      );
      String? system, user;
      await pool(
        model: (s, u, _) async {
          system = s;
          user = u;
          return null;
        },
      ).build([_candidate('m'), _candidate('n')], facts: 'Today is a test.');
      final lines = user!.split('\n');
      expect(
        lines.firstWhere((l) => l.startsWith('c1:')),
        allOf(contains('clip watched to the end'), contains('opened Details')),
      );
      expect(
        lines.firstWhere((l) => l.startsWith('c2:')),
        allOf(contains('saved 2 days ago, not played yet'), contains('clip watched to the end 2×')),
      );
      expect(system, contains('facts about the kind of title, not bans'));
    });

    test('the facts name Not for me, the counts per kind of title and the titles passed on lately', () async {
      await sharePool(DateTime(2026, 3, 9), ['a', 'b']); // both 'harbor drama'
      await cachePool(now, ['c']);
      await store.cache(
        ReelPool.dayKey(now),
        jsonEncode([
          {'id': 'c', 'sv': 's1', 'rk': 'c', 'cl': 'cosy anime'},
        ]),
      );
      await recordAt(DateTime(2026, 3, 9, 20), 'a', ReelAction.sampled);
      await recordAt(DateTime(2026, 3, 9, 20, 5), 'b', ReelAction.notForMe);
      await store.notForMe('b');
      await recordAt(DateTime(2026, 3, 10, 9), 'c', ReelAction.toEnd);
      // A pass made on the phone weeks ago, in the synced vetoes only.
      final was = now;
      now = DateTime(2026, 2, 1);
      await store.notForMe('d');
      now = was;
      final names = {'b': 'Harbor Lights', 'd': 'Lantern Street'};
      final facts = await forYouFacts(
        store: store,
        pool: pool(),
        brain: _Brain(),
        now: now,
        nameOf: (id) async => names[id],
      );
      expect(facts, contains('the local time is 20:00.'));
      expect(
        facts,
        contains('In the Reel, last 30 days, both devices together: 1 sampled, 1 watched to the end, 1 Not for me.'),
      );
      expect(facts, contains('- harbor drama: 1 sampled, 1 Not for me'));
      expect(facts, contains('- cosy anime: 1 watched to the end'));
      expect(
        facts,
        contains(
          'Passed on in the Reel lately (Not for me, newest first): Harbor Lights (harbor drama), Lantern Street',
        ),
      );
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

  group('wider For You candidates', () {
    late ForkDatabase db;
    late LocalCustomisationStore settings;
    late ReelStore store;
    final now = DateTime(2026, 3, 10, 20);

    setUp(() {
      db = ForkDatabase.memory();
      settings = LocalCustomisationStore(db);
      store = ReelStore(database: () async => db, settings: () async => settings, clock: () => now);
    });

    tearDown(() async => db.close());

    test('every source reaches the list, a title from two sources is one candidate, and each is tagged', () async {
      final loved = TitleProfile(
        id: 'p:loved',
        kind: TitleKind.movie,
        title: 'Harbor Lights',
        myRating: 9,
        watches: [DateTime(2025, 6, 1)],
      );
      final lately = TitleProfile(
        id: 'p:lately',
        kind: TitleKind.show,
        title: 'Lantern Street',
        watches: [now.subtract(const Duration(days: 3))],
      );
      final brain = _SeededBrain(
        watched: [loved, lately],
        near: {
          'p:loved': [(profile: _unseen('a'), score: 0.9), (profile: _unseen('both'), score: 0.5)],
          'p:lately': [
            (profile: _unseen('b', kind: TitleKind.show), score: 0.8),
            (profile: _unseen('both'), score: 0.4),
          ],
          'p:saved': [(profile: _unseen('c'), score: 0.7)],
          'p:savedHere': [(profile: _unseen('g'), score: 0.6)],
        },
        names: {'p:savedHere': 'Quiet Tide'},
      );
      await store.savePick(
        ReelPick(
          titleId: 'p:saved',
          groupKey: 'gsaved',
          serverId: 's1',
          ratingKey: 'saved',
          title: 'Northern Ferry',
          at: now.subtract(const Duration(days: 1)),
        ),
      );
      await store.record('p:savedHere', ReelAction.save, deck: 'for-you');

      final list = await forYouCandidates(
        library: _Library(),
        store: store,
        brain: brain,
        now: now,
        asks: () async => [
          _answer('slow sea dramas', ['d']),
        ],
        suggested: () async => [
          _answer('Quiet coastal films', ['e']),
        ],
        added: (since) async {
          expect(since, now.subtract(const Duration(days: 7)));
          return [
            (entry: const DeckEntry(serverId: 's1', ratingKey: 'f'), added: now.subtract(const Duration(days: 2))),
          ];
        },
      );
      expect(brain.asked, containsAll(['p:loved', 'p:lately', 'p:saved', 'p:savedHere']));
      final byId = {for (final c in list) c.titleId: c};
      expect(byId.keys.toSet(), {'a', 'both', 'b', 'c', 'g', 'd', 'e', 'f'});
      expect(list.where((c) => c.titleId == 'both'), hasLength(1));
      expect(byId['both']!.like, ['Harbor Lights']);
      expect(byId['both']!.recent, ['Lantern Street']);
      expect(byId['both']!.score, closeTo(0.9, 1e-9));
      expect(byId['c']!.saved, ['Northern Ferry']);
      expect(byId['g']!.saved, ['Quiet Tide']);
      expect(byId['d']!.askedFor, 'slow sea dramas');
      expect(byId['e']!.suggested, 'Quiet coastal films');
      expect(byId['f']!.added, now.subtract(const Duration(days: 2)));

      String? user;
      await ReelPool(
        store: store,
        library: _Library(),
        clock: () => now,
        model: (_, u, _) async {
          user = u;
          return {'cards': const []};
        },
      ).build(list, facts: '');
      final lines = user!.split('\n');
      String line(String title) => lines.firstWhere((l) => l.contains(': Title $title'));
      expect(
        line('both'),
        allOf(contains('similar to Harbor Lights'), contains('similar to recent plays Lantern Street')),
      );
      expect(line('c'), contains('similar to Reel Saves Northern Ferry'));
      expect(line('d'), contains('from their ask "slow sea dramas"'));
      expect(line('e'), contains('from the suggested list "Quiet coastal films"'));
      expect(line('f'), contains('added to the library 2 days ago'));
    });

    test('the bound keeps every source: a large taste pool does not crowd out the newest titles', () async {
      final loved = TitleProfile(
        id: 'p:loved',
        kind: TitleKind.movie,
        title: 'Harbor Lights',
        myRating: 9,
        watches: [DateTime(2025, 6, 1)],
      );
      final brain = _SeededBrain(
        watched: [loved],
        near: {
          'p:loved': [for (var i = 0; i < 600; i++) (profile: _unseen('t$i'), score: 0.9)],
        },
      );
      final list = await forYouCandidates(
        library: _Library(),
        store: store,
        brain: brain,
        now: now,
        asks: () async => const [],
        suggested: () async => const [],
        added: (_) async => [
          for (final k in ['n1', 'n2', 'n3']) (entry: DeckEntry(serverId: 's1', ratingKey: k), added: now),
        ],
      );
      expect(list, hasLength(ReelPool.maxCandidates));
      expect(list.map((c) => c.titleId), containsAll(['n1', 'n2', 'n3']));
    });

    test('a why line may name a recent play, a Reel Save or a suggested list', () {
      const c = PoolCandidate(
        entry: DeckEntry(serverId: 's1', ratingKey: 'x'),
        titleId: 'x',
        score: 1,
        recent: ['Lantern Street'],
        saved: ['Northern Ferry'],
        suggested: 'Quiet coastal films',
      );
      expect(ReelPool.checkedWhy('Like Lantern Street, set on the night shift', 'Lantern Street', c), isNotNull);
      expect(ReelPool.checkedWhy('Another ferry tale after Northern Ferry', 'Northern Ferry', c), isNotNull);
      expect(ReelPool.checkedWhy('Fits your Quiet coastal films list', 'Quiet coastal films', c), isNotNull);
      expect(ReelPool.checkedWhy('Like Harbor Lights', 'Harbor Lights', c), isNull);
    });

    test('a new title is tagged by its day, only within the week', () {
      expect(ReelPool.addedLine(now, now), 'added to the library today');
      expect(ReelPool.addedLine(DateTime(2026, 3, 9, 23), now), 'added to the library yesterday');
      expect(ReelPool.addedLine(DateTime(2026, 3, 4, 8), now), 'added to the library 6 days ago');
      expect(ReelPool.addedLine(DateTime(2026, 3, 3, 8), now), isNull);
      expect(ReelPool.addedLine(null, now), isNull);
    });

    test("prepare gathers before the brain yields only when today's build is due", () async {
      var gathered = 0;
      ForYouDeck deck(ReelPool pool) => ForYouDeck(
        pool: pool,
        library: _Library(),
        candidates: () async {
          gathered++;
          return [_candidate('p')];
        },
        facts: () async => '',
      );
      await deck(ReelPool(store: store, library: _Library(), clock: () => now)).prepare();
      expect(gathered, 1, reason: 'no pool today: the build is due, so the gather runs now');

      await store.cache(
        ReelPool.dayKey(now),
        jsonEncode([
          {'id': 'p', 'sv': 's1', 'rk': 'p'},
        ]),
      );
      await deck(ReelPool(store: store, library: _Library(), clock: () => now)).prepare();
      expect(gathered, 1, reason: "today's pool is here: nothing to gather");

      final failing = ForYouDeck(
        pool: ReelPool(store: store, library: _Library(), clock: () => now.add(const Duration(days: 1))),
        library: _Library(),
        candidates: () async => throw StateError('index busy'),
        facts: () async => '',
      );
      await failing.prepare();
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
  group('Give it another go', () {
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

    SeenState paused(DateTime last) => SeenState(kind: SeenKind.paused, last: last, eps: 3, total: 10);
    SeenState sampled(DateTime? last) => SeenState(kind: SeenKind.sampled, last: last, eps: 1, total: 20);

    /// Invented shows in every state the deck must tell apart.
    final library = _Library(
      shows: {
        'harbor': (seen: paused(DateTime(2026, 1, 2)), kids: false),
        'lantern': (seen: sampled(DateTime(2025, 2, 1)), kids: false),
        'tide': (seen: paused(DateTime(2025, 12, 1)), kids: false),
        'mill': (seen: sampled(null), kids: false),
        'cartoon': (seen: paused(DateTime(2026, 1, 9)), kids: true),
        'current': (seen: const SeenState(kind: SeenKind.inProgress, eps: 5, total: 10), kids: false),
        'done': (seen: const SeenState(kind: SeenKind.finished, eps: 10, total: 10), kids: false),
        'gone': (seen: const SeenState(kind: SeenKind.dropped, eps: 6, total: 30), kids: false),
        'fresh': (seen: SeenState.unseen, kids: false),
      },
    );

    TitleProfile watchedShow(String key) => TitleProfile(
      id: 'p:$key',
      kind: TitleKind.show,
      title: 'Show $key',
      serverId: 's1',
      ratingKey: key,
      inLibrary: true,
      episodesWatched: 1,
    );

    PoolCandidate again(String key) => PoolCandidate(
      entry: DeckEntry(serverId: 's1', ratingKey: key),
      titleId: key,
      score: 0,
    );

    ReelPool pool({PoolModel? model, bool host = true}) =>
        ReelPool(store: store, library: library, model: model, host: host, clock: () => now);

    test('the gather keeps sampled and paused shows only, paused first, newest first, never Kids', () async {
      final brain = _SeededBrain(
        watched: [
          for (final k in ['lantern', 'harbor', 'mill', 'cartoon', 'current', 'done', 'gone', 'tide', 'fresh'])
            watchedShow(k),
          // A film is never offered, whatever its state.
          _unseen('reel'),
          // Not on the servers: nothing to play.
          TitleProfile(id: 'p:away', kind: TitleKind.show, title: 'Show away', episodesWatched: 1),
        ],
        near: const {},
      );
      final got = await anotherGoCandidates(library: library, store: store, brain: brain);
      expect(got.map((c) => c.titleId), ['harbor', 'tide', 'lantern', 'mill']);

      await store.notForMe('tide');
      final resting = await anotherGoCandidates(library: library, store: store, brain: brain);
      expect(resting.map((c) => c.titleId), isNot(contains('tide')), reason: 'Not for me rests it here too');
    });

    test('the deck opens in code order, marks every card to resume, and keeps seen titles', () async {
      final forYou = ForYouDeck(
        pool: pool(),
        library: library,
        candidates: () async => const [],
        facts: () async => '',
        again: () async => [again('harbor'), again('lantern'), again('current'), again('cartoon')],
      );
      final deck = AnotherGoDeck(forYou: forYou, library: library);
      final cards = await deck.load();
      expect(cards.map((c) => c.id), ['harbor', 'lantern'], reason: 'picked up again or Kids: left out');
      expect(cards.every((c) => c.resume), isTrue);
      expect(deck.keepsSeen, isTrue);
      expect(deck.daily, isTrue);
      expect(deck.id, 'another-go');
      expect(identical(deck.rebuilt, forYou.rebuilt), isTrue);
    });

    test('the For You call orders the deck through its optional another_go array, with no call of its own', () async {
      var calls = 0;
      String? user;
      Map<String, Object?>? tool;
      String? system;
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
              'another_go': ['g3', 'g9', 'c1', 'g1', 'g3'],
            };
          },
        ),
        library: library,
        candidates: () async => [_candidate('fresh')],
        facts: () async => '',
        again: () async => [again('harbor'), again('lantern'), again('tide')],
      );
      final deck = AnotherGoDeck(forYou: forYou, library: library);
      var fired = 0;
      deck.rebuilt.addListener(() => fired++);
      expect((await deck.load()).map((c) => c.id), ['harbor', 'lantern', 'tide'], reason: 'code order first');
      await forYou.building;
      expect(calls, 1);
      expect(fired, 1);
      expect((await deck.load()).map((c) => c.id), ['tide', 'harbor']);
      expect(calls, 1, reason: 'no second build once today is cached');

      final lines = user!.split('\n');
      final head = lines.indexWhere((l) => l.startsWith('Another go'));
      expect(head, greaterThan(lines.indexOf('Candidates:')));
      expect(lines.firstWhere((l) => l.startsWith('g1:')), contains('3/10 eps, paused'));
      expect(lines.firstWhere((l) => l.startsWith('g1:')), contains('last watched Jan 2026'));
      expect(lines.firstWhere((l) => l.startsWith('g2:')), contains('1/20 eps, sampled'));
      expect(system, contains('another_go: optional'));
      final props = (tool!['input_schema'] as Map)['properties'] as Map;
      expect(props.containsKey('another_go'), isTrue);
      expect((tool!['input_schema'] as Map)['required'], ['cards']);
    });

    test('a build with no another_go keeps code order, and no list means no section', () async {
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
      );
      await forYou.load();
      await forYou.building;
      expect(user, isNot(contains('Another go')));
      expect(await store.cached(ReelPool.againKey(now)), isNull);
      expect(await pool().cachedAgain(), isNull);
    });

    test("the TV shares the order with its pool; a phone reads it as the day's remainder", () async {
      await pool(
        model: (_, _, _) async => {
          'cards': [
            {'id': 'c1', 'cluster': 'harbor drama'},
          ],
          'another_go': ['g2', 'g1'],
        },
      ).build([_candidate('fresh')], facts: '', again: [again('harbor'), again('lantern')]);
      final shared = jsonDecode((await settings.readSetting(ReelStore.poolKey))!) as Map;
      expect((shared['again'] as List).map((j) => (j as Map)['rk']), ['lantern', 'harbor']);

      // The phone: its own database, the same synced settings, no build of
      // its own; the TV's order comes back as the day's remainder.
      final phoneDb = ForkDatabase.memory();
      addTearDown(phoneDb.close);
      final phoneStore = ReelStore(database: () async => phoneDb, settings: () async => settings, clock: () => now);
      final phone = ReelPool(store: phoneStore, library: library, host: false, clock: () => now);
      expect((await phone.cachedAgain())?.map((e) => e.ratingKey), ['lantern', 'harbor']);
      await phoneStore.record('lantern', ReelAction.sampled, deck: 'another-go');
      expect((await phone.cachedAgain())?.map((e) => e.ratingKey), ['harbor'], reason: 'gone through today');
    });
  });
}
