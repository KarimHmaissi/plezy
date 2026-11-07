import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_rating.dart';
import 'package:plezy/services/ai/facts/index_title_facts_source.dart';
import 'package:plezy/services/ai/facts/title_facts.dart';
import 'package:plezy/services/library_index/index_database.dart';
import 'package:plezy/services/library_index/index_mapping.dart';
import 'package:plezy_brain/plezy_brain.dart';

final _now = DateTime.utc(2026, 11, 6);

const _ref = TitleRef(id: 'm:imdb:tt1', groupKey: 'imdb:tt1');

TitleFacts _facts({
  double? imdb,
  int? votes,
  double? rtCritic,
  double? rtAudience,
  double? tmdb,
  double? audience,
  String? certificate,
  bool kids = false,
  bool kidsOnly = false,
  SeenState seen = SeenState.unseen,
  LedgerSummary? ledger,
}) => TitleFacts(
  ref: _ref,
  seen: seen,
  imdb: imdb,
  imdbVotes: votes,
  rtCritic: rtCritic,
  rtAudience: rtAudience,
  tmdb: tmdb,
  audience: audience,
  certificate: certificate,
  inKidsLibrary: kids,
  kidsLibraryOnly: kidsOnly,
  ledger: ledger,
);

void main() {
  group('cardLine: one score, honestly labelled', () {
    test('IMDb with votes, and compact', () {
      expect(_facts(imdb: 8.5, votes: 220400).cardLine(), 'IMDb 8.5 (220k)');
      expect(_facts(imdb: 8.5, votes: 220400).cardLine(compact: true), 'IMDb 8.5');
    });

    test('an unlabelled Plex score is a bare star, never IMDb', () {
      final line = _facts(audience: 8.3).cardLine();
      expect(line, '★ 8.3');
      expect(line, isNot(contains('IMDb')));
    });

    test('labelled RT and TMDB scores keep their names', () {
      expect(_facts(rtAudience: 9.2, rtCritic: 7.7).cardLine(), 'RT audience 92%');
      expect(_facts(tmdb: 8.2).cardLine(), 'TMDB 8.2');
      expect(_facts(rtCritic: 7.7).cardLine(), 'RT 77%');
    });

    test('nothing known is no line', () => expect(_facts().cardLine(), isNull));
  });

  test('withRatings reads a saved pick\'s sources: an RT critic score is never the card\'s IMDb score', () {
    final f = _facts(audience: 7.7).withRatings(const [
      MediaRatingSource(source: 'rottenTomatoesCritic', value: 7.7),
      MediaRatingSource(source: 'rottenTomatoesAudience', value: 9.2),
      MediaRatingSource(source: 'imdb', value: 8.5, votes: 1500000),
      MediaRatingSource(source: 'tmdb', value: 8.2),
    ]);
    expect(f.cardLine(), 'IMDb 8.5 (1.5M)');
    expect(f.modelLine(), startsWith('IMDb 8.5 (1.5M) · RT 77% · RT audience 92% · TMDB 8.2'));
    expect(f.modelLine(), isNot(contains('source unknown')));
  });

  test('modelLine states kids and seen facts for the model to judge', () {
    final f = _facts(
      audience: 6.1,
      certificate: 'TV-Y',
      kids: true,
      kidsOnly: true,
      seen: const SeenState(kind: SeenKind.logged, loggedVia: {LoggedVia.trakt}),
    );
    expect(f.modelLine(), 'Plex audience 6.1 (source unknown) · TV-Y · Kids library only · logged as seen (Trakt)');
    expect(_facts(kids: true).modelLine(), 'also in Kids library · unseen');
  });

  group('ledger fact lines decay, never a final verdict', () {
    test('shown and not played yet', () {
      final l = LedgerSummary(timesShown: 3, now: _now);
      expect(l.factLine(), 'shown 3× lately, not played yet');
      expect(_facts(ledger: l).modelLine(), endsWith('unseen · shown 3× lately, not played yet'));
    });

    test('Not for me rests 90 days, reads as a soft fact until 180, then is gone', () {
      LedgerSummary at(int daysAgo) => LedgerSummary(
        notForMeAt: _now.subtract(Duration(days: daysAgo)),
        now: _now,
      );
      expect(at(10).resting, isTrue);
      expect(at(100).resting, isFalse);
      expect(at(100).factLine(), startsWith('passed on in '));
      expect(at(181).factLine(), isNull);
    });

    test('took or kept says nothing', () {
      expect(const LedgerSummary(timesShown: 2, outcome: PickOutcome.took).factLine(), isNull);
    });

    test('shown only in the Reel says so (V2-44)', () {
      final reel = LedgerSummary(timesShown: 3, surfaces: const {PickSurface.reel}, now: _now);
      expect(reel.factLine(), 'shown 3× in the Reel lately, not played yet');
      final mixed = LedgerSummary(timesShown: 3, surfaces: const {PickSurface.reel, PickSurface.ask}, now: _now);
      expect(mixed.factLine(), 'shown 3× lately, not played yet');
    });

    test('seenAt: a watch after the last showing, or a start, settles it (V2-44)', () {
      final shown = LedgerSummary(
        timesShown: 2,
        lastShown: _now.subtract(const Duration(days: 5)),
        surfaces: const {PickSurface.reel},
        now: _now,
      );
      expect(shown.seenAt(null).factLine(), 'shown 2× in the Reel lately, not played yet');
      expect(shown.seenAt(_now.subtract(const Duration(days: 30))).factLine(), isNotNull, reason: 'watched before');
      expect(shown.seenAt(_now.subtract(const Duration(days: 1))).outcome, PickOutcome.took);
      expect(shown.seenAt(_now.subtract(const Duration(days: 1))).factLine(), isNull);
      expect(shown.seenAt(null, inProgress: true).factLine(), isNull);
      final passed = LedgerSummary(notForMeAt: _now.subtract(const Duration(days: 3)), now: _now);
      expect(passed.seenAt(_now).factLine(), startsWith('passed on in '), reason: 'a pass is still said');
    });
  });

  test('lengthLine: film runtime, show episodes', () {
    expect(const TitleFacts(ref: _ref, seen: SeenState.unseen, runtimeMinutes: 118).lengthLine(), '1h 58m');
    expect(const TitleFacts(ref: _ref, seen: SeenState.unseen, runtimeMinutes: 45).lengthLine(), '45m');
    const show = TitleRef(id: 's:tvdb:1', groupKey: 'tvdb:1');
    expect(const TitleFacts(ref: show, seen: SeenState.unseen, episodes: 62).lengthLine(), '62 episodes');
    expect(const TitleFacts(ref: show, seen: SeenState.unseen).lengthLine(), isNull);
  });

  test('compactCount', () {
    expect(TitleFacts.compactCount(950), '950');
    expect(TitleFacts.compactCount(12400), '12k');
    expect(TitleFacts.compactCount(1250000), '1.3M');
    expect(TitleFacts.compactCount(25000000), '25M');
  });

  group('IndexTitleFactsSource', () {
    late IndexDatabase db;

    Future<void> add(
      String key, {
      required String library,
      String type = 'movie',
      String title = 'Film',
      String guid = 'imdb://tt1',
      int views = 0,
      double? audience,
      String? cert,
      int? leafCount,
      int? viewedLeafCount,
      DateTime? lastViewedAt,
    }) => db
        .into(db.indexTitles)
        .insert(
          indexRowFromPlex(
            {
              'ratingKey': key,
              'type': type,
              'title': title,
              'year': 2006,
              'viewCount': views,
              'audienceRating': ?audience,
              'contentRating': ?cert,
              'leafCount': ?leafCount,
              'viewedLeafCount': ?viewedLeafCount,
              if (lastViewedAt != null) 'lastViewedAt': lastViewedAt.millisecondsSinceEpoch ~/ 1000,
              'Guid': [
                {'id': guid},
              ],
              'Genre': [
                {'tag': 'Drama'},
              ],
            },
            serverId: key.startsWith('x') ? 'xtra' : 'main',
            serverName: 'S',
            libraryKey: library,
            libraryTitle: library,
          ),
        );

    setUp(() => db = IndexDatabase.memory());
    tearDown(() => db.close());

    IndexTitleFactsSource source({Map<String, TitleProfile> profiles = const {}, PickLedger? ledger}) =>
        IndexTitleFactsSource(
          database: () async => db,
          profiles: () async =>
              (id) => profiles[id],
          clock: () => _now,
          ledger: ledger,
        );

    Future<TitleRef> refFor(String key) async {
      final row = await (db.select(db.indexTitles)..where((t) => t.ratingKey.equals(key))).getSingle();
      return IndexTitleFactsSource.refOf(row);
    }

    test('Kids facts are EXISTS and ALL over every copy', () async {
      await add('1', library: 'Movies', audience: 7.1, cert: 'PG');
      await add('x2', library: 'Kids Movies');
      await add('3', library: 'Kids', guid: 'imdb://tt2', title: 'Cartoon');
      final ref = await refFor('1');
      final cartoon = await refFor('3');
      final out = await source().load([ref, cartoon]);
      expect(out[ref.id]!.inKidsLibrary, isTrue);
      expect(out[ref.id]!.kidsLibraryOnly, isFalse);
      expect(out[cartoon.id]!.kidsLibraryOnly, isTrue);
      // The stand-in copy is the grown-up one.
      expect(out[ref.id]!.audience, 7.1);
      expect(out[ref.id]!.certificate, 'PG');
      expect(out[ref.id]!.cardLine(), '★ 7.1');
    });

    test('a copy watched on one server makes the title seen; peek serves every copy', () async {
      await add('1', library: 'Movies');
      await add('x2', library: '4K Movies', views: 1);
      final ref = await refFor('1');
      final s = source();
      expect(s.peek('main:1'), isNull);
      final out = await s.load([ref]);
      expect(out[ref.id]!.seen.isUnseen, isFalse);
      expect(s.peek('main:1')?.seen.kind, out[ref.id]!.seen.kind);
      expect(s.peek('xtra:x2'), same(s.peek('main:1')));
    });

    test('a Trakt-logged title the servers call unwatched reads as logged', () async {
      await add('1', library: 'Movies');
      final ref = await refFor('1');
      final p = TitleProfile(id: ref.id, kind: TitleKind.movie, title: 'Film', bulkPlays: 1, bulkVia: const {'trakt'});
      final out = await source(profiles: {ref.id: p}).load([ref]);
      expect(out[ref.id]!.seen.line(), 'logged as seen (Trakt)');
    });

    test('shows carry their episodes and episode progress', () async {
      await add('7', library: 'TV', type: 'show', guid: 'tvdb://99', title: 'Show', leafCount: 62, viewedLeafCount: 38);
      final ref = await refFor('7');
      final out = await source().load([ref]);
      expect(out[ref.id]!.episodes, 62);
      expect(out[ref.id]!.seen.line(), startsWith('38/62 eps'));
    });

    test('the pick ledger rides on the facts; a watch since the showing settles it (V2-44)', () async {
      await add('1', library: 'Movies', guid: 'imdb://tt1', title: 'Harbor Lights');
      await add('2', library: 'Movies', guid: 'imdb://tt2', title: 'Copper Valley');
      await add(
        '3',
        library: 'Movies',
        guid: 'imdb://tt3',
        title: 'Northern Static',
        views: 1,
        lastViewedAt: _now.subtract(const Duration(days: 1)),
      );
      final harbor = await refFor('1'), copper = await refFor('2'), northern = await refFor('3');
      LedgerSummary shown(int times) => LedgerSummary(
        timesShown: times,
        lastShown: _now.subtract(const Duration(days: 4)),
        surfaces: const {PickSurface.reel},
        now: _now,
      );
      final ledger = _MapLedger({harbor.id: shown(3), northern.id: shown(1)});

      final before = await source().load([harbor, copper, northern]);
      final after = await source(ledger: ledger).load([harbor, copper, northern]);

      expect(ledger.asked, [
        [harbor.id, copper.id, northern.id],
      ], reason: 'one ledger read per batch');
      expect(before[harbor.id]!.ledger, isNull);
      expect(before[harbor.id]!.modelLine(), 'unseen');
      expect(after[harbor.id]!.modelLine(), 'unseen · shown 3× in the Reel lately, not played yet');
      expect(after[copper.id]!.modelLine(), before[copper.id]!.modelLine(), reason: 'no Reel facts, no change');
      expect(after[northern.id]!.ledger!.outcome, PickOutcome.took, reason: 'watched after it was shown');
      expect(after[northern.id]!.modelLine(), before[northern.id]!.modelLine());
    });

    test('a ledger that fails leaves the facts as they were', () async {
      await add('1', library: 'Movies');
      final ref = await refFor('1');
      final out = await source(ledger: _MapLedger(const {}, fail: true)).load([ref]);
      expect(out[ref.id]!.ledger, isNull);
      expect(out[ref.id]!.modelLine(), 'unseen');
    });

    test('unknown titles are left out', () async {
      final out = await source().load([const TitleRef(id: 'm:imdb:tt404', groupKey: 'nope')]);
      expect(out, isEmpty);
    });
  });
}

/// A ledger with fixed summaries; records which ids each read asked for.
class _MapLedger implements PickLedger {
  _MapLedger(this.byId, {this.fail = false});

  final Map<TitleId, LedgerSummary> byId;
  final bool fail;
  final List<List<TitleId>> asked = [];

  @override
  Future<Map<TitleId, LedgerSummary>> summaries(Iterable<TitleId> ids, {DateTime? now}) async {
    asked.add(ids.toList());
    if (fail) throw StateError('ledger unavailable');
    return {for (final id in ids) id: ?byId[id]};
  }

  @override
  Future<void> record(List<PickEvent> events) async {}

  @override
  Future<Set<TitleId>> shownWithin(Duration window, {Iterable<PickSurface>? surfaces, DateTime? now}) async => {};

  @override
  Future<String> promptFacts({DateTime? now, int maxLines = 40}) async => '';

  @override
  Future<Set<TitleId>> resting({DateTime? now}) async => {};
}
